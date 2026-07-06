with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories; use Ada.Directories;
with Ada.Exceptions;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Interfaces.C;
with System;
with GNAT.OS_Lib;

with Version.Config;
with Version.Files;
with Version.Hash;
with Version.History;
with Version.LFS;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Path_Safety;
with Version.Platform;
with Version.Write;

package body Version.Merge is

   use Version.Objects;
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type GNAT.OS_Lib.String_Access;

   --  Resolve a program name on PATH (GNAT.OS_Lib.Spawn does not search PATH).
   --  Falls back to the bare name so error handling stays unchanged.
   function Resolve_Program (Name : String) return String is
      P : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Locate_Exec_On_Path (Name);
   begin
      if P = null then
         return Name;
      end if;
      return R : constant String := P.all do
         GNAT.OS_Lib.Free (P);
      end return;
   end Resolve_Program;

   function Normalize_Text
     (Text : String; Behavior : Merge_Behavior) return String;
   function Equivalent_Text
     (Left, Right : String; Behavior : Merge_Behavior) return Boolean;
   use type GNAT.OS_Lib.File_Descriptor;
   use type Version.Platform.Platform_Kind;

   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   package Line_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Natural,
      Element_Type => String);

   type Match_Pair is record
      Base_Pos    : Natural;
      Variant_Pos : Natural;
   end record;

   package Match_Pair_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Match_Pair);

   type Edit_Span is record
      Base_First    : Natural;
      Base_After    : Natural;
      Variant_First : Natural;
      Variant_After : Natural;
   end record;

   package Edit_Span_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Edit_Span);

   function Symlink
     (Target : System.Address; Linkpath : System.Address)
      return Interfaces.C.int;
   pragma Import (C, Symlink, "symlink");

   function Unlink (Path : System.Address) return Interfaces.C.int;
   pragma Import (C, Unlink, "unlink");

   type Merge_Attribute is
     (Attribute_Default,
      Attribute_Reset,
      Attribute_Text,
      Attribute_Ours,
      Attribute_Theirs,
      Attribute_Union,
      Attribute_Binary);

   function Config_True (Text : String) return Boolean is
      Value : String := Version.Config.Trim (Text);
   begin
      for I in Value'Range loop
         Value (I) := Ada.Characters.Handling.To_Lower (Value (I));
      end loop;

      return Value = "true" or else Value = "1"
        or else Value = "yes" or else Value = "on";
   end Config_True;

   function Config_False (Text : String) return Boolean is
      Value : String := Version.Config.Trim (Text);
   begin
      for I in Value'Range loop
         Value (I) := Ada.Characters.Handling.To_Lower (Value (I));
      end loop;

      return Value = "false" or else Value = "0"
        or else Value = "no" or else Value = "off";
   end Config_False;

   function Core_Symlinks_Disabled
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      --  Read inside the body so a missing key (Get_Value raises) is handled
      --  here rather than escaping from the declarative part to the caller.
      declare
         Value : constant String :=
           Version.Config.Trim (Version.Config.Get_Value (Repo, "core.symlinks"));
      begin
         if Value'Length = 0 then
            return Version.Platform.Current /= Version.Platform.POSIX_Platform;
         else
            return Config_False (Value);
         end if;
      end;
   exception
      when others =>
         return Version.Platform.Current /= Version.Platform.POSIX_Platform;
   end Core_Symlinks_Disabled;

   function Conflict_Kind_Image (Kind : Conflict_Kind) return String is
   begin
      case Kind is
         when Content_Conflict        => return "content";
         when Add_Add_Conflict        => return "add-add";
         when Delete_Modify_Conflict  => return "delete-modify";
         when Directory_File_Conflict => return "directory-file";
         when Binary_Conflict         => return "binary";
      end case;
   end Conflict_Kind_Image;

   function Conflict_Kind_Value (Text : String) return Conflict_Kind is
   begin
      if Text = "content" then
         return Content_Conflict;
      elsif Text = "add-add" then
         return Add_Add_Conflict;
      elsif Text = "delete-modify" then
         return Delete_Modify_Conflict;
      elsif Text = "directory-file" then
         return Directory_File_Conflict;
      elsif Text = "binary" then
         return Binary_Conflict;
      else
         raise Ada.IO_Exceptions.Data_Error with
           "invalid merge conflict kind: " & Text;
      end if;
   end Conflict_Kind_Value;

   function Is_Binary_Content (Content : String) return Boolean is
   begin
      for I in Content'Range loop
         if Content (I) = Character'Val (0) then
            return True;
         end if;
      end loop;

      return False;
   end Is_Binary_Content;

   function Find_Tree_Item
     (Items : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
      return Natural is
   begin
      if Items.Is_Empty then
         return Natural'Last;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if To_String (Items.Element (I).Path) = Path then
            return I;
         end if;
      end loop;

      return Natural'Last;
   end Find_Tree_Item;

   function Is_Safe_Relative_Path (Path : String) return Boolean is
   begin
      return Version.Path_Safety.Is_Safe_Relative_Path (Path);
   end Is_Safe_Relative_Path;

   procedure Require_Safe_Path (Path : String) is
   begin
      Version.Path_Safety.Require_Safe_Relative_Path (Path, "merge path");
   end Require_Safe_Path;

   function Has_Path_Prefix
     (Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Prefix : String) return Boolean
   is
      Needle : constant String := Prefix & "/";
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            P : constant String := To_String (Items.Element (I).Path);
         begin
            if P'Length > Needle'Length
              and then P (P'First .. P'First + Needle'Length - 1) = Needle
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Path_Prefix;

   function Has_Ancestor_File
     (Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Path  : String) return Boolean
   is
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            declare
               Parent : constant String := Path (Path'First .. I - 1);
            begin
               if Find_Tree_Item (Items, Parent) /= Natural'Last then
                  return True;
               end if;
            end;
         end if;
      end loop;

      return False;
   end Has_Ancestor_File;

   function With_Trailing_Newline (Text : String) return String;

   function Conflict_Text
     (Current_Name : String;
      Current_Text : String;
      Base_Name    : String;
      Base_Text    : String;
      Has_Base     : Boolean;
      Target_Name  : String;
      Target_Text  : String;
      Behavior     : Merge_Behavior) return String;

   function Split_Lines (Text : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Start  : Natural := Text'First;
      Stop   : Natural;
   begin
      if Text'Length = 0 then
         return Result;
      end if;

      while Start <= Text'Last loop
         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
            Stop := Stop + 1;
         end loop;

         if Stop <= Text'Last then
            Result.Append (Text (Start .. Stop));
            Start := Stop + 1;
         else
            Result.Append (Text (Start .. Text'Last));
            Start := Text'Last + 1;
         end if;
      end loop;

      return Result;
   end Split_Lines;

   procedure Append_Line_Range
     (Result : in out Unbounded_String;
      Lines  : Line_Vectors.Vector;
      First  : Natural;
      After  : Natural) is
   begin
      if First >= After then
         return;
      end if;

      for I in First .. After - 1 loop
         Append (Result, Lines.Element (I));
      end loop;
   end Append_Line_Range;

   function Line_Range_Text
     (Lines : Line_Vectors.Vector;
      First : Natural;
      After : Natural) return String
   is
      Result : Unbounded_String;
   begin
      Append_Line_Range (Result, Lines, First, After);
      return To_String (Result);
   end Line_Range_Text;

   function Common_Prefix_Count
     (Left, Right : Line_Vectors.Vector) return Natural
   is
      Limit : constant Natural := Natural'Min
        (Natural (Left.Length), Natural (Right.Length));
      Count : Natural := 0;
   begin
      while Count < Limit
        and then Left.Element (Count) = Right.Element (Count)
      loop
         Count := Count + 1;
      end loop;

      return Count;
   end Common_Prefix_Count;

   function Common_Suffix_Count
     (Left, Right : Line_Vectors.Vector;
      Prefix      : Natural) return Natural
   is
      Left_Length  : constant Natural := Natural (Left.Length);
      Right_Length : constant Natural := Natural (Right.Length);
      Limit        : constant Natural :=
        Natural'Min (Left_Length - Prefix, Right_Length - Prefix);
      Count        : Natural := 0;
   begin
      while Count < Limit
        and then Left.Element (Left_Length - Count - 1)
                 = Right.Element (Right_Length - Count - 1)
      loop
         Count := Count + 1;
      end loop;

      return Count;
   end Common_Suffix_Count;

   function Replacement_Equal
     (Left        : Line_Vectors.Vector;
      Left_First  : Natural;
      Left_After  : Natural;
      Right       : Line_Vectors.Vector;
      Right_First : Natural;
      Right_After : Natural) return Boolean
   is
      Left_Length  : constant Natural := Left_After - Left_First;
      Right_Length : constant Natural := Right_After - Right_First;
   begin
      if Left_Length /= Right_Length then
         return False;
      elsif Left_Length = 0 then
         return True;
      end if;

      for Offset in 0 .. Left_Length - 1 loop
         if Left.Element (Left_First + Offset)
           /= Right.Element (Right_First + Offset)
         then
            return False;
         end if;
      end loop;

      return True;
   exception
      when Constraint_Error =>
         return Left_Length = 0 and then Right_Length = 0;
   end Replacement_Equal;

   function Try_Linewise_Text_Merge
     (Base_Lines    : Line_Vectors.Vector;
      Current_Lines : Line_Vectors.Vector;
      Target_Lines  : Line_Vectors.Vector;
      Merged        : out Unbounded_String) return Boolean
   is
      Length : constant Natural := Natural (Base_Lines.Length);
   begin
      Merged := Null_Unbounded_String;

      if Natural (Current_Lines.Length) /= Length
        or else Natural (Target_Lines.Length) /= Length
      then
         return False;
      end if;

      if Length = 0 then
         return True;
      end if;

      for I in 0 .. Length - 1 loop
         declare
            Base_Line    : constant String := Base_Lines.Element (I);
            Current_Line : constant String := Current_Lines.Element (I);
            Target_Line  : constant String := Target_Lines.Element (I);
         begin
            if Current_Line = Target_Line then
               Append (Merged, Current_Line);
            elsif Current_Line = Base_Line then
               Append (Merged, Target_Line);
            elsif Target_Line = Base_Line then
               Append (Merged, Current_Line);
            else
               Merged := Null_Unbounded_String;
               return False;
            end if;
         end;
      end loop;

      return True;
   end Try_Linewise_Text_Merge;

   function Line_Count (Lines : Line_Vectors.Vector; Needle : String) return Natural is
      Count : Natural := 0;
   begin
      if Lines.Is_Empty then
         return 0;
      end if;

      for I in Lines.First_Index .. Lines.Last_Index loop
         if Lines.Element (I) = Needle then
            Count := Count + 1;
         end if;
      end loop;

      return Count;
   end Line_Count;

   function Match_Allowed
     (Base_Lines    : Line_Vectors.Vector;
      Variant_Lines : Line_Vectors.Vector;
      Base_Pos      : Natural;
      Variant_Pos   : Natural;
      Algorithm     : Diff_Algorithm) return Boolean
   is
      Text : constant String := Base_Lines.Element (Base_Pos);
      Base_Count : Natural;
      Variant_Count : Natural;
      pragma Unreferenced (Variant_Pos);
   begin
      case Algorithm is
         when Diff_Algorithm_Default | Diff_Algorithm_Myers
            | Diff_Algorithm_Minimal =>
            return True;

         when Diff_Algorithm_Patience =>
            return Line_Count (Base_Lines, Text) = 1
              and then Line_Count (Variant_Lines, Text) = 1;

         when Diff_Algorithm_Histogram =>
            Base_Count := Line_Count (Base_Lines, Text);
            Variant_Count := Line_Count (Variant_Lines, Text);
            return Base_Count > 0
              and then Variant_Count > 0
              and then Base_Count * Variant_Count <= 16;
      end case;
   end Match_Allowed;

   function LCS_Matches
     (Base_Lines    : Line_Vectors.Vector;
      Variant_Lines : Line_Vectors.Vector;
      Algorithm     : Diff_Algorithm) return Match_Pair_Vectors.Vector
   is
      Base_Length    : constant Natural := Natural (Base_Lines.Length);
      Variant_Length : constant Natural := Natural (Variant_Lines.Length);
      Result         : Match_Pair_Vectors.Vector;
   begin
      if Base_Length = 0 or else Variant_Length = 0
        or else Base_Length > 700 or else Variant_Length > 700
      then
         return Result;
      end if;

      declare
         type Natural_Matrix is array (Natural range <>, Natural range <>) of Natural;
         Scores : Natural_Matrix (0 .. Base_Length, 0 .. Variant_Length) :=
           [others => [others => 0]];
      begin
         for I in reverse 0 .. Base_Length - 1 loop
            for J in reverse 0 .. Variant_Length - 1 loop
               if Base_Lines.Element (I) = Variant_Lines.Element (J)
                 and then Match_Allowed
                   (Base_Lines    => Base_Lines,
                    Variant_Lines => Variant_Lines,
                    Base_Pos      => I,
                    Variant_Pos   => J,
                    Algorithm     => Algorithm)
               then
                  Scores (I, J) := Scores (I + 1, J + 1) + 1;
               elsif Scores (I + 1, J) >= Scores (I, J + 1) then
                  Scores (I, J) := Scores (I + 1, J);
               else
                  Scores (I, J) := Scores (I, J + 1);
               end if;
            end loop;
         end loop;

         declare
            I : Natural := 0;
            J : Natural := 0;
         begin
            while I < Base_Length and then J < Variant_Length loop
               if Base_Lines.Element (I) = Variant_Lines.Element (J)
                 and then Match_Allowed
                   (Base_Lines    => Base_Lines,
                    Variant_Lines => Variant_Lines,
                    Base_Pos      => I,
                    Variant_Pos   => J,
                    Algorithm     => Algorithm)
                 and then Scores (I, J) = Scores (I + 1, J + 1) + 1
               then
                  Result.Append
                    (Match_Pair'
                       (Base_Pos    => I,
                        Variant_Pos => J));
                  I := I + 1;
                  J := J + 1;
               elsif Scores (I + 1, J) >= Scores (I, J + 1) then
                  I := I + 1;
               else
                  J := J + 1;
               end if;
            end loop;
         end;
      end;

      return Result;
   end LCS_Matches;

   function Diff_Edits
     (Base_Lines    : Line_Vectors.Vector;
      Variant_Lines : Line_Vectors.Vector;
      Algorithm     : Diff_Algorithm) return Edit_Span_Vectors.Vector
   is
      Matches : constant Match_Pair_Vectors.Vector :=
        LCS_Matches
          (Base_Lines    => Base_Lines,
           Variant_Lines => Variant_Lines,
           Algorithm     => Algorithm);
      Result : Edit_Span_Vectors.Vector;
      Base_Cursor    : Natural := 0;
      Variant_Cursor : Natural := 0;
      Base_Length    : constant Natural := Natural (Base_Lines.Length);
      Variant_Length : constant Natural := Natural (Variant_Lines.Length);

      procedure Append_Edit
        (Base_First    : Natural;
         Base_After    : Natural;
         Variant_First : Natural;
         Variant_After : Natural) is
      begin
         if Base_First /= Base_After or else Variant_First /= Variant_After then
            Result.Append
              (Edit_Span'
                 (Base_First    => Base_First,
                  Base_After    => Base_After,
                  Variant_First => Variant_First,
                  Variant_After => Variant_After));
         end if;
      end Append_Edit;
   begin
      if not Matches.Is_Empty then
         for I in Matches.First_Index .. Matches.Last_Index loop
            declare
               Match : constant Match_Pair := Matches.Element (I);
            begin
               Append_Edit
                 (Base_First    => Base_Cursor,
                  Base_After    => Match.Base_Pos,
                  Variant_First => Variant_Cursor,
                  Variant_After => Match.Variant_Pos);
               Base_Cursor := Match.Base_Pos + 1;
               Variant_Cursor := Match.Variant_Pos + 1;
            end;
         end loop;
      end if;

      Append_Edit
        (Base_First    => Base_Cursor,
         Base_After    => Base_Length,
         Variant_First => Variant_Cursor,
         Variant_After => Variant_Length);
      return Result;
   end Diff_Edits;

   function Try_Script_Text_Merge
     (Base_Lines    : Line_Vectors.Vector;
      Current_Lines : Line_Vectors.Vector;
      Target_Lines  : Line_Vectors.Vector;
      Algorithm     : Diff_Algorithm;
      Merged        : out Unbounded_String) return Boolean
   is
      Current_Edits : constant Edit_Span_Vectors.Vector :=
        Diff_Edits
          (Base_Lines    => Base_Lines,
           Variant_Lines => Current_Lines,
           Algorithm     => Algorithm);
      Target_Edits : constant Edit_Span_Vectors.Vector :=
        Diff_Edits
          (Base_Lines    => Base_Lines,
           Variant_Lines => Target_Lines,
           Algorithm     => Algorithm);
      Current_Index : Natural := 0;
      Target_Index  : Natural := 0;
      Base_Cursor   : Natural := 0;
      Base_Length   : constant Natural := Natural (Base_Lines.Length);

      procedure Apply_Edit
        (Span          : Edit_Span;
         Variant_Lines : Line_Vectors.Vector) is
      begin
         if Span.Base_First < Base_Cursor then
            Merged := Null_Unbounded_String;
            raise Constraint_Error;
         end if;

         Append_Line_Range (Merged, Base_Lines, Base_Cursor, Span.Base_First);
         Append_Line_Range
           (Merged, Variant_Lines, Span.Variant_First, Span.Variant_After);
         Base_Cursor := Span.Base_After;
      end Apply_Edit;

      function Same_Replacement
        (Current_Span : Edit_Span;
         Target_Span  : Edit_Span) return Boolean is
      begin
         return Replacement_Equal
           (Current_Lines,
            Current_Span.Variant_First,
            Current_Span.Variant_After,
            Target_Lines,
            Target_Span.Variant_First,
            Target_Span.Variant_After);
      end Same_Replacement;
   begin
      Merged := Null_Unbounded_String;

      while Current_Index < Natural (Current_Edits.Length)
        or else Target_Index < Natural (Target_Edits.Length)
      loop
         if Current_Index >= Natural (Current_Edits.Length) then
            Apply_Edit (Target_Edits.Element (Target_Index), Target_Lines);
            Target_Index := Target_Index + 1;
         elsif Target_Index >= Natural (Target_Edits.Length) then
            Apply_Edit (Current_Edits.Element (Current_Index), Current_Lines);
            Current_Index := Current_Index + 1;
         else
            declare
               Current_Span : constant Edit_Span :=
                 Current_Edits.Element (Current_Index);
               Target_Span : constant Edit_Span :=
                 Target_Edits.Element (Target_Index);
            begin
               if Current_Span.Base_First = Current_Span.Base_After
                 and then Target_Span.Base_First = Target_Span.Base_After
                 and then Current_Span.Base_First = Target_Span.Base_First
               then
                  if not Same_Replacement (Current_Span, Target_Span) then
                     Merged := Null_Unbounded_String;
                     return False;
                  end if;

                  Apply_Edit (Current_Span, Current_Lines);
                  Current_Index := Current_Index + 1;
                  Target_Index := Target_Index + 1;
               elsif Current_Span.Base_After <= Target_Span.Base_First then
                  Apply_Edit (Current_Span, Current_Lines);
                  Current_Index := Current_Index + 1;
               elsif Target_Span.Base_After <= Current_Span.Base_First then
                  Apply_Edit (Target_Span, Target_Lines);
                  Target_Index := Target_Index + 1;
               elsif Current_Span.Base_First = Target_Span.Base_First
                 and then Current_Span.Base_After = Target_Span.Base_After
                 and then Same_Replacement (Current_Span, Target_Span)
               then
                  Apply_Edit (Current_Span, Current_Lines);
                  Current_Index := Current_Index + 1;
                  Target_Index := Target_Index + 1;
               else
                  Merged := Null_Unbounded_String;
                  return False;
               end if;
            end;
         end if;
      end loop;

      Append_Line_Range (Merged, Base_Lines, Base_Cursor, Base_Length);
      return True;
   exception
      when Constraint_Error =>
         Merged := Null_Unbounded_String;
         return False;
   end Try_Script_Text_Merge;

   function Try_Auto_Text_Merge
     (Base     : String;
      Current  : String;
      Target   : String;
      Behavior : Merge_Behavior;
      Merged   : out Unbounded_String) return Boolean
   is
      Base_Lines    : constant Line_Vectors.Vector := Split_Lines (Base);
      Current_Lines : constant Line_Vectors.Vector := Split_Lines (Current);
      Target_Lines  : constant Line_Vectors.Vector := Split_Lines (Target);

      Base_Length    : constant Natural := Natural (Base_Lines.Length);
      Current_Length : constant Natural := Natural (Current_Lines.Length);
      Target_Length  : constant Natural := Natural (Target_Lines.Length);

      Current_Prefix : constant Natural :=
        Common_Prefix_Count (Base_Lines, Current_Lines);
      Target_Prefix : constant Natural :=
        Common_Prefix_Count (Base_Lines, Target_Lines);
      Current_Suffix : constant Natural :=
        Common_Suffix_Count (Base_Lines, Current_Lines, Current_Prefix);
      Target_Suffix : constant Natural :=
        Common_Suffix_Count (Base_Lines, Target_Lines, Target_Prefix);

      Current_First : constant Natural := Current_Prefix;
      Current_After : constant Natural := Base_Length - Current_Suffix;
      Target_First  : constant Natural := Target_Prefix;
      Target_After  : constant Natural := Base_Length - Target_Suffix;

      Current_Replacement_After : constant Natural :=
        Current_Length - Current_Suffix;
      Target_Replacement_After : constant Natural :=
        Target_Length - Target_Suffix;
   begin
      Merged := Null_Unbounded_String;

      if Equivalent_Text (Base, Current, Behavior) then
         Merged := To_Unbounded_String (Target);
         return True;
      elsif Equivalent_Text (Base, Target, Behavior)
        or else Equivalent_Text (Current, Target, Behavior)
      then
         Merged := To_Unbounded_String (Current);
         return True;
      elsif Try_Linewise_Text_Merge
        (Base_Lines    => Base_Lines,
         Current_Lines => Current_Lines,
         Target_Lines  => Target_Lines,
         Merged        => Merged)
      then
         return True;
      end if;

      if Current_First = Target_First
        and then Current_After = Target_After
        and then Replacement_Equal
          (Current_Lines,
           Current_Prefix,
           Current_Replacement_After,
           Target_Lines,
           Target_Prefix,
           Target_Replacement_After)
      then
         Append_Line_Range (Merged, Base_Lines, 0, Current_First);
         Append_Line_Range
           (Merged, Current_Lines, Current_Prefix, Current_Replacement_After);
         Append_Line_Range (Merged, Base_Lines, Current_After, Base_Length);
         return True;
      elsif Current_After <= Target_First then
         Append_Line_Range (Merged, Base_Lines, 0, Current_First);
         Append_Line_Range
           (Merged, Current_Lines, Current_Prefix, Current_Replacement_After);
         Append_Line_Range (Merged, Base_Lines, Current_After, Target_First);
         Append_Line_Range
           (Merged, Target_Lines, Target_Prefix, Target_Replacement_After);
         Append_Line_Range (Merged, Base_Lines, Target_After, Base_Length);
         return True;
      elsif Target_After <= Current_First then
         Append_Line_Range (Merged, Base_Lines, 0, Target_First);
         Append_Line_Range
           (Merged, Target_Lines, Target_Prefix, Target_Replacement_After);
         Append_Line_Range (Merged, Base_Lines, Target_After, Current_First);
         Append_Line_Range
           (Merged, Current_Lines, Current_Prefix, Current_Replacement_After);
         Append_Line_Range (Merged, Base_Lines, Current_After, Base_Length);
         return True;
      elsif Try_Script_Text_Merge
          (Base_Lines    => Base_Lines,
           Current_Lines => Current_Lines,
           Target_Lines  => Target_Lines,
           Algorithm     => Behavior.Algorithm,
           Merged        => Merged)
      then
         return True;
      else
         return False;
      end if;
   end Try_Auto_Text_Merge;

   function ZDiff3_Conflict_Text
     (Current_Name : String;
      Current_Text : String;
      Base_Name    : String;
      Base_Text    : String;
      Target_Name  : String;
      Target_Text  : String;
      Behavior     : Merge_Behavior) return String
   is
      Current_Lines : constant Line_Vectors.Vector := Split_Lines (Current_Text);
      Base_Lines    : constant Line_Vectors.Vector := Split_Lines (Base_Text);
      Target_Lines  : constant Line_Vectors.Vector := Split_Lines (Target_Text);
      Current_Length : constant Natural := Natural (Current_Lines.Length);
      Base_Length    : constant Natural := Natural (Base_Lines.Length);
      Target_Length  : constant Natural := Natural (Target_Lines.Length);
      Prefix : Natural := 0;
      Suffix : Natural := 0;
      Result : Unbounded_String;
   begin
      while Prefix < Current_Length
        and then Prefix < Base_Length
        and then Prefix < Target_Length
        and then Current_Lines.Element (Prefix) = Base_Lines.Element (Prefix)
        and then Current_Lines.Element (Prefix) = Target_Lines.Element (Prefix)
      loop
         Prefix := Prefix + 1;
      end loop;

      while Suffix < Current_Length - Prefix
        and then Suffix < Base_Length - Prefix
        and then Suffix < Target_Length - Prefix
        and then Current_Lines.Element (Current_Length - Suffix - 1)
                 = Base_Lines.Element (Base_Length - Suffix - 1)
        and then Current_Lines.Element (Current_Length - Suffix - 1)
                 = Target_Lines.Element (Target_Length - Suffix - 1)
      loop
         Suffix := Suffix + 1;
      end loop;

      Append_Line_Range (Result, Current_Lines, 0, Prefix);
      Append
        (Result,
         Conflict_Text
           (Current_Name => Current_Name,
            Current_Text => Line_Range_Text
              (Current_Lines, Prefix, Current_Length - Suffix),
            Base_Name    => Base_Name,
            Base_Text    => Line_Range_Text
              (Base_Lines, Prefix, Base_Length - Suffix),
            Has_Base     => True,
            Target_Name  => Target_Name,
            Target_Text  => Line_Range_Text
              (Target_Lines, Prefix, Target_Length - Suffix),
            Behavior     => Merge_Behavior'
              (Favor            => Behavior.Favor,
               Style            => Conflict_Style_Diff3,
               Marker_Size      => Behavior.Marker_Size,
               Detect_Renames   => Behavior.Detect_Renames,
               Rename_Threshold => Behavior.Rename_Threshold,
               Rename_Limit     => Behavior.Rename_Limit,
               Detect_Copies    => Behavior.Detect_Copies,
               Directory_Renames => Behavior.Directory_Renames,
               Recurse_Submodules => Behavior.Recurse_Submodules,
               Renormalize      => Behavior.Renormalize,
               Whitespace       => Behavior.Whitespace,
               Algorithm        => Behavior.Algorithm,
               Enable_Rerere    => Behavior.Enable_Rerere,
               Update_Worktree  => Behavior.Update_Worktree,
               Materialize_Virtual_Conflicts => Behavior.Materialize_Virtual_Conflicts)));
      Append_Line_Range
        (Result, Current_Lines, Current_Length - Suffix, Current_Length);
      return To_String (Result);
   end ZDiff3_Conflict_Text;

   function Has_Directory_File_Conflict
     (Path          : String;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector) return Boolean is
   begin
      return Has_Path_Prefix (Current_Items, Path)
        or else Has_Path_Prefix (Target_Items, Path)
        or else Has_Ancestor_File (Current_Items, Path)
        or else Has_Ancestor_File (Target_Items, Path);
   end Has_Directory_File_Conflict;

   function Mode_Text (Item : Version.Objects.Tree_Entry) return String is
   begin
      return To_String (Item.Mode);
   end Mode_Text;

   function Is_Gitlink (Item : Version.Objects.Tree_Entry) return Boolean is
   begin
      return Item.Kind = Version.Objects.Tree_Gitlink
        or else Mode_Text (Item) = "160000";
   end Is_Gitlink;

   function Is_Symlink_Mode (Mode : String) return Boolean is
   begin
      return Mode = "120000";
   end Is_Symlink_Mode;

   function Same_Entry
     (Left, Right : Version.Objects.Tree_Entry) return Boolean is
   begin
      return Left.Id = Right.Id and then Mode_Text (Left) = Mode_Text (Right);
   end Same_Entry;

   function Is_Regular_File_Mode (Mode : String) return Boolean is
   begin
      return Mode = "100644" or else Mode = "100755";
   end Is_Regular_File_Mode;

   procedure Apply_Worktree_File_Mode
     (Path : String;
      Mode : String)
   is
   begin
      if Mode = "100755" and then Version.Platform.Supports_Executable_Bit then
         GNAT.OS_Lib.Set_Executable (Version.Files.To_Native_Path (Path));
      end if;
   end Apply_Worktree_File_Mode;

   function Rename_Modes_Compatible
     (Left, Right : Version.Objects.Tree_Entry) return Boolean
   is
      Left_Mode  : constant String := Mode_Text (Left);
      Right_Mode : constant String := Mode_Text (Right);
   begin
      return Left_Mode = Right_Mode
        or else (Is_Regular_File_Mode (Left_Mode)
                 and then Is_Regular_File_Mode (Right_Mode));
   end Rename_Modes_Compatible;

   function Merged_Content_Mode
     (Base_Item    : Version.Objects.Tree_Entry;
      Has_Base     : Boolean;
      Current_Item : Version.Objects.Tree_Entry;
      Target_Item  : Version.Objects.Tree_Entry) return Unbounded_String
   is
      Current_Mode : constant String := Mode_Text (Current_Item);
      Target_Mode  : constant String := Mode_Text (Target_Item);
   begin
      if Has_Base then
         declare
            Base_Mode : constant String := Mode_Text (Base_Item);
         begin
            if Current_Mode = Target_Mode then
               return Current_Item.Mode;
            elsif Is_Regular_File_Mode (Base_Mode)
              and then Is_Regular_File_Mode (Current_Mode)
              and then Is_Regular_File_Mode (Target_Mode)
            then
               if Current_Mode = Base_Mode and then Target_Mode /= Base_Mode then
                  return Target_Item.Mode;
               elsif Target_Mode = Base_Mode and then Current_Mode /= Base_Mode then
                  return Current_Item.Mode;
               end if;
            end if;
         end;
      end if;

      return Current_Item.Mode;
   end Merged_Content_Mode;

   function Parent_Directory (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;

      return "";
   end Parent_Directory;

   function Leaf_Name (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;

      return Path;
   end Leaf_Name;

   function Is_Under_Directory (Path, Dir : String) return Boolean is
   begin
      if Dir'Length = 0 then
         return Ada.Strings.Fixed.Index (Path, "/") = 0;
      end if;

      return Path'Length > Dir'Length
        and then Path (Path'First .. Path'First + Dir'Length - 1) = Dir
        and then Path (Path'First + Dir'Length) = '/';
   end Is_Under_Directory;

   function Move_Under_Directory
     (Path, Old_Dir, New_Dir : String) return String
   is
      Suffix_First : constant Natural :=
        (if Old_Dir'Length = 0 then Path'First else Path'First + Old_Dir'Length + 1);
      Suffix : constant String := Path (Suffix_First .. Path'Last);
   begin
      if New_Dir'Length = 0 then
         return Suffix;
      else
         return New_Dir & "/" & Suffix;
      end if;
   end Move_Under_Directory;

   function With_Path
     (Item : Version.Objects.Tree_Entry; Path : String)
      return Version.Objects.Tree_Entry is
   begin
      return Version.Objects.Tree_Entry'
        (Path => To_Unbounded_String (Path),
         Id   => Item.Id,
         Kind => Item.Kind,
         Mode => Item.Mode);
   end With_Path;

   function Marker (Ch : Character; Count : Positive) return String is
      Result : String (1 .. Count);
   begin
      for I in Result'Range loop
         Result (I) := Ch;
      end loop;
      return Result;
   end Marker;

   function Last_Component (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (I + 1 .. Path'Last);
         end if;
      end loop;
      return Path;
   end Last_Component;

   function Ends_With (Text, Suffix : String) return Boolean is
   begin
      return Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Ends_With;

   function Pattern_Matches (Pattern, Path : String) return Boolean is
   begin
      if Pattern = "*" then
         return True;
      elsif Pattern'Length > 2
        and then Pattern (Pattern'First) = '*'
        and then Pattern (Pattern'First + 1) = '.'
      then
         return Ends_With (Last_Component (Path),
                           Pattern (Pattern'First + 1 .. Pattern'Last));
      elsif Ends_With (Pattern, "/") then
         return Path'Length > Pattern'Length
           and then Path (Path'First .. Path'First + Pattern'Length - 1) = Pattern;
      elsif Ada.Strings.Fixed.Index (Pattern, "/") = 0 then
         return Last_Component (Path) = Pattern;
      else
         return Path = Pattern;
      end if;
   end Pattern_Matches;

   function Attribute_From_Token (Token : String) return Merge_Attribute is
   begin
      if Token = "merge=ours" then
         return Attribute_Ours;
      elsif Token = "merge=theirs" then
         return Attribute_Theirs;
      elsif Token = "merge=union" then
         return Attribute_Union;
      elsif Token = "merge=text" or else Token = "merge" then
         return Attribute_Text;
      elsif Token = "!merge" then
         return Attribute_Reset;
      elsif Token = "binary" or else Token = "-merge"
        or else Token = "merge=binary"
      then
         return Attribute_Binary;
      else
         return Attribute_Default;
      end if;
   end Attribute_From_Token;

   function Attribute_For_Line (Line, Path : String) return Merge_Attribute is
      First : Natural := Line'First;
      Last  : constant Natural := Line'Last;
   begin
      while First <= Last and then (Line (First) = ' ' or else Line (First) = Character'Val (9)) loop
         First := First + 1;
      end loop;
      if First > Last or else Line (First) = '#' then
         return Attribute_Default;
      end if;

      declare
         Pattern_Last : Natural := First;
      begin
         while Pattern_Last <= Last
           and then Line (Pattern_Last) /= ' '
           and then Line (Pattern_Last) /= Character'Val (9)
         loop
            Pattern_Last := Pattern_Last + 1;
         end loop;

         if not Pattern_Matches (Line (First .. Pattern_Last - 1), Path) then
            return Attribute_Default;
         end if;

         declare
            Pos    : Natural := Pattern_Last;
            Result : Merge_Attribute := Attribute_Default;
         begin
            while Pos <= Last loop
               while Pos <= Last
                 and then (Line (Pos) = ' ' or else Line (Pos) = Character'Val (9))
               loop
                  Pos := Pos + 1;
               end loop;

               exit when Pos > Last;

               declare
                  Token_First : constant Natural := Pos;
               begin
                  while Pos <= Last
                    and then Line (Pos) /= ' '
                    and then Line (Pos) /= Character'Val (9)
                  loop
                     Pos := Pos + 1;
                  end loop;

                  declare
                     Attr : constant Merge_Attribute :=
                       Attribute_From_Token (Line (Token_First .. Pos - 1));
                  begin
                     if Attr /= Attribute_Default then
                        Result := Attr;
                     end if;
                  end;
               end;
            end loop;

            return Result;
         end;
      end;
   end Attribute_For_Line;

   procedure Apply_Attributes_File
     (Attr_Path     : String;
      Relative_Path : String;
      Result        : in out Merge_Attribute) is
   begin
      if not Ada.Directories.Exists (Attr_Path)
        or else Ada.Directories.Kind (Attr_Path) /= Ada.Directories.Ordinary_File
      then
         return;
      end if;

      declare
         Text  : constant String := Version.Files.Read_Binary_File (Attr_Path);
         Start : Natural := Text'First;
      begin
         while Start <= Text'Last loop
            declare
               Stop : Natural := Start;
            begin
               while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
                  Stop := Stop + 1;
               end loop;

               if Stop > Start then
                  declare
                     Line : constant String :=
                       (if Text (Stop - 1) = Character'Val (13)
                        then Text (Start .. Stop - 2)
                        else Text (Start .. Stop - 1));
                     Attr : constant Merge_Attribute :=
                       Attribute_For_Line (Line, Relative_Path);
                  begin
                     if Attr = Attribute_Reset then
                        Result := Attribute_Default;
                     elsif Attr /= Attribute_Default then
                        Result := Attr;
                     end if;
                  end;
               end if;

               Start := Stop + 1;
            end;
         end loop;
      end;
   end Apply_Attributes_File;

   procedure Apply_Worktree_Attributes
     (Repo          : Version.Repository.Repository_Handle;
      Attribute_Dir : String;
      Relative_Path : String;
      Result        : in out Merge_Attribute)
   is
      Attr_Path : constant String :=
        (if Attribute_Dir'Length = 0 then
           Version.Files.Join (Version.Repository.Root_Path (Repo), ".gitattributes")
         else
           Version.Files.Join
             (Version.Files.Join (Version.Repository.Root_Path (Repo), Attribute_Dir),
              ".gitattributes"));
   begin
      Apply_Attributes_File
        (Attr_Path     => Attr_Path,
         Relative_Path => Relative_Path,
         Result        => Result);
   end Apply_Worktree_Attributes;

   function Attribute_For_Path
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Merge_Attribute
   is
      Result : Merge_Attribute := Attribute_Default;
   begin
      Apply_Worktree_Attributes
        (Repo          => Repo,
         Attribute_Dir => "",
         Relative_Path => Path,
         Result        => Result);

      for I in Path'Range loop
         if Path (I) = '/' then
            Apply_Worktree_Attributes
              (Repo          => Repo,
               Attribute_Dir => Path (Path'First .. I - 1),
               Relative_Path => Path (I + 1 .. Path'Last),
               Result        => Result);
         end if;
      end loop;

      Apply_Attributes_File
        (Attr_Path     => Version.Files.Join
           (Version.Files.Join (Version.Repository.Git_Dir (Repo), "info"),
            "attributes"),
         Relative_Path => Path,
         Result        => Result);

      return Result;
   end Attribute_For_Path;

   function Driver_Name_From_Token (Token : String) return String is
   begin
      if Token'Length > 6
        and then Token (Token'First .. Token'First + 5) = "merge="
      then
         declare
            Name : constant String := Token (Token'First + 6 .. Token'Last);
         begin
            if Name = "ours" or else Name = "theirs" or else Name = "union"
              or else Name = "text" or else Name = "binary"
            then
               return "";
            else
               return Name;
            end if;
         end;
      elsif Token = "merge" or else Token = "-merge"
        or else Token = "binary"
      then
         return "";
      else
         return "";
      end if;
   end Driver_Name_From_Token;

   function Driver_For_Line (Line, Path : String) return String is
      First : Natural := Line'First;
      Last  : constant Natural := Line'Last;
   begin
      while First <= Last and then (Line (First) = ' ' or else Line (First) = Character'Val (9)) loop
         First := First + 1;
      end loop;
      if First > Last or else Line (First) = '#' then
         return "";
      end if;

      declare
         Pattern_Last : Natural := First;
      begin
         while Pattern_Last <= Last
           and then Line (Pattern_Last) /= ' '
           and then Line (Pattern_Last) /= Character'Val (9)
         loop
            Pattern_Last := Pattern_Last + 1;
         end loop;

         if not Pattern_Matches (Line (First .. Pattern_Last - 1), Path) then
            return "";
         end if;

         declare
            Pos    : Natural := Pattern_Last;
            Result : Unbounded_String;
         begin
            while Pos <= Last loop
               while Pos <= Last
                 and then (Line (Pos) = ' ' or else Line (Pos) = Character'Val (9))
               loop
                  Pos := Pos + 1;
               end loop;

               exit when Pos > Last;

               declare
                  Token_First : constant Natural := Pos;
               begin
                  while Pos <= Last
                    and then Line (Pos) /= ' '
                    and then Line (Pos) /= Character'Val (9)
                  loop
                     Pos := Pos + 1;
                  end loop;

                  declare
                     Token : constant String := Line (Token_First .. Pos - 1);
                     Driver : constant String := Driver_Name_From_Token (Token);
                  begin
                     if Token = "merge" or else Token = "merge=text"
                       or else Token = "-merge" or else Token = "!merge"
                       or else Token = "binary" or else Token = "merge=binary"
                     then
                        Result := Null_Unbounded_String;
                     elsif Driver'Length > 0 then
                        Result := To_Unbounded_String (Driver);
                     end if;
                  end;
               end;
            end loop;

            return To_String (Result);
         end;
      end;
   end Driver_For_Line;

   procedure Apply_Driver_Attributes_File
     (Attr_Path     : String;
      Relative_Path : String;
      Result        : in out Unbounded_String) is
   begin
      if not Ada.Directories.Exists (Attr_Path)
        or else Ada.Directories.Kind (Attr_Path) /= Ada.Directories.Ordinary_File
      then
         return;
      end if;

      declare
         Text  : constant String := Version.Files.Read_Binary_File (Attr_Path);
         Start : Natural := Text'First;
      begin
         while Start <= Text'Last loop
            declare
               Stop : Natural := Start;
            begin
               while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
                  Stop := Stop + 1;
               end loop;

               if Stop > Start then
                  declare
                     Line : constant String :=
                       (if Text (Stop - 1) = Character'Val (13)
                        then Text (Start .. Stop - 2)
                        else Text (Start .. Stop - 1));
                     Driver : constant String := Driver_For_Line (Line, Relative_Path);
                  begin
                     if Driver'Length > 0 then
                        Result := To_Unbounded_String (Driver);
                     elsif Attribute_For_Line (Line, Relative_Path) /= Attribute_Default then
                        Result := Null_Unbounded_String;
                     end if;
                  end;
               end if;

               Start := Stop + 1;
            end;
         end loop;
      end;
   end Apply_Driver_Attributes_File;

   procedure Apply_Worktree_Driver_Attributes
     (Repo          : Version.Repository.Repository_Handle;
      Attribute_Dir : String;
      Relative_Path : String;
      Result        : in out Unbounded_String)
   is
      Attr_Path : constant String :=
        (if Attribute_Dir'Length = 0 then
           Version.Files.Join (Version.Repository.Root_Path (Repo), ".gitattributes")
         else
           Version.Files.Join
             (Version.Files.Join (Version.Repository.Root_Path (Repo), Attribute_Dir),
              ".gitattributes"));
   begin
      Apply_Driver_Attributes_File
        (Attr_Path     => Attr_Path,
         Relative_Path => Relative_Path,
         Result        => Result);
   end Apply_Worktree_Driver_Attributes;

   function Merge_Driver_For_Path
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Result : Unbounded_String;
   begin
      Apply_Worktree_Driver_Attributes
        (Repo          => Repo,
         Attribute_Dir => "",
         Relative_Path => Path,
         Result        => Result);

      for I in Path'Range loop
         if Path (I) = '/' then
            Apply_Worktree_Driver_Attributes
              (Repo          => Repo,
               Attribute_Dir => Path (Path'First .. I - 1),
               Relative_Path => Path (I + 1 .. Path'Last),
               Result        => Result);
         end if;
      end loop;

      Apply_Driver_Attributes_File
        (Attr_Path     => Version.Files.Join
           (Version.Files.Join (Version.Repository.Git_Dir (Repo), "info"),
            "attributes"),
         Relative_Path => Path,
         Result        => Result);

      return To_String (Result);
   end Merge_Driver_For_Path;

   function Normalize_Text
     (Text : String; Behavior : Merge_Behavior) return String
   is
      Result : Unbounded_String;
      Last_Was_Space : Boolean := False;

      procedure Append_Normalized (C : Character) is
      begin
         case Behavior.Whitespace is
            when Whitespace_Strict =>
               Append (Result, C);
            when Whitespace_Ignore_All_Space =>
               if C /= ' ' and then C /= Character'Val (9) then
                  Append (Result, C);
               end if;
            when Whitespace_Ignore_Space_Change =>
               if C = ' ' or else C = Character'Val (9) then
                  if not Last_Was_Space then
                     Append (Result, ' ');
                  end if;
                  Last_Was_Space := True;
               else
                  Append (Result, C);
                  Last_Was_Space := False;
               end if;
            when Whitespace_Ignore_Space_At_EOL =>
               Append (Result, C);
            when Whitespace_Ignore_CR_At_EOL =>
               Append (Result, C);
         end case;
      end Append_Normalized;
   begin
      for I in Text'Range loop
         if Behavior.Renormalize and then Text (I) = Character'Val (13) then
            if I = Text'Last or else Text (I + 1) /= Character'Val (10) then
               Append_Normalized (Character'Val (10));
            end if;
         else
            Append_Normalized (Text (I));
         end if;
      end loop;

      if Behavior.Whitespace = Whitespace_Ignore_Space_At_EOL then
         declare
            Raw : constant String := To_String (Result);
            Clean : Unbounded_String;
            Pending : Unbounded_String;
         begin
            for C of Raw loop
               if C = ' ' or else C = Character'Val (9) then
                  Append (Pending, C);
               elsif C = Character'Val (10) then
                  Pending := Null_Unbounded_String;
                  Append (Clean, C);
               else
                  Append (Clean, To_String (Pending));
                  Pending := Null_Unbounded_String;
                  Append (Clean, C);
               end if;
            end loop;
            Append (Clean, To_String (Pending));
            return To_String (Clean);
         end;
      elsif Behavior.Whitespace = Whitespace_Ignore_CR_At_EOL then
         declare
            Raw : constant String := To_String (Result);
            Clean : Unbounded_String;
         begin
            for I in Raw'Range loop
               if Raw (I) = Character'Val (13)
                 and then (I = Raw'Last or else Raw (I + 1) = Character'Val (10))
               then
                  null;
               else
                  Append (Clean, Raw (I));
               end if;
            end loop;
            return To_String (Clean);
         end;
      end if;

      return To_String (Result);
   end Normalize_Text;

   function Equivalent_Text
     (Left, Right : String; Behavior : Merge_Behavior) return Boolean is
   begin
      return Normalize_Text (Left, Behavior) = Normalize_Text (Right, Behavior);
   end Equivalent_Text;

   function Blob_Text_For_Similarity
     (Repo  : Version.Repository.Repository_Handle;
      Item  : Version.Objects.Tree_Entry;
      Found : out Boolean) return String is
   begin
      if Is_Gitlink (Item) then
         Found := False;
         return "";
      end if;

      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Item.Id);
      begin
         Found := Version.Objects.Kind (Obj) = Version.Objects.Blob_Object;
         if Found then
            return Version.Objects.Content (Obj);
         else
            return "";
         end if;
      end;
   exception
      when others =>
         Found := False;
         return "";
   end Blob_Text_For_Similarity;

   function Text_Similarity (Left, Right : String) return Natural is
      Left_Lines   : constant Line_Vectors.Vector := Split_Lines (Left);
      Right_Lines  : constant Line_Vectors.Vector := Split_Lines (Right);
      Left_Length  : constant Natural := Natural (Left_Lines.Length);
      Right_Length : constant Natural := Natural (Right_Lines.Length);
      type Boolean_Array is array (Natural range <>) of Boolean;
   begin
      if Left = Right then
         return 100;
      elsif Left_Length = 0 or else Right_Length = 0 then
         return 0;
      end if;

      declare
         Used   : Boolean_Array (0 .. Right_Length - 1) := [others => False];
         Common : Natural := 0;
      begin
         for I in 0 .. Left_Length - 1 loop
            for J in 0 .. Right_Length - 1 loop
               if not Used (J)
                 and then Left_Lines.Element (I) = Right_Lines.Element (J)
               then
                  Used (J) := True;
                  Common := Common + 1;
                  exit;
               end if;
            end loop;
         end loop;

         return Natural'Min (100, (Common * 200) / (Left_Length + Right_Length));
      end;
   end Text_Similarity;

   function Rename_Similarity
     (Repo  : Version.Repository.Repository_Handle;
      Left  : Version.Objects.Tree_Entry;
      Right : Version.Objects.Tree_Entry) return Natural
   is
      Left_Found  : Boolean := False;
      Right_Found : Boolean := False;
      Left_Text : constant String :=
        Blob_Text_For_Similarity (Repo, Left, Left_Found);
      Right_Text : constant String :=
        Blob_Text_For_Similarity (Repo, Right, Right_Found);
   begin
      if not Left_Found or else not Right_Found then
         return 0;
      elsif not Rename_Modes_Compatible (Left, Right) then
         return 0;
      else
         return Text_Similarity (Left_Text, Right_Text);
      end if;
   end Rename_Similarity;

   function Union_Text (Left, Right : String) return String is
   begin
      if Left'Length = 0 then
         return With_Trailing_Newline (Right);
      elsif Right'Length = 0 or else Left = Right then
         return With_Trailing_Newline (Left);
      else
         return With_Trailing_Newline (Left) & With_Trailing_Newline (Right);
      end if;
   end Union_Text;

   procedure Add_Conflict
     (Conflicts : in out Conflict_Vectors.Vector;
      Path      : String;
      Kind      : Conflict_Kind) is
   begin
      Require_Safe_Path (Path);

      if not Conflicts.Is_Empty then
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            declare
               Existing : constant Conflict := Conflicts.Element (I);
            begin
               if To_String (Existing.Path) = Path and then Existing.Kind = Kind then
                  return;
               end if;
            end;
         end loop;
      end if;

      Conflicts.Append
        (Conflict'
           (Path => To_Unbounded_String (Path),
            Kind => Kind));
   end Add_Conflict;

   procedure Remove_Index_Path
     (Result : in out Version.Staging.Index_Entry_Vectors.Vector;
      Path   : String)
   is
   begin
      if Result.Is_Empty then
         return;
      end if;

      declare
         I : Natural := Result.First_Index;
      begin
         while I <= Result.Last_Index loop
            if To_String (Result.Element (I).Path) = Path then
               Result.Delete (I);
               if Result.Is_Empty then
                  return;
               end if;
            else
               I := I + 1;
            end if;
         end loop;
      end;
   end Remove_Index_Path;

   procedure Add_Merged_Path
     (Result : in out Version.Staging.Index_Entry_Vectors.Vector;
      Item   : Version.Objects.Tree_Entry) is
      Path_Text : constant String := To_String (Item.Path);
   begin
      Require_Safe_Path (Path_Text);
      Remove_Index_Path (Result, Path_Text);

      Result.Append
        (Version.Staging.Index_Entry'
           (Path  => Item.Path,
            Id    => Item.Id,
            Mode  => Item.Mode,
            Stage => 0));
   end Add_Merged_Path;

   procedure Add_Staged_Conflict_Path
     (Result : in out Version.Staging.Index_Entry_Vectors.Vector;
      Item   : Version.Objects.Tree_Entry;
      Stage  : Natural)
   is
      Path_Text : constant String := To_String (Item.Path);
   begin
      Require_Safe_Path (Path_Text);

      if not Result.Is_Empty then
         for I in Result.First_Index .. Result.Last_Index loop
            if To_String (Result.Element (I).Path) = Path_Text
              and then Result.Element (I).Stage = Stage
            then
               Result.Replace_Element
                 (I,
                  Version.Staging.Index_Entry'
                    (Path  => Item.Path,
                     Id    => Item.Id,
                     Mode  => Item.Mode,
                     Stage => Stage));
               return;
            end if;
         end loop;
      end if;

      Result.Append
        (Version.Staging.Index_Entry'
           (Path  => Item.Path,
            Id    => Item.Id,
            Mode  => Item.Mode,
            Stage => Stage));
   end Add_Staged_Conflict_Path;

   function With_Trailing_Newline (Text : String) return String is
   begin
      if Text'Length = 0 then
         return "";
      elsif Text (Text'Last) = Character'Val (10) then
         return Text;
      else
         return Text & Character'Val (10);
      end if;
   end With_Trailing_Newline;

   function Conflict_Text
     (Current_Name : String;
      Current_Text : String;
      Base_Name    : String;
      Base_Text    : String;
      Has_Base     : Boolean;
      Target_Name  : String;
      Target_Text  : String;
      Behavior     : Merge_Behavior) return String
   is
      Left_Marker  : constant String := Marker ('<', Behavior.Marker_Size);
      Base_Marker  : constant String := Marker ('|', Behavior.Marker_Size);
      Mid_Marker   : constant String := Marker ('=', Behavior.Marker_Size);
      Right_Marker : constant String := Marker ('>', Behavior.Marker_Size);
   begin
      if Has_Base and then Behavior.Style = Conflict_Style_ZDiff3 then
         return ZDiff3_Conflict_Text
           (Current_Name => Current_Name,
            Current_Text => Current_Text,
            Base_Name    => Base_Name,
            Base_Text    => Base_Text,
            Target_Name  => Target_Name,
            Target_Text  => Target_Text,
            Behavior     => Behavior);
      elsif Has_Base and then Behavior.Style = Conflict_Style_Diff3 then
         return
           Left_Marker & " " & Current_Name & Character'Val (10)
           & With_Trailing_Newline (Current_Text)
           & Base_Marker & " " & Base_Name & Character'Val (10)
           & With_Trailing_Newline (Base_Text)
           & Mid_Marker & Character'Val (10)
           & With_Trailing_Newline (Target_Text)
           & Right_Marker & " " & Target_Name & Character'Val (10);
      else
         return
           Left_Marker & " " & Current_Name & Character'Val (10)
           & With_Trailing_Newline (Current_Text)
           & Mid_Marker & Character'Val (10)
           & With_Trailing_Newline (Target_Text)
           & Right_Marker & " " & Target_Name & Character'Val (10);
      end if;
   end Conflict_Text;

   function Rerere_Enabled
     (Repo : Version.Repository.Repository_Handle;
      Behavior : Merge_Behavior) return Boolean
   is
   begin
      if Behavior.Enable_Rerere then
         return True;
      end if;

      return Config_True (Version.Config.Get_Value (Repo, "rerere.enabled"))
        or else Config_True (Version.Config.Get_Value (Repo, "rerere.autoupdate"));
   exception
      when others =>
         return False;
   end Rerere_Enabled;

   function Rerere_Key
     (Base_Id    : String;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id) return String
   is
      Current_Text : constant String := To_String (Current_Id);
      Target_Text  : constant String := To_String (Target_Id);
   begin
      if Current_Text <= Target_Text then
         return Version.Hash.Sha1_Hex
           (Base_Id & ":" & Current_Text & ":" & Target_Text);
      else
         return Version.Hash.Sha1_Hex
           (Base_Id & ":" & Target_Text & ":" & Current_Text);
      end if;
   end Rerere_Key;

   function Rerere_Postimage_Path
     (Repo : Version.Repository.Repository_Handle; Key : String) return String
   is
   begin
      return Version.Files.Join
        (Version.Files.Join
           (Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "rr-cache"),
            Key),
         "postimage");
   end Rerere_Postimage_Path;

   function Rerere_Preimage_Path
     (Repo : Version.Repository.Repository_Handle; Key : String) return String
   is
   begin
      return Version.Files.Join
        (Version.Files.Join
           (Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "rr-cache"),
            Key),
         "preimage");
   end Rerere_Preimage_Path;

   function Merge_RR_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Version.Files.Join
        (Version.Repository.Common_Git_Dir (Repo), "MERGE_RR");
   end Merge_RR_Path;

   --  Append a path -> rr-cache key mapping so the postimage recorded on
   --  --continue lands under the same key the preimage used (Git's MERGE_RR).
   procedure Record_Merge_RR_Entry
     (Repo : Version.Repository.Repository_Handle; Key : String; Path : String)
   is
      MR       : constant String := Merge_RR_Path (Repo);
      Existing : constant String :=
        (if Ada.Directories.Exists (MR)
         then Version.Files.Read_Binary_File (MR) else "");
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => MR,
         Content => Existing & Key & Character'Val (9) & Path & Character'Val (10));
   end Record_Merge_RR_Entry;

   procedure Record_Rerere_Preimage
     (Repo     : Version.Repository.Repository_Handle;
      Rel_Path : String;
      Base_Id  : String;
      Current  : Version.Objects.Hex_Object_Id;
      Target   : Version.Objects.Hex_Object_Id;
      Content  : String;
      Behavior : Merge_Behavior)
   is
      Key : constant String :=
        Rerere_Key
          (Base_Id    => Base_Id,
           Current_Id => Current,
           Target_Id  => Target);
      Dir : constant String :=
        Version.Files.Join
          (Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "rr-cache"),
           Key);
      Path : constant String := Rerere_Preimage_Path (Repo, Key);
   begin
      if not Behavior.Update_Worktree or else not Rerere_Enabled (Repo, Behavior)
      then
         return;
      end if;

      Ada.Directories.Create_Path (Dir);
      if not Ada.Directories.Exists (Path) then
         Version.Files.Write_Binary_File_Atomic (Path => Path, Content => Content);
      end if;
      Record_Merge_RR_Entry (Repo, Key, Rel_Path);
   end Record_Rerere_Preimage;

   function Has_Conflict_Markers (Content : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Content, "<<<<<<<") /= 0
        or else Ada.Strings.Fixed.Index (Content, "=======") /= 0
        or else Ada.Strings.Fixed.Index (Content, ">>>>>>>") /= 0;
   end Has_Conflict_Markers;

   function Rerere_Postimage_For_Preimage
     (Repo    : Version.Repository.Repository_Handle;
      Content : String) return String
   is
      Root : constant String :=
        Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "rr-cache");
      Search : Ada.Directories.Search_Type;
      Dir_Item : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if Content'Length = 0
        or else not Ada.Directories.Exists (Root)
        or else Ada.Directories.Kind (Root) /= Ada.Directories.Directory
      then
         return "";
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Root,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Item);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Item);
            Dir  : constant String := Ada.Directories.Full_Name (Dir_Item);
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Preimage  : constant String := Version.Files.Join (Dir, "preimage");
                  Postimage : constant String := Version.Files.Join (Dir, "postimage");
               begin
                  if Ada.Directories.Exists (Preimage)
                    and then Ada.Directories.Exists (Postimage)
                    and then Ada.Directories.Kind (Preimage)
                             = Ada.Directories.Ordinary_File
                    and then Ada.Directories.Kind (Postimage)
                             = Ada.Directories.Ordinary_File
                    and then Version.Files.Read_Binary_File (Preimage) = Content
                  then
                     Ada.Directories.End_Search (Search);
                     return Postimage;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return "";
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         return "";
   end Rerere_Postimage_For_Preimage;

   function Try_Rerere_Resolution
     (Repo       : Version.Repository.Repository_Handle;
      Path_Text  : String;
      Base_Id    : String;
      Preimage_Content : String;
      Result_Item : Version.Objects.Tree_Entry;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Result     : in out Version.Staging.Index_Entry_Vectors.Vector;
      Behavior   : Merge_Behavior) return Boolean
   is
      Key : constant String := Rerere_Key (Base_Id, Current_Id, Target_Id);
      Exact_Path : constant String := Rerere_Postimage_Path (Repo, Key);
      Path : Unbounded_String;
   begin
      if not Behavior.Update_Worktree
        or else not Rerere_Enabled (Repo, Behavior)
      then
         return False;
      elsif Ada.Directories.Exists (Exact_Path)
        and then Ada.Directories.Kind (Exact_Path) = Ada.Directories.Ordinary_File
      then
         Path := To_Unbounded_String (Exact_Path);
      else
         declare
            Fuzzy_Path : constant String :=
              Rerere_Postimage_For_Preimage
                (Repo => Repo, Content => Preimage_Content);
         begin
            if Fuzzy_Path'Length = 0 then
               return False;
            end if;
            Path := To_Unbounded_String (Fuzzy_Path);
         end;
      end if;

      declare
         Content : constant String :=
           Version.Files.Read_Binary_File (To_String (Path));
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo => Repo, Content => Content);
         Item : constant Version.Objects.Tree_Entry :=
           Version.Objects.Tree_Entry'
             (Path => To_Unbounded_String (Path_Text),
              Id   => Blob_Id,
              Kind => Result_Item.Kind,
              Mode => Result_Item.Mode);
      begin
         Version.Files.Write_Binary_File_Atomic
           (Path    => Version.Files.Join
              (Version.Repository.Root_Path (Repo), Path_Text),
            Content => Content);
         Apply_Worktree_File_Mode
           (Version.Files.Join (Version.Repository.Root_Path (Repo), Path_Text),
            To_String (Item.Mode));
         Add_Merged_Path (Result, Item);
         return True;
      end;
   end Try_Rerere_Resolution;

   procedure Delete_Working_File
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String) is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Require_Safe_Path (Relative_Path);

      if Ada.Directories.Exists (Absolute_Path) then
         if Ada.Directories.Kind (Absolute_Path) = Ada.Directories.Ordinary_File then
            Version.Files.Remove_File_If_Safe
              (Repo_Root     => Version.Repository.Root_Path (Repo),
               Relative_Path => Relative_Path);
         else
            raise Ada.IO_Exceptions.Data_Error with
              "cannot delete merge path because it is not a file: "
              & Relative_Path;
         end if;
      end if;
   end Delete_Working_File;

   procedure Write_File_From_Object
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Object_Id     : Version.Objects.Hex_Object_Id;
      Mode          : String) is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Object_Id);
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Require_Safe_Path (Relative_Path);
      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Relative_Path);

      if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
         return;
      end if;

      if Ada.Directories.Exists (Absolute_Path)
        and then Ada.Directories.Kind (Absolute_Path) = Ada.Directories.Directory
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot write merge file over directory: " & Relative_Path;
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Path    => Absolute_Path,
         Content => Version.LFS.Smudge_Content
           (Repo          => Repo,
            Relative_Path => Relative_Path,
            Content       => Version.Objects.Content (Obj)));
      Apply_Worktree_File_Mode (Absolute_Path, Mode);
   end Write_File_From_Object;

   procedure Remove_File_Or_Link_For_Symlink_Write
     (Repo : Version.Repository.Repository_Handle; Relative_Path : String)
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
      Native_Path : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Native_Path) then
         declare
            Native_C : aliased String := Native_Path & Character'Val (0);
         begin
            if Unlink (Native_C'Address) /= 0 then
               raise Ada.IO_Exceptions.Use_Error with
                 "could not remove existing merge symlink: " & Relative_Path;
            end if;
         end;
      elsif Ada.Directories.Exists (Native_Path) then
         if Ada.Directories.Kind (Native_Path) = Ada.Directories.Ordinary_File then
            Version.Files.Delete_File_If_Exists (Absolute_Path);
         elsif Ada.Directories.Kind (Native_Path) = Ada.Directories.Directory then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot write merge symlink over directory: " & Relative_Path;
         else
            raise Ada.IO_Exceptions.Data_Error with
              "unsafe merge symlink target path: " & Relative_Path;
         end if;
      end if;
   end Remove_File_Or_Link_For_Symlink_Write;

   procedure Write_Symlink_From_Object
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Object_Id     : Version.Objects.Hex_Object_Id)
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Object_Id);
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
      Native_Path : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      Require_Safe_Path (Relative_Path);
      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Relative_Path,
         Is_Symlink    => True);

      if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
         return;
      end if;

      declare
         Target : constant String := Version.Objects.Content (Obj);
      begin
         if Target'Length = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "empty symlink target in merge tree entry: " & Relative_Path;
         elsif Is_Binary_Content (Target) then
            raise Ada.IO_Exceptions.Data_Error with
              "symlink target contains NUL: " & Relative_Path;
         end if;

         Version.Files.Create_Parent_Directories (Absolute_Path);
         Remove_File_Or_Link_For_Symlink_Write (Repo, Relative_Path);

         if Core_Symlinks_Disabled (Repo) then
            Version.Files.Write_Binary_File_Atomic
              (Path    => Absolute_Path,
               Content => Target);
         else
            declare
               Target_C : aliased String := Target & Character'Val (0);
               Link_C   : aliased String := Native_Path & Character'Val (0);
            begin
               if Symlink (Target_C'Address, Link_C'Address) /= 0 then
                  raise Ada.IO_Exceptions.Use_Error with
                    "could not create merge symlink: " & Relative_Path;
               end if;
            end;
         end if;
      end;
   end Write_Symlink_From_Object;

   procedure Write_Worktree_Item
     (Repo : Version.Repository.Repository_Handle; Item : Version.Objects.Tree_Entry) is
   begin
      if Is_Gitlink (Item) then
         return;
      elsif Is_Symlink_Mode (Mode_Text (Item)) then
         Write_Symlink_From_Object (Repo, To_String (Item.Path), Item.Id);
      else
         Write_File_From_Object
           (Repo          => Repo,
            Relative_Path => To_String (Item.Path),
            Object_Id     => Item.Id,
            Mode          => Mode_Text (Item));
      end if;
   end Write_Worktree_Item;

   procedure Maybe_Write_Worktree_Item
     (Repo     : Version.Repository.Repository_Handle;
      Item     : Version.Objects.Tree_Entry;
      Behavior : Merge_Behavior) is
   begin
      if Behavior.Update_Worktree then
         Write_Worktree_Item (Repo, Item);
      end if;
   end Maybe_Write_Worktree_Item;

   procedure Maybe_Delete_Working_File
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Behavior      : Merge_Behavior) is
   begin
      if Behavior.Update_Worktree then
         Delete_Working_File (Repo, Relative_Path);
      end if;
   end Maybe_Delete_Working_File;

   function Git_Worktree_Diff_Status (Sub_Worktree : String) return Integer is
      Args : GNAT.OS_Lib.Argument_List (1 .. 4) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("diff");
      Args (4) := new String'("--quiet");
      Status := GNAT.OS_Lib.Spawn (Program_Name => Resolve_Program ("git"), Args => Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Worktree_Diff_Status;

   function Git_Index_Diff_Status (Sub_Worktree : String) return Integer is
      Args : GNAT.OS_Lib.Argument_List (1 .. 5) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("diff");
      Args (4) := new String'("--cached");
      Args (5) := new String'("--quiet");
      Status := GNAT.OS_Lib.Spawn (Program_Name => Resolve_Program ("git"), Args => Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Index_Diff_Status;

   function Spawn_Git_Quiet_Status
     (Args : in out GNAT.OS_Lib.Argument_List) return Integer
   is
      Output_FD   : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
      Output_Name : GNAT.OS_Lib.String_Access := null;
      Status      : Integer := 2;

      procedure Cleanup is
      begin
         if Output_FD /= GNAT.OS_Lib.Invalid_FD then
            GNAT.OS_Lib.Close (Output_FD);
            Output_FD := GNAT.OS_Lib.Invalid_FD;
         end if;

         if Output_Name /= null then
            Version.Files.Delete_File_If_Exists (Output_Name.all);
            GNAT.OS_Lib.Free (Output_Name);
            Output_Name := null;
         end if;
      end Cleanup;
   begin
      GNAT.OS_Lib.Create_Temp_Output_File (Output_FD, Output_Name);
      if Output_FD = GNAT.OS_Lib.Invalid_FD or else Output_Name = null then
         Cleanup;
         return 2;
      end if;

      GNAT.OS_Lib.Spawn
        (Program_Name           => Resolve_Program ("git"),
         Args                   => Args,
         Output_File_Descriptor => Output_FD,
         Return_Code            => Status,
         Err_To_Out             => True);
      Cleanup;
      return Status;
   exception
      when others =>
         Cleanup;
         return 2;
   end Spawn_Git_Quiet_Status;

   function Git_Untracked_Status (Sub_Worktree : String) return Integer is
      Args : GNAT.OS_Lib.Argument_List (1 .. 7) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("ls-files");
      Args (4) := new String'("--others");
      Args (5) := new String'("--exclude-standard");
      Args (6) := new String'("--error-unmatch");
      Args (7) := new String'(".");
      Status := Spawn_Git_Quiet_Status (Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 0;
   end Git_Untracked_Status;

   function Git_Merge_Base_Status
     (Sub_Worktree : String; Ancestor : String; Descendant : String) return Integer
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 6) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("merge-base");
      Args (4) := new String'("--is-ancestor");
      Args (5) := new String'(Ancestor);
      Args (6) := new String'(Descendant);
      Status := GNAT.OS_Lib.Spawn (Program_Name => Resolve_Program ("git"), Args => Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Merge_Base_Status;

   function Git_Object_Exists_Status
     (Sub_Worktree : String; Object_Id : String) return Integer
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 5) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("cat-file");
      Args (4) := new String'("-e");
      Args (5) := new String'(Object_Id & "^{commit}");
      Status := Spawn_Git_Quiet_Status (Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Object_Exists_Status;

   function Git_Fetch_Object_Status
     (Sub_Worktree : String; Object_Id : String) return Integer
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 6) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("fetch");
      Args (4) := new String'("--quiet");
      Args (5) := new String'("origin");
      Args (6) := new String'(Object_Id);
      Status := Spawn_Git_Quiet_Status (Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Fetch_Object_Status;

   function Git_Submodule_Update_Recursive_Status
     (Sub_Worktree : String) return Integer
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 6) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("submodule");
      Args (4) := new String'("update");
      Args (5) := new String'("--init");
      Args (6) := new String'("--recursive");
      Status := Spawn_Git_Quiet_Status (Args);
      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;
      return Status;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         return 1;
   end Git_Submodule_Update_Recursive_Status;

   function Submodule_Head_Is_Target
     (Sub_Worktree : String; Target_Id : String) return Boolean is
   begin
      return Git_Merge_Base_Status (Sub_Worktree, Target_Id, "HEAD") = 0
        and then Git_Merge_Base_Status (Sub_Worktree, "HEAD", Target_Id) = 0;
   end Submodule_Head_Is_Target;

   function Submodule_Has_Dirty_State
     (Sub_Worktree : String) return Boolean is
   begin
      return Git_Worktree_Diff_Status (Sub_Worktree) /= 0
        or else Git_Index_Diff_Status (Sub_Worktree) /= 0
        or else Git_Untracked_Status (Sub_Worktree) /= 1;
   end Submodule_Has_Dirty_State;

   procedure Maybe_Update_Submodule_Worktree
     (Repo      : Version.Repository.Repository_Handle;
      Path_Text : String;
      Item      : Version.Objects.Tree_Entry;
      Behavior  : Merge_Behavior)
   is
      Sub_Worktree : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path_Text);
      Sub_Git_Dir : constant String :=
        Version.Repository.Resolve_Git_Dir (Sub_Worktree);
      Args : GNAT.OS_Lib.Argument_List (1 .. 5) := [others => null];
      Status : Integer;

      procedure Free_Args is
      begin
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
               Args (I) := null;
            end if;
         end loop;
      end Free_Args;
   begin
      if not Behavior.Update_Worktree or else not Is_Gitlink (Item)
        or else Sub_Git_Dir'Length = 0
      then
         return;
      end if;

      if Git_Object_Exists_Status (Sub_Worktree, To_String (Item.Id)) /= 0 then
         if Submodule_Has_Dirty_State (Sub_Worktree) then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot update dirty submodule worktree: " & Path_Text;
         elsif Git_Fetch_Object_Status (Sub_Worktree, To_String (Item.Id)) /= 0
           or else Git_Object_Exists_Status (Sub_Worktree, To_String (Item.Id)) /= 0
         then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot fetch submodule commit: " & Path_Text;
         end if;
      end if;

      if Submodule_Head_Is_Target (Sub_Worktree, To_String (Item.Id)) then
         return;
      elsif Submodule_Has_Dirty_State (Sub_Worktree) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot update dirty submodule worktree: " & Path_Text;
      end if;

      Args (1) := new String'("-C");
      Args (2) := new String'(Sub_Worktree);
      Args (3) := new String'("checkout");
      Args (4) := new String'("--detach");
      Args (5) := new String'(To_String (Item.Id));
      Status := GNAT.OS_Lib.Spawn (Program_Name => Resolve_Program ("git"), Args => Args);
      Free_Args;

      if Status /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot update submodule worktree: " & Path_Text;
      elsif Behavior.Recurse_Submodules
        and then Ada.Directories.Exists
          (Version.Files.Join (Sub_Worktree, ".gitmodules"))
        and then Git_Submodule_Update_Recursive_Status (Sub_Worktree) /= 0
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot update nested submodules: " & Path_Text;
      end if;
   exception
      when others =>
         Free_Args;
         raise;
   end Maybe_Update_Submodule_Worktree;

   function Try_Gitlink_Merge
     (Repo         : Version.Repository.Repository_Handle;
      Path_Text    : String;
      Base_Item    : Version.Objects.Tree_Entry;
      Has_Base     : Boolean;
      Current_Item : Version.Objects.Tree_Entry;
      Target_Item  : Version.Objects.Tree_Entry;
      Result       : in out Version.Staging.Index_Entry_Vectors.Vector;
      Behavior     : Merge_Behavior)
      return Boolean
   is
      Current_Result : constant Version.Objects.Tree_Entry :=
        With_Path (Current_Item, Path_Text);
      Target_Result : constant Version.Objects.Tree_Entry :=
        With_Path (Target_Item, Path_Text);
   begin
      if not Is_Gitlink (Current_Item) or else not Is_Gitlink (Target_Item) then
         return False;
      elsif Same_Entry (Current_Item, Target_Item) then
         Add_Merged_Path (Result, Current_Result);
         Maybe_Update_Submodule_Worktree
           (Repo => Repo, Path_Text => Path_Text, Item => Current_Result,
            Behavior => Behavior);
         return True;
      elsif Has_Base and then Is_Gitlink (Base_Item) then
         if Same_Entry (Current_Item, Base_Item) then
            Add_Merged_Path (Result, Target_Result);
            Maybe_Update_Submodule_Worktree
              (Repo => Repo, Path_Text => Path_Text, Item => Target_Result,
               Behavior => Behavior);
            return True;
         elsif Same_Entry (Target_Item, Base_Item) then
            Add_Merged_Path (Result, Current_Result);
            Maybe_Update_Submodule_Worktree
              (Repo => Repo, Path_Text => Path_Text, Item => Current_Result,
               Behavior => Behavior);
            return True;
         end if;
      end if;

      declare
         Sub_Worktree : constant String :=
           Version.Files.Join (Version.Repository.Root_Path (Repo), Path_Text);
         Sub_Git_Dir : constant String :=
           Version.Repository.Resolve_Git_Dir (Sub_Worktree);
         Target_Is_Descendant  : Boolean := False;
         Current_Is_Descendant : Boolean := False;
      begin
         if Sub_Git_Dir'Length = 0 then
            return False;
         end if;

         declare
            Sub_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open_Git_Dir (Sub_Git_Dir);
         begin
            Target_Is_Descendant :=
              Version.History.Is_Ancestor
                (Repo       => Sub_Repo,
                 Base_Id    => Current_Item.Id,
                 Derived_Id => Target_Item.Id);
            Current_Is_Descendant :=
              Version.History.Is_Ancestor
                (Repo       => Sub_Repo,
                 Base_Id    => Target_Item.Id,
                 Derived_Id => Current_Item.Id);
         exception
            when others =>
               return False;
         end;

         if Target_Is_Descendant then
            Add_Merged_Path (Result, Target_Result);
            Maybe_Update_Submodule_Worktree
              (Repo => Repo, Path_Text => Path_Text, Item => Target_Result,
               Behavior => Behavior);
            return True;
         elsif Current_Is_Descendant then
            Add_Merged_Path (Result, Current_Result);
            Maybe_Update_Submodule_Worktree
              (Repo => Repo, Path_Text => Path_Text, Item => Current_Result,
               Behavior => Behavior);
            return True;
         else
            return False;
         end if;
      end;
   end Try_Gitlink_Merge;

   function Blob_Content_Or_Empty
     (Repo : Version.Repository.Repository_Handle;
      Item : Version.Objects.Tree_Entry;
      Is_Blob : out Boolean) return String
   is
   begin
      if Is_Gitlink (Item) then
         Is_Blob := False;
         return "";
      end if;

      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Item.Id);
      begin
         Is_Blob := Version.Objects.Kind (Obj) = Version.Objects.Blob_Object;
         if Is_Blob then
            return Version.Objects.Content (Obj);
         else
            return "";
         end if;
      end;
   end Blob_Content_Or_Empty;

   function Natural_Image_No_Leading_Space (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Natural_Image_No_Leading_Space;

   function Shell_Quote (Text : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("'");
   begin
      for C of Text loop
         if C = Character'Val (39) then
            Append (Result, "'\''");
         else
            Append (Result, C);
         end if;
      end loop;
      Append (Result, "'");
      return To_String (Result);
   end Shell_Quote;

   function Config_Value_Or_Empty
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      return Version.Config.Get_Value (Repo => Repo, Name => Name);
   exception
      when others =>
         return "";
   end Config_Value_Or_Empty;

   function Recursive_Attribute_For_Driver
     (Repo : Version.Repository.Repository_Handle; Driver_Name : String)
      return Merge_Attribute
   is
      Value : String := Version.Config.Trim
        (Config_Value_Or_Empty
           (Repo => Repo, Name => "merge." & Driver_Name & ".recursive"));
   begin
      if Driver_Name'Length = 0 then
         return Attribute_Default;
      end if;

      for I in Value'Range loop
         Value (I) := Ada.Characters.Handling.To_Lower (Value (I));
      end loop;

      if Value = "ours" then
         return Attribute_Ours;
      elsif Value = "theirs" then
         return Attribute_Theirs;
      elsif Value = "union" then
         return Attribute_Union;
      elsif Value = "text" then
         return Attribute_Text;
      elsif Value = "binary" then
         return Attribute_Binary;
      else
         return Attribute_Default;
      end if;
   end Recursive_Attribute_For_Driver;

   function Recursive_External_Driver_Name
     (Repo : Version.Repository.Repository_Handle; Driver_Name : String)
      return String
   is
      Raw : constant String := Version.Config.Trim
        (Config_Value_Or_Empty
           (Repo => Repo, Name => "merge." & Driver_Name & ".recursive"));
      Lower : String := Raw;
   begin
      if Driver_Name'Length = 0 or else Raw'Length = 0 then
         return "";
      end if;

      for I in Lower'Range loop
         Lower (I) := Ada.Characters.Handling.To_Lower (Lower (I));
      end loop;

      if Lower = "ours" or else Lower = "theirs" or else Lower = "union"
        or else Lower = "text" or else Lower = "binary"
      then
         return "";
      else
         return Raw;
      end if;
   end Recursive_External_Driver_Name;

   function Effective_External_Driver_Name
     (Repo        : Version.Repository.Repository_Handle;
      Driver_Name : String;
      Behavior    : Merge_Behavior) return String
   is
   begin
      if Behavior.Update_Worktree then
         return Driver_Name;
      else
         declare
            Recursive_Name : constant String :=
              Recursive_External_Driver_Name
                (Repo => Repo, Driver_Name => Driver_Name);
         begin
            if Recursive_Name'Length > 0 then
               return Recursive_Name;
            else
               return Driver_Name;
            end if;
         end;
      end if;
   end Effective_External_Driver_Name;

   procedure Save_Env
     (Name : String; Exists : out Boolean; Value : out Unbounded_String) is
   begin
      Exists := Ada.Environment_Variables.Exists (Name);
      if Exists then
         Value := To_Unbounded_String (Ada.Environment_Variables.Value (Name));
      else
         Value := Null_Unbounded_String;
      end if;
   end Save_Env;

   procedure Restore_Env
     (Name : String; Exists : Boolean; Value : Unbounded_String) is
   begin
      if Exists then
         Ada.Environment_Variables.Set (Name, To_String (Value));
      else
         Ada.Environment_Variables.Clear (Name);
      end if;
   end Restore_Env;

   function Expand_Driver_Command
     (Template     : String;
      Base_Path    : String;
      Current_Path : String;
      Target_Path  : String;
      Marker_Size  : Positive;
      Merge_Path   : String;
      Base_Name    : String;
      Current_Name : String;
      Target_Name  : String) return String
   is
      Result : Unbounded_String;
      I : Natural := Template'First;
   begin
      while I <= Template'Last loop
         if Template (I) = '%' and then I < Template'Last then
            declare
               Code : constant Character := Template (I + 1);
            begin
               case Code is
                  when 'O' => Append (Result, Shell_Quote (Base_Path));
                  when 'A' => Append (Result, Shell_Quote (Current_Path));
                  when 'B' => Append (Result, Shell_Quote (Target_Path));
                  when 'L' => Append (Result, Natural_Image_No_Leading_Space (Marker_Size));
                  when 'P' => Append (Result, Shell_Quote (Merge_Path));
                  when 'S' => Append (Result, Shell_Quote (Base_Name));
                  when 'X' => Append (Result, Shell_Quote (Current_Name));
                  when 'Y' => Append (Result, Shell_Quote (Target_Name));
                  when '%' => Append (Result, "%");
                  when others =>
                     Append (Result, "%");
                     Append (Result, Code);
               end case;
               I := I + 2;
            end;
         else
            Append (Result, Template (I));
            I := I + 1;
         end if;
      end loop;

      return To_String (Result);
   end Expand_Driver_Command;

   function Try_Recursive_Merge_Driver
     (Repo         : Version.Repository.Repository_Handle;
      Path_Text    : String;
      Driver_Name  : String;
      Current_Text : String;
      Target_Text  : String;
      Current_Item : Version.Objects.Tree_Entry;
      Target_Item  : Version.Objects.Tree_Entry;
      Result       : in out Version.Staging.Index_Entry_Vectors.Vector)
      return Boolean
   is
      Attr : constant Merge_Attribute :=
        Recursive_Attribute_For_Driver
          (Repo => Repo, Driver_Name => Driver_Name);
   begin
      case Attr is
         when Attribute_Ours =>
            Add_Merged_Path (Result, Current_Item);
            return True;

         when Attribute_Theirs =>
            Add_Merged_Path (Result, Target_Item);
            return True;

         when Attribute_Union =>
            if Is_Binary_Content (Current_Text)
              or else Is_Binary_Content (Target_Text)
            then
               return False;
            end if;

            declare
               Content : constant String := Union_Text (Current_Text, Target_Text);
               Blob_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Blob (Repo => Repo, Content => Content);
               Union_Item : constant Version.Objects.Tree_Entry :=
                 Version.Objects.Tree_Entry'
                   (Path => To_Unbounded_String (Path_Text),
                    Id   => Blob_Id,
                    Kind => Current_Item.Kind,
                    Mode => Current_Item.Mode);
            begin
               Add_Merged_Path (Result, Union_Item);
               return True;
            end;

         when Attribute_Default | Attribute_Reset | Attribute_Text | Attribute_Binary =>
            return False;
      end case;
   end Try_Recursive_Merge_Driver;

   function Try_External_Merge_Driver
     (Repo         : Version.Repository.Repository_Handle;
      Path_Text    : String;
      Driver_Name  : String;
      Base_Text    : String;
      Current_Text : String;
      Target_Text  : String;
      Current_Name : String;
      Target_Name  : String;
      Current_Item : Version.Objects.Tree_Entry;
      Behavior     : Merge_Behavior;
      Result       : in out Version.Staging.Index_Entry_Vectors.Vector)
      return Boolean
   is
      Command_Template : constant String :=
        Config_Value_Or_Empty
          (Repo => Repo, Name => "merge." & Driver_Name & ".driver");
      Key : constant String :=
        Version.Hash.Sha1_Hex
          (Path_Text & To_String (Current_Item.Id) & Driver_Name);
      Temp_Dir : constant String :=
        Version.Files.Join (Version.Repository.Git_Dir (Repo), "version-merge-driver");
      Base_Path : constant String := Version.Files.Join (Temp_Dir, Key & ".O");
      Current_Path : constant String := Version.Files.Join (Temp_Dir, Key & ".A");
      Target_Path : constant String := Version.Files.Join (Temp_Dir, Key & ".B");
      Args : GNAT.OS_Lib.Argument_List (1 .. 2) := [others => null];
      Status : Integer;
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Git_Dir_Exists        : Boolean := False;
      Old_Common_Git_Dir_Exists : Boolean := False;
      Old_Work_Tree_Exists      : Boolean := False;
      Old_Index_File_Exists     : Boolean := False;
      Old_Git_Dir               : Unbounded_String;
      Old_Common_Git_Dir        : Unbounded_String;
      Old_Work_Tree             : Unbounded_String;
      Old_Index_File            : Unbounded_String;
      Env_Saved                 : Boolean := False;

      procedure Cleanup is
      begin
         Version.Files.Delete_File_If_Exists (Base_Path);
         Version.Files.Delete_File_If_Exists (Current_Path);
         Version.Files.Delete_File_If_Exists (Target_Path);
         Version.Files.Delete_Directory_Tree_If_Exists (Temp_Dir);
      end Cleanup;
   begin
      if Driver_Name'Length = 0 or else Command_Template'Length = 0 then
         return False;
      end if;

      Version.Files.Write_Binary_File_Atomic (Path => Base_Path, Content => Base_Text);
      Version.Files.Write_Binary_File_Atomic (Path => Current_Path, Content => Current_Text);
      Version.Files.Write_Binary_File_Atomic (Path => Target_Path, Content => Target_Text);

      declare
         Command : constant String :=
           Expand_Driver_Command
             (Template     => Command_Template,
              Base_Path    => Base_Path,
              Current_Path => Current_Path,
              Target_Path  => Target_Path,
              Marker_Size  => Behavior.Marker_Size,
              Merge_Path   => Path_Text,
              Base_Name    => "base",
              Current_Name => Current_Name,
              Target_Name  => Target_Name);
      begin
         Save_Env ("GIT_DIR", Old_Git_Dir_Exists, Old_Git_Dir);
         Save_Env ("GIT_COMMON_DIR", Old_Common_Git_Dir_Exists, Old_Common_Git_Dir);
         Save_Env ("GIT_WORK_TREE", Old_Work_Tree_Exists, Old_Work_Tree);
         Save_Env ("GIT_INDEX_FILE", Old_Index_File_Exists, Old_Index_File);
         Env_Saved := True;
         Ada.Environment_Variables.Set
           ("GIT_DIR", Version.Repository.Git_Dir (Repo));
         Ada.Environment_Variables.Set
           ("GIT_COMMON_DIR", Version.Repository.Common_Git_Dir (Repo));
         Ada.Environment_Variables.Set
           ("GIT_WORK_TREE", Version.Repository.Root_Path (Repo));
         Ada.Environment_Variables.Set
           ("GIT_INDEX_FILE",
            Version.Files.Join (Version.Repository.Git_Dir (Repo), "index"));
         Ada.Directories.Set_Directory
           (Version.Files.To_Native_Path (Version.Repository.Root_Path (Repo)));

         Args (1) := new String'("-c");
         Args (2) := new String'(Command);
         Status := GNAT.OS_Lib.Spawn (Program_Name => "/bin/sh", Args => Args);

         Ada.Directories.Set_Directory (Old_Dir);
         Restore_Env ("GIT_DIR", Old_Git_Dir_Exists, Old_Git_Dir);
         Restore_Env ("GIT_COMMON_DIR", Old_Common_Git_Dir_Exists, Old_Common_Git_Dir);
         Restore_Env ("GIT_WORK_TREE", Old_Work_Tree_Exists, Old_Work_Tree);
         Restore_Env ("GIT_INDEX_FILE", Old_Index_File_Exists, Old_Index_File);
      end;

      GNAT.OS_Lib.Free (Args (1));
      Args (1) := null;
      GNAT.OS_Lib.Free (Args (2));
      Args (2) := null;

      if Status > 128 then
         Cleanup;
         raise Ada.IO_Exceptions.Data_Error with
           "external merge driver failed: " & Driver_Name;
      elsif Status /= 0 then
         Cleanup;
         return False;
      end if;

      if not Version.Files.Is_Ordinary_File (Current_Path) then
         Cleanup;
         raise Ada.IO_Exceptions.Data_Error with
           "external merge driver failed: " & Driver_Name;
      end if;

      declare
         Content : constant String := Version.Files.Read_Binary_File (Current_Path);
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo => Repo, Content => Content);
         Merged_Item : constant Version.Objects.Tree_Entry :=
           Version.Objects.Tree_Entry'
             (Path => To_Unbounded_String (Path_Text),
              Id   => Blob_Id,
              Kind => Current_Item.Kind,
              Mode => Current_Item.Mode);
      begin
         if Behavior.Update_Worktree then
            Version.Files.Write_Binary_File_Atomic
              (Path    => Version.Files.Join
                 (Version.Repository.Root_Path (Repo), Path_Text),
               Content => Content);
            Apply_Worktree_File_Mode
              (Version.Files.Join (Version.Repository.Root_Path (Repo), Path_Text),
               To_String (Merged_Item.Mode));
         end if;
         Add_Merged_Path (Result, Merged_Item);
         Cleanup;
         return True;
      end;
   exception
      when E : Ada.IO_Exceptions.Data_Error =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         if Env_Saved then
            Restore_Env ("GIT_DIR", Old_Git_Dir_Exists, Old_Git_Dir);
            Restore_Env ("GIT_COMMON_DIR", Old_Common_Git_Dir_Exists, Old_Common_Git_Dir);
            Restore_Env ("GIT_WORK_TREE", Old_Work_Tree_Exists, Old_Work_Tree);
            Restore_Env ("GIT_INDEX_FILE", Old_Index_File_Exists, Old_Index_File);
         end if;
         if Args (1) /= null then
            GNAT.OS_Lib.Free (Args (1));
            Args (1) := null;
         end if;
         if Args (2) /= null then
            GNAT.OS_Lib.Free (Args (2));
            Args (2) := null;
         end if;
         Cleanup;

         if Ada.Strings.Fixed.Index
           (Ada.Exceptions.Exception_Message (E),
            "external merge driver failed:") = 1
         then
            raise;
         else
            return False;
         end if;

      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         if Env_Saved then
            Restore_Env ("GIT_DIR", Old_Git_Dir_Exists, Old_Git_Dir);
            Restore_Env ("GIT_COMMON_DIR", Old_Common_Git_Dir_Exists, Old_Common_Git_Dir);
            Restore_Env ("GIT_WORK_TREE", Old_Work_Tree_Exists, Old_Work_Tree);
            Restore_Env ("GIT_INDEX_FILE", Old_Index_File_Exists, Old_Index_File);
         end if;
         if Args (1) /= null then
            GNAT.OS_Lib.Free (Args (1));
            Args (1) := null;
         end if;
         if Args (2) /= null then
            GNAT.OS_Lib.Free (Args (2));
            Args (2) := null;
         end if;
         Cleanup;
         return False;
   end Try_External_Merge_Driver;

   procedure Write_Conflict_File
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Current_Name  : String;
      Base_Item     : Version.Objects.Tree_Entry;
      Has_Base      : Boolean;
      Current_Item  : Version.Objects.Tree_Entry;
      Target_Name   : String;
      Target_Item   : Version.Objects.Tree_Entry;
      Behavior      : Merge_Behavior;
      Kind          : out Conflict_Kind)
   is
      Current_Is_Blob : Boolean := False;
      Target_Is_Blob  : Boolean := False;
      Base_Is_Blob    : Boolean := False;
      Current_Text : constant String :=
        Blob_Content_Or_Empty (Repo, Current_Item, Current_Is_Blob);
      Target_Text  : constant String :=
        Blob_Content_Or_Empty (Repo, Target_Item, Target_Is_Blob);
      Base_Text    : constant String :=
        (if Has_Base then Blob_Content_Or_Empty (Repo, Base_Item, Base_Is_Blob) else "");
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Require_Safe_Path (Relative_Path);
      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Relative_Path);

      if Is_Gitlink (Current_Item) or else Is_Gitlink (Target_Item)
        or else not Current_Is_Blob or else not Target_Is_Blob
        or else Attribute_For_Path (Repo, Relative_Path) = Attribute_Binary
      then
         Kind := Binary_Conflict;
         Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
         return;
      end if;

      if Is_Binary_Content (Current_Text) or else Is_Binary_Content (Target_Text) then
         Kind := Binary_Conflict;
         Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
      else
         Kind := Content_Conflict;
         declare
            Content : constant String :=
              Conflict_Text
                (Current_Name => Current_Name,
                 Current_Text => Current_Text,
                 Base_Name    => "base",
                 Base_Text    => Base_Text,
                 Has_Base     => Has_Base and then Base_Is_Blob,
                 Target_Name  => Target_Name,
                 Target_Text  => Target_Text,
                 Behavior     => Behavior);
            Base_Id : constant String :=
              (if Has_Base
               then To_String (Base_Item.Id)
               else "0000000000000000000000000000000000000000");
         begin
            if Behavior.Update_Worktree then
               Version.Files.Write_Binary_File_Atomic
                 (Path => Absolute_Path, Content => Content);
               Apply_Worktree_File_Mode
                 (Absolute_Path, To_String (Current_Item.Mode));
            end if;
            Record_Rerere_Preimage
              (Repo     => Repo,
               Rel_Path => Relative_Path,
               Base_Id  => Base_Id,
               Current  => Current_Item.Id,
               Target   => Target_Item.Id,
               Content  => Content,
               Behavior => Behavior);
         end;
      end if;
   end Write_Conflict_File;

   procedure Handle_Two_Sided_Conflict
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Path_Text     : String;
      Base_Item     : Version.Objects.Tree_Entry;
      Has_Base      : Boolean;
      Current_Item  : Version.Objects.Tree_Entry;
      Target_Item   : Version.Objects.Tree_Entry;
      Default_Kind  : Conflict_Kind;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior)
   is
      Current_Is_Blob : Boolean := False;
      Target_Is_Blob  : Boolean := False;
      Base_Is_Blob    : Boolean := False;
      Current_Text : constant String :=
        Blob_Content_Or_Empty (Repo, Current_Item, Current_Is_Blob);
      Target_Text  : constant String :=
        Blob_Content_Or_Empty (Repo, Target_Item, Target_Is_Blob);
      Base_Text : constant String :=
        (if Has_Base then Blob_Content_Or_Empty (Repo, Base_Item, Base_Is_Blob) else "");
      Attr : constant Merge_Attribute := Attribute_For_Path (Repo, Path_Text);
      Driver_Name : constant String := Merge_Driver_For_Path (Repo, Path_Text);
      Result_Item : constant Version.Objects.Tree_Entry :=
        With_Path (Current_Item, Path_Text);
      Base_Id : constant String :=
        (if Has_Base
         then To_String (Base_Item.Id)
         else "0000000000000000000000000000000000000000");
      Actual_Kind : Conflict_Kind;
   begin
      if Attr = Attribute_Ours or else Behavior.Favor = Favor_Current then
         Add_Merged_Path (Merged_Index, Result_Item);
         Maybe_Write_Worktree_Item (Repo, Result_Item, Behavior);
         return;
      elsif Attr = Attribute_Theirs or else Behavior.Favor = Favor_Target then
         declare
            Target_Result : constant Version.Objects.Tree_Entry :=
              With_Path (Target_Item, Path_Text);
         begin
            Add_Merged_Path (Merged_Index, Target_Result);
            Maybe_Write_Worktree_Item (Repo, Target_Result, Behavior);
            return;
         end;
      end if;

      if Try_Gitlink_Merge
           (Repo         => Repo,
            Path_Text    => Path_Text,
            Base_Item    => Base_Item,
            Has_Base     => Has_Base,
            Current_Item => Current_Item,
            Target_Item  => Target_Item,
            Result       => Merged_Index,
            Behavior     => Behavior)
      then
         return;
      end if;

      if Current_Is_Blob and then Target_Is_Blob then
         if Equivalent_Text (Current_Text, Target_Text, Behavior) then
            declare
               Merged_Item : Version.Objects.Tree_Entry := Result_Item;
            begin
               Merged_Item.Mode := Merged_Content_Mode
                 (Base_Item    => Base_Item,
                  Has_Base     => Has_Base,
                  Current_Item => Current_Item,
                  Target_Item  => Target_Item);

               Add_Merged_Path (Merged_Index, Merged_Item);
               Maybe_Write_Worktree_Item (Repo, Merged_Item, Behavior);
            end;
            return;
         elsif (not Behavior.Update_Worktree)
           and then Try_Recursive_Merge_Driver
             (Repo         => Repo,
              Path_Text    => Path_Text,
              Driver_Name  => Driver_Name,
              Current_Text => Current_Text,
              Target_Text  => Target_Text,
              Current_Item => Result_Item,
              Target_Item  => With_Path (Target_Item, Path_Text),
              Result       => Merged_Index)
         then
            return;
         elsif Try_External_Merge_Driver
           (Repo         => Repo,
            Path_Text    => Path_Text,
            Driver_Name  => Effective_External_Driver_Name
              (Repo => Repo, Driver_Name => Driver_Name, Behavior => Behavior),
            Base_Text    => (if Has_Base and then Base_Is_Blob then Base_Text else ""),
            Current_Text => Current_Text,
            Target_Text  => Target_Text,
            Current_Name => Current_Name,
            Target_Name  => Target_Name,
            Current_Item => Result_Item,
            Behavior     => Behavior,
            Result       => Merged_Index)
         then
            return;
         elsif Attr = Attribute_Union
           and then not Is_Binary_Content (Current_Text)
           and then not Is_Binary_Content (Target_Text)
         then
            declare
               Content : constant String := Union_Text (Current_Text, Target_Text);
               Blob_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Blob (Repo => Repo, Content => Content);
               Union_Item : constant Version.Objects.Tree_Entry :=
                 Version.Objects.Tree_Entry'
                   (Path => To_Unbounded_String (Path_Text),
                    Id   => Blob_Id,
                    Kind => Current_Item.Kind,
                    Mode => Current_Item.Mode);
            begin
               if Behavior.Update_Worktree then
                  Version.Files.Write_Binary_File_Atomic
                    (Path    => Version.Files.Join
                       (Version.Repository.Root_Path (Repo), Path_Text),
                     Content => Content);
                  Apply_Worktree_File_Mode
                    (Version.Files.Join
                       (Version.Repository.Root_Path (Repo), Path_Text),
                     To_String (Union_Item.Mode));
               end if;
               Add_Merged_Path (Merged_Index, Union_Item);
               return;
            end;
         elsif Has_Base
           and then Base_Is_Blob
           and then not Is_Binary_Content (Base_Text)
           and then not Is_Binary_Content (Current_Text)
           and then not Is_Binary_Content (Target_Text)
           and then Attr /= Attribute_Binary
         then
            declare
               Merged_Text : Unbounded_String;
            begin
               if Try_Auto_Text_Merge
                    (Base     => Base_Text,
                     Current  => Current_Text,
                     Target   => Target_Text,
                     Behavior => Behavior,
                     Merged   => Merged_Text)
               then
                  declare
                     Content : constant String := To_String (Merged_Text);
                     Blob_Id : constant Version.Objects.Hex_Object_Id :=
                       Version.Write.Write_Blob (Repo => Repo, Content => Content);
                     Merged_Item : constant Version.Objects.Tree_Entry :=
                       Version.Objects.Tree_Entry'
                         (Path => To_Unbounded_String (Path_Text),
                          Id   => Blob_Id,
                          Kind => Current_Item.Kind,
                          Mode => Merged_Content_Mode
                            (Base_Item    => Base_Item,
                             Has_Base     => Has_Base,
                             Current_Item => Current_Item,
                             Target_Item  => Target_Item));
                  begin
                     if Behavior.Update_Worktree then
                        Version.Files.Write_Binary_File_Atomic
                          (Path    => Version.Files.Join
                             (Version.Repository.Root_Path (Repo), Path_Text),
                           Content => Content);
                        Apply_Worktree_File_Mode
                          (Version.Files.Join
                             (Version.Repository.Root_Path (Repo), Path_Text),
                           To_String (Merged_Item.Mode));
                     end if;
                     Add_Merged_Path (Merged_Index, Merged_Item);
                     return;
                  end;
               end if;
            end;
         end if;
      end if;

      declare
         Preimage_Content : constant String :=
           (if Current_Is_Blob
              and then Target_Is_Blob
              and then Attr /= Attribute_Binary
              and then not Is_Binary_Content (Current_Text)
              and then not Is_Binary_Content (Target_Text)
            then Conflict_Text
              (Current_Name => Current_Name,
               Current_Text => Current_Text,
               Base_Name    => "base",
               Base_Text    => Base_Text,
               Has_Base     => Has_Base and then Base_Is_Blob,
               Target_Name  => Target_Name,
               Target_Text  => Target_Text,
               Behavior     => Behavior)
            else "");
      begin
         if Try_Rerere_Resolution
              (Repo             => Repo,
               Path_Text        => Path_Text,
               Base_Id          => Base_Id,
               Preimage_Content => Preimage_Content,
               Result_Item      => Result_Item,
               Current_Id       => Current_Item.Id,
               Target_Id        => Target_Item.Id,
               Result           => Merged_Index,
               Behavior         => Behavior)
         then
            return;
         end if;
      end;

      Write_Conflict_File
        (Repo          => Repo,
         Relative_Path => Path_Text,
         Current_Name  => Current_Name,
         Base_Item     => Base_Item,
         Has_Base      => Has_Base,
         Current_Item  => Result_Item,
         Target_Name   => Target_Name,
         Target_Item   => With_Path (Target_Item, Path_Text),
         Behavior      => Behavior,
         Kind          => Actual_Kind);

      if Actual_Kind = Binary_Conflict then
         if Behavior.Materialize_Virtual_Conflicts then
            Add_Merged_Path (Merged_Index, Result_Item);
         end if;
         Add_Conflict (Conflicts, Path_Text, Binary_Conflict);
      else
         if Behavior.Materialize_Virtual_Conflicts
           and then Current_Is_Blob
           and then Target_Is_Blob
           and then Attr /= Attribute_Binary
           and then not Is_Binary_Content (Current_Text)
           and then not Is_Binary_Content (Target_Text)
         then
            declare
               Content : constant String :=
                 Conflict_Text
                   (Current_Name => Current_Name,
                    Current_Text => Current_Text,
                    Base_Name    => "base",
                    Base_Text    => Base_Text,
                    Has_Base     => Has_Base and then Base_Is_Blob,
                    Target_Name  => Target_Name,
                    Target_Text  => Target_Text,
                    Behavior     => Behavior);
               Blob_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Blob (Repo => Repo, Content => Content);
               Virtual_Item : constant Version.Objects.Tree_Entry :=
                 Version.Objects.Tree_Entry'
                   (Path => To_Unbounded_String (Path_Text),
                    Id   => Blob_Id,
                    Kind => Current_Item.Kind,
                    Mode => Merged_Content_Mode
                      (Base_Item    => Base_Item,
                       Has_Base     => Has_Base,
                       Current_Item => Current_Item,
                       Target_Item  => Target_Item));
            begin
               Add_Merged_Path (Merged_Index, Virtual_Item);
            end;
         end if;

         Add_Conflict (Conflicts, Path_Text, Default_Kind);
      end if;
   end Handle_Two_Sided_Conflict;

   function Directory_Rename_Target
     (Base_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      New_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Old_Dir    : String;
      Ambiguous  : out Boolean) return String;

   function Contains_Planned_Path
     (Plans : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      Path  : String)
      return Boolean
   is
   begin
      if Plans.Is_Empty then
         return False;
      end if;

      for I in Plans.First_Index .. Plans.Last_Index loop
         if To_String (Plans.Element (I).Path) = Path then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Planned_Path;

   function Has_Case_Only_Replacement
     (Base_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Path_Text   : String) return Boolean
   is
      Path_Key : constant String :=
        Version.Filesystem_Guard.Collision_Key (Path_Text);
   begin
      if Find_Tree_Item (Base_Items, Path_Text) = Natural'Last
        or else Find_Tree_Item (Other_Items, Path_Text) /= Natural'Last
        or else Other_Items.Is_Empty
      then
         return False;
      end if;

      for I in Other_Items.First_Index .. Other_Items.Last_Index loop
         declare
            Other_Path : constant String := To_String (Other_Items.Element (I).Path);
         begin
            if Other_Path /= Path_Text
              and then Version.Filesystem_Guard.Collision_Key (Other_Path) = Path_Key
              and then Find_Tree_Item (Base_Items, Other_Path) = Natural'Last
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Case_Only_Replacement;

   procedure Append_Merge_Write_Plans
     (Base_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Items       : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Plans       : in out Version.Filesystem_Guard.Planned_Path_Vectors.Vector)
   is
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item : constant Version.Objects.Tree_Entry := Items.Element (I);
            Path_Text : constant String := To_String (Item.Path);
         begin
            Require_Safe_Path (Path_Text);

            if not Has_Directory_File_Conflict
                     (Path_Text, Items, Other_Items)
              and then Item.Kind /= Version.Objects.Tree_Gitlink
              and then To_String (Item.Mode) /= "160000"
              and then not Has_Case_Only_Replacement
                (Base_Items  => Base_Items,
                 Other_Items => Other_Items,
                 Path_Text   => Path_Text)
              and then not Contains_Planned_Path (Plans, Path_Text)
            then
               Plans.Append
                 (Planned_Path'
                    (Path         => To_Unbounded_String (Path_Text),
                     Is_Directory => False,
                     Is_Symlink   => To_String (Item.Mode) = "120000"));
            end if;
         end;
      end loop;
   end Append_Merge_Write_Plans;

   procedure Append_Directory_Rename_Write_Plans
     (Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Renamed_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Items   : Version.Objects.Tree_Entry_Vectors.Vector;
      Behavior      : Merge_Behavior;
      Plans         : in out Version.Filesystem_Guard.Planned_Path_Vectors.Vector)
   is
      Processed : Path_Sets.Set;
   begin
      if Base_Items.Is_Empty
        or else Behavior.Directory_Renames = Directory_Renames_Disabled
      then
         return;
      end if;

      for I in Base_Items.First_Index .. Base_Items.Last_Index loop
         declare
            Old_Dir : constant String :=
              Parent_Directory (To_String (Base_Items.Element (I).Path));
         begin
            if Old_Dir'Length > 0 and then not Processed.Contains (Old_Dir) then
               Processed.Include (Old_Dir);

               declare
                  Ambiguous_Rename : Boolean := False;
                  New_Dir : constant String :=
                    Directory_Rename_Target
                      (Base_Items => Base_Items,
                       New_Items  => Renamed_Items,
                       Old_Dir    => Old_Dir,
                       Ambiguous  => Ambiguous_Rename);
                  pragma Unreferenced (Ambiguous_Rename);
               begin
                  if New_Dir'Length > 0 and then not Other_Items.Is_Empty then
                     for J in Other_Items.First_Index .. Other_Items.Last_Index loop
                        declare
                           Other_Item : constant Version.Objects.Tree_Entry :=
                             Other_Items.Element (J);
                           Old_Path : constant String := To_String (Other_Item.Path);
                        begin
                           if Is_Under_Directory (Old_Path, Old_Dir)
                             and then Find_Tree_Item (Base_Items, Old_Path) = Natural'Last
                             and then Find_Tree_Item (Renamed_Items, Old_Path) = Natural'Last
                             and then Other_Item.Kind /= Version.Objects.Tree_Gitlink
                             and then To_String (Other_Item.Mode) /= "160000"
                           then
                              declare
                                 New_Path : constant String :=
                                   Move_Under_Directory (Old_Path, Old_Dir, New_Dir);
                              begin
                                 Require_Safe_Path (New_Path);

                                 if Find_Tree_Item (Renamed_Items, New_Path) = Natural'Last
                                   and then not Contains_Planned_Path (Plans, New_Path)
                                 then
                                    Plans.Append
                                      (Planned_Path'
                                         (Path         => To_Unbounded_String (New_Path),
                                          Is_Directory => False,
                                          Is_Symlink   => To_String (Other_Item.Mode) = "120000"));
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Append_Directory_Rename_Write_Plans;

   procedure Preflight_Merge_Working_Writes
     (Repo          : Version.Repository.Repository_Handle;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Behavior      : Merge_Behavior)
   is
      Plans : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
   begin
      Append_Merge_Write_Plans
        (Base_Items  => Base_Items,
         Items       => Current_Items,
         Other_Items => Target_Items,
         Plans       => Plans);
      Append_Merge_Write_Plans
        (Base_Items  => Base_Items,
         Items       => Target_Items,
         Other_Items => Current_Items,
         Plans       => Plans);
      Append_Directory_Rename_Write_Plans
        (Base_Items    => Base_Items,
         Renamed_Items => Current_Items,
         Other_Items   => Target_Items,
         Behavior      => Behavior,
         Plans         => Plans);
      Append_Directory_Rename_Write_Plans
        (Base_Items    => Base_Items,
         Renamed_Items => Target_Items,
         Other_Items   => Current_Items,
         Behavior      => Behavior,
         Plans         => Plans);

      Version.Filesystem_Guard.Preflight_Checkout
        (Repo_Root => Version.Repository.Root_Path (Repo),
         Paths     => Plans);
   end Preflight_Merge_Working_Writes;

   function Find_Renamed_Item
     (Repo       : Version.Repository.Repository_Handle;
      Items      : Version.Objects.Tree_Entry_Vectors.Vector;
      Base_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Base_Item  : Version.Objects.Tree_Entry;
      Old_Path   : String;
      Used       : Path_Sets.Set;
      Behavior   : Merge_Behavior) return Natural
   is
      Best_Pos   : Natural := Natural'Last;
      Best_Score : Natural := 0;
      Candidate_Count : Natural := 0;
   begin
      if Items.Is_Empty then
         return Natural'Last;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item : constant Version.Objects.Tree_Entry := Items.Element (I);
            P    : constant String := To_String (Item.Path);
         begin
            if P /= Old_Path
              and then not Used.Contains (P)
              and then Find_Tree_Item (Base_Items, P) = Natural'Last
            then
               if Same_Entry (Item, Base_Item) then
                  return I;
               end if;

               Candidate_Count := Candidate_Count + 1;
            end if;
         end;
      end loop;

      if Behavior.Rename_Limit /= 0
        and then Candidate_Count > Behavior.Rename_Limit
      then
         return Natural'Last;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item  : constant Version.Objects.Tree_Entry := Items.Element (I);
            P     : constant String := To_String (Item.Path);
            Score : Natural := 0;
         begin
            if P /= Old_Path
              and then not Used.Contains (P)
              and then Find_Tree_Item (Base_Items, P) = Natural'Last
              and then not Same_Entry (Item, Base_Item)
            then
               Score := Rename_Similarity (Repo, Base_Item, Item);
               if Score > Best_Score then
                  Best_Pos := I;
                  Best_Score := Score;
               end if;
            end if;
         end;
      end loop;

      if Best_Pos /= Natural'Last
        and then Best_Score >= Behavior.Rename_Threshold
      then
         return Best_Pos;
      else
         return Natural'Last;
      end if;
   end Find_Renamed_Item;

   function Find_Copy_Base_For_Add_Add
     (Repo         : Version.Repository.Repository_Handle;
      Base_Items   : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Item : Version.Objects.Tree_Entry;
      Target_Item  : Version.Objects.Tree_Entry;
      New_Path     : String;
      Behavior     : Merge_Behavior) return Natural
   is
      Best_Pos   : Natural := Natural'Last;
      Best_Score : Natural := 0;
   begin
      if not Behavior.Detect_Copies or else Base_Items.Is_Empty then
         return Natural'Last;
      end if;

      for I in Base_Items.First_Index .. Base_Items.Last_Index loop
         declare
            Base_Item : constant Version.Objects.Tree_Entry := Base_Items.Element (I);
            Base_Path : constant String := To_String (Base_Item.Path);
         begin
            if Base_Path /= New_Path then
               declare
                  Current_Score : constant Natural :=
                    Rename_Similarity (Repo, Base_Item, Current_Item);
                  Target_Score : constant Natural :=
                    Rename_Similarity (Repo, Base_Item, Target_Item);
               begin
                  if Current_Score >= Behavior.Rename_Threshold
                    and then Target_Score >= Behavior.Rename_Threshold
                    and then Current_Score + Target_Score > Best_Score
                  then
                     Best_Pos := I;
                     Best_Score := Current_Score + Target_Score;
                  end if;
               end;
            end if;
         end;
      end loop;

      return Best_Pos;
   end Find_Copy_Base_For_Add_Add;

   procedure Add_Stage_If_Found
     (Result : in out Version.Staging.Index_Entry_Vectors.Vector;
      Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Pos    : Natural;
      Stage  : Natural;
      Path   : String := "")
   is
   begin
      if Pos /= Natural'Last then
         if Path'Length = 0 then
            Add_Staged_Conflict_Path (Result, Items.Element (Pos), Stage);
         else
            Add_Staged_Conflict_Path
              (Result, With_Path (Items.Element (Pos), Path), Stage);
         end if;
      end if;
   end Add_Stage_If_Found;

   function Directory_Rename_Target
     (Base_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      New_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Old_Dir    : String;
      Ambiguous  : out Boolean) return String
   is
      Candidate : Unbounded_String;
      Found     : Boolean := False;
      Split     : Boolean := False;
   begin
      Ambiguous := False;
      if Old_Dir'Length = 0 or else Base_Items.Is_Empty or else New_Items.Is_Empty then
         return "";
      end if;

      for I in Base_Items.First_Index .. Base_Items.Last_Index loop
         declare
            Base_Item : constant Version.Objects.Tree_Entry := Base_Items.Element (I);
            Old_Path  : constant String := To_String (Base_Item.Path);
         begin
            if Is_Under_Directory (Old_Path, Old_Dir)
              and then Find_Tree_Item (New_Items, Old_Path) = Natural'Last
            then
               for J in New_Items.First_Index .. New_Items.Last_Index loop
                  declare
                     New_Item : constant Version.Objects.Tree_Entry := New_Items.Element (J);
                     New_Path : constant String := To_String (New_Item.Path);
                     New_Dir  : constant String := Parent_Directory (New_Path);
                  begin
                     if New_Dir /= Old_Dir
                       and then Find_Tree_Item (Base_Items, New_Path) = Natural'Last
                       and then Leaf_Name (New_Path) = Leaf_Name (Old_Path)
                       and then Same_Entry (New_Item, Base_Item)
                     then
                        if not Found then
                           Candidate := To_Unbounded_String (New_Dir);
                           Found := True;
                        elsif To_String (Candidate) /= New_Dir then
                           Split := True;
                        end if;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;

      if Found and then not Split then
         return To_String (Candidate);
      else
         Ambiguous := Found and then Split;
         return "";
      end if;
   end Directory_Rename_Target;

   procedure Apply_Directory_Rename_Additions
     (Repo          : Version.Repository.Repository_Handle;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Renamed_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Items   : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Is_Current : Boolean;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior;
      Skip_Renamed  : in out Path_Sets.Set;
      Skip_Other    : in out Path_Sets.Set)
   is
      Processed : Path_Sets.Set;
   begin
      if Base_Items.Is_Empty
        or else Behavior.Directory_Renames = Directory_Renames_Disabled
      then
         return;
      end if;

      for I in Base_Items.First_Index .. Base_Items.Last_Index loop
         declare
            Old_Dir : constant String := Parent_Directory (To_String (Base_Items.Element (I).Path));
         begin
            if Old_Dir'Length > 0 and then not Processed.Contains (Old_Dir) then
               Processed.Include (Old_Dir);

               declare
                  Ambiguous_Rename : Boolean := False;
                  New_Dir : constant String :=
                    Directory_Rename_Target
                      (Base_Items => Base_Items,
                       New_Items  => Renamed_Items,
                       Old_Dir    => Old_Dir,
                       Ambiguous  => Ambiguous_Rename);
               begin
                  if New_Dir'Length > 0 then
                     for J in Other_Items.First_Index .. Other_Items.Last_Index loop
                        declare
                           Other_Item : constant Version.Objects.Tree_Entry :=
                             Other_Items.Element (J);
                           Old_Path : constant String := To_String (Other_Item.Path);
                        begin
                           if Is_Under_Directory (Old_Path, Old_Dir)
                             and then not Skip_Other.Contains (Old_Path)
                             and then Find_Tree_Item (Base_Items, Old_Path) = Natural'Last
                             and then Find_Tree_Item (Renamed_Items, Old_Path) = Natural'Last
                           then
                              declare
                                 New_Path : constant String :=
                                   Move_Under_Directory (Old_Path, Old_Dir, New_Dir);
                                 Renamed_Pos : constant Natural :=
                                   Find_Tree_Item (Renamed_Items, New_Path);
                                 Moved_Other : constant Version.Objects.Tree_Entry :=
                                   With_Path (Other_Item, New_Path);
                              begin
                                 if Renamed_Pos = Natural'Last then
                                    if Behavior.Directory_Renames = Directory_Renames_Conflict then
                                       if Behavior.Materialize_Virtual_Conflicts then
                                          Add_Merged_Path (Merged_Index, Moved_Other);
                                       end if;
                                       if Other_Is_Current then
                                          Add_Staged_Conflict_Path (Merged_Index, Moved_Other, 2);
                                       else
                                          Add_Staged_Conflict_Path (Merged_Index, Moved_Other, 3);
                                       end if;
                                       Add_Conflict (Conflicts, New_Path, Add_Add_Conflict);
                                    else
                                       Add_Merged_Path (Merged_Index, Moved_Other);
                                    end if;
                                    Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                                    Maybe_Write_Worktree_Item (Repo, Moved_Other, Behavior);
                                    Skip_Other.Include (Old_Path);
                                 elsif Same_Entry (Renamed_Items.Element (Renamed_Pos), Moved_Other)
                                   and then Behavior.Directory_Renames /= Directory_Renames_Conflict
                                 then
                                    Add_Merged_Path
                                      (Merged_Index, Renamed_Items.Element (Renamed_Pos));
                                    Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                                    Maybe_Write_Worktree_Item
                                      (Repo, Renamed_Items.Element (Renamed_Pos), Behavior);
                                    Skip_Other.Include (Old_Path);
                                    Skip_Renamed.Include (New_Path);
                                 else
                                    if Behavior.Materialize_Virtual_Conflicts then
                                       Add_Merged_Path
                                         (Merged_Index,
                                          (if Other_Is_Current
                                           then Moved_Other
                                           else Renamed_Items.Element (Renamed_Pos)));
                                    end if;
                                    if Other_Is_Current then
                                       Add_Staged_Conflict_Path (Merged_Index, Moved_Other, 2);
                                       Add_Staged_Conflict_Path
                                         (Merged_Index, Renamed_Items.Element (Renamed_Pos), 3);
                                    else
                                       Add_Staged_Conflict_Path
                                         (Merged_Index, Renamed_Items.Element (Renamed_Pos), 2);
                                       Add_Staged_Conflict_Path (Merged_Index, Moved_Other, 3);
                                    end if;

                                    Add_Conflict (Conflicts, New_Path, Add_Add_Conflict);
                                    Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                                    Maybe_Write_Worktree_Item
                                      (Repo,
                                       (if Other_Is_Current then Moved_Other
                                        else Renamed_Items.Element (Renamed_Pos)),
                                       Behavior);
                                    Skip_Other.Include (Old_Path);
                                    Skip_Renamed.Include (New_Path);
                                 end if;
                              end;
                           end if;
                        end;
                     end loop;
                  elsif Ambiguous_Rename then
                     for J in Other_Items.First_Index .. Other_Items.Last_Index loop
                        declare
                           Other_Item : constant Version.Objects.Tree_Entry :=
                             Other_Items.Element (J);
                           Old_Path : constant String := To_String (Other_Item.Path);
                        begin
                           if Is_Under_Directory (Old_Path, Old_Dir)
                             and then not Skip_Other.Contains (Old_Path)
                             and then Find_Tree_Item (Base_Items, Old_Path) = Natural'Last
                             and then Find_Tree_Item (Renamed_Items, Old_Path) = Natural'Last
                           then
                              if Behavior.Materialize_Virtual_Conflicts then
                                 Add_Merged_Path (Merged_Index, Other_Item);
                              end if;
                              if Other_Is_Current then
                                 Add_Staged_Conflict_Path
                                   (Merged_Index, Other_Item, 2);
                              else
                                 Add_Staged_Conflict_Path
                                   (Merged_Index, Other_Item, 3);
                              end if;

                              Add_Conflict
                                (Conflicts, Old_Path, Add_Add_Conflict);
                              Maybe_Write_Worktree_Item
                                (Repo, Other_Item, Behavior);
                              Skip_Other.Include (Old_Path);
                           end if;
                        end;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Apply_Directory_Rename_Additions;

   procedure Apply_Rename_Detections
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior;
      Skip_Current  : in out Path_Sets.Set;
      Skip_Target   : in out Path_Sets.Set)
   is
   begin
      if Base_Items.Is_Empty then
         return;
      end if;

      for I in Base_Items.First_Index .. Base_Items.Last_Index loop
         declare
            Base_Item : constant Version.Objects.Tree_Entry := Base_Items.Element (I);
            Old_Path  : constant String := To_String (Base_Item.Path);
            Current_Pos : constant Natural := Find_Tree_Item (Current_Items, Old_Path);
            Target_Pos  : constant Natural := Find_Tree_Item (Target_Items, Old_Path);
            Current_Rename_Pos : constant Natural :=
              Find_Renamed_Item
                (Repo       => Repo,
                 Items      => Current_Items,
                 Base_Items => Base_Items,
                 Base_Item  => Base_Item,
                 Old_Path   => Old_Path,
                 Used       => Skip_Current,
                 Behavior   => Behavior);
            Target_Rename_Pos : constant Natural :=
              Find_Renamed_Item
                (Repo       => Repo,
                 Items      => Target_Items,
                 Base_Items => Base_Items,
                 Base_Item  => Base_Item,
                 Old_Path   => Old_Path,
                 Used       => Skip_Target,
                 Behavior   => Behavior);
         begin
            if Current_Rename_Pos /= Natural'Last
              and then Target_Rename_Pos /= Natural'Last
              and then Current_Pos = Natural'Last
              and then Target_Pos = Natural'Last
            then
               declare
                  Current_New : constant Version.Objects.Tree_Entry :=
                    Current_Items.Element (Current_Rename_Pos);
                  Target_New : constant Version.Objects.Tree_Entry :=
                    Target_Items.Element (Target_Rename_Pos);
                  Current_Path : constant String := To_String (Current_New.Path);
                  Target_Path  : constant String := To_String (Target_New.Path);
               begin
                  Skip_Current.Include (Current_Path);
                  Skip_Target.Include (Target_Path);

                  if Current_Path = Target_Path then
                     if Same_Entry (Current_New, Target_New) then
                        Add_Merged_Path (Merged_Index, Current_New);
                        Maybe_Write_Worktree_Item (Repo, Current_New, Behavior);
                     else
                        Add_Staged_Conflict_Path
                          (Merged_Index, With_Path (Base_Item, Current_Path), 1);
                        Add_Staged_Conflict_Path (Merged_Index, Current_New, 2);
                        Add_Staged_Conflict_Path (Merged_Index, Target_New, 3);
                        Handle_Two_Sided_Conflict
                          (Repo          => Repo,
                           Current_Name  => Current_Name,
                           Target_Name   => Target_Name,
                           Path_Text     => Current_Path,
                           Base_Item     => With_Path (Base_Item, Current_Path),
                           Has_Base      => True,
                           Current_Item  => Current_New,
                           Target_Item   => Target_New,
                           Default_Kind  => Content_Conflict,
                           Merged_Index  => Merged_Index,
                           Conflicts     => Conflicts,
                           Behavior      => Behavior);
                     end if;
                  else
                     if Behavior.Materialize_Virtual_Conflicts then
                        Add_Merged_Path (Merged_Index, Current_New);
                        Add_Merged_Path (Merged_Index, Target_New);
                     end if;
                     Add_Staged_Conflict_Path (Merged_Index, Current_New, 2);
                     Add_Staged_Conflict_Path (Merged_Index, Target_New, 3);
                     Add_Conflict (Conflicts, Current_Path, Content_Conflict);
                     Add_Conflict (Conflicts, Target_Path, Content_Conflict);
                     Maybe_Write_Worktree_Item (Repo, Current_New, Behavior);
                     Maybe_Write_Worktree_Item (Repo, Target_New, Behavior);
                  end if;
               end;

            elsif Target_Rename_Pos /= Natural'Last
              and then Target_Pos = Natural'Last
            then
               declare
                  Target_New : constant Version.Objects.Tree_Entry :=
                    Target_Items.Element (Target_Rename_Pos);
                  New_Path : constant String := To_String (Target_New.Path);
               begin
                  Skip_Target.Include (New_Path);

                  if Current_Pos /= Natural'Last then
                     Skip_Current.Include (Old_Path);
                     if Same_Entry (Current_Items.Element (Current_Pos), Base_Item) then
                        Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                        Add_Merged_Path (Merged_Index, Target_New);
                        Maybe_Write_Worktree_Item (Repo, Target_New, Behavior);
                     else
                        declare
                           Current_Moved : constant Version.Objects.Tree_Entry :=
                             With_Path
                               (Current_Items.Element (Current_Pos), New_Path);
                        begin
                           Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                           Handle_Two_Sided_Conflict
                             (Repo          => Repo,
                              Current_Name  => Current_Name,
                              Target_Name   => Target_Name,
                              Path_Text     => New_Path,
                              Base_Item     => Base_Item,
                              Has_Base      => True,
                              Current_Item  => Current_Moved,
                              Target_Item   => Target_New,
                              Default_Kind  => Content_Conflict,
                              Merged_Index  => Merged_Index,
                              Conflicts     => Conflicts,
                              Behavior      => Behavior);
                        end;
                     end if;
                  else
                     declare
                        Current_New_Pos : constant Natural :=
                          Find_Tree_Item (Current_Items, New_Path);
                     begin
                        Maybe_Delete_Working_File (Repo, Old_Path, Behavior);

                        if Current_New_Pos /= Natural'Last then
                           declare
                              Current_New : constant Version.Objects.Tree_Entry :=
                                Current_Items.Element (Current_New_Pos);
                           begin
                              Skip_Current.Include (New_Path);
                              Add_Staged_Conflict_Path
                                (Merged_Index, With_Path (Base_Item, New_Path), 1);
                              Add_Staged_Conflict_Path
                                (Merged_Index, Current_New, 2);
                              Add_Staged_Conflict_Path
                                (Merged_Index, Target_New, 3);
                              Handle_Two_Sided_Conflict
                                (Repo          => Repo,
                                 Current_Name  => Current_Name,
                                 Target_Name   => Target_Name,
                                 Path_Text     => New_Path,
                                 Base_Item     => With_Path (Base_Item, New_Path),
                                 Has_Base      => False,
                                 Current_Item  => Current_New,
                                 Target_Item   => Target_New,
                                 Default_Kind  => Add_Add_Conflict,
                                 Merged_Index  => Merged_Index,
                                 Conflicts     => Conflicts,
                                 Behavior      => Behavior);
                           end;
                        else
                           if Behavior.Materialize_Virtual_Conflicts then
                              Add_Merged_Path (Merged_Index, Target_New);
                           end if;
                           Add_Staged_Conflict_Path
                             (Merged_Index, With_Path (Base_Item, New_Path), 1);
                           Add_Staged_Conflict_Path (Merged_Index, Target_New, 3);
                           Add_Conflict (Conflicts, New_Path, Delete_Modify_Conflict);
                           Maybe_Write_Worktree_Item (Repo, Target_New, Behavior);
                        end if;
                     end;
                  end if;
               end;

            elsif Current_Rename_Pos /= Natural'Last
              and then Current_Pos = Natural'Last
            then
               declare
                  Current_New : constant Version.Objects.Tree_Entry :=
                    Current_Items.Element (Current_Rename_Pos);
                  New_Path : constant String := To_String (Current_New.Path);
               begin
                  Skip_Current.Include (New_Path);

                  if Target_Pos /= Natural'Last then
                     Skip_Target.Include (Old_Path);
                     if Same_Entry (Target_Items.Element (Target_Pos), Base_Item) then
                        Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                        Add_Merged_Path (Merged_Index, Current_New);
                        Maybe_Write_Worktree_Item (Repo, Current_New, Behavior);
                     else
                        declare
                           Target_Moved : constant Version.Objects.Tree_Entry :=
                             With_Path
                               (Target_Items.Element (Target_Pos), New_Path);
                        begin
                           Maybe_Delete_Working_File (Repo, Old_Path, Behavior);
                           Handle_Two_Sided_Conflict
                             (Repo          => Repo,
                              Current_Name  => Current_Name,
                              Target_Name   => Target_Name,
                              Path_Text     => New_Path,
                              Base_Item     => Base_Item,
                              Has_Base      => True,
                              Current_Item  => Current_New,
                              Target_Item   => Target_Moved,
                              Default_Kind  => Content_Conflict,
                              Merged_Index  => Merged_Index,
                              Conflicts     => Conflicts,
                              Behavior      => Behavior);
                        end;
                     end if;
                  else
                     declare
                        Target_New_Pos : constant Natural :=
                          Find_Tree_Item (Target_Items, New_Path);
                     begin
                        Maybe_Delete_Working_File (Repo, Old_Path, Behavior);

                        if Target_New_Pos /= Natural'Last then
                           declare
                              Target_New : constant Version.Objects.Tree_Entry :=
                                Target_Items.Element (Target_New_Pos);
                           begin
                              Skip_Target.Include (New_Path);
                              Add_Staged_Conflict_Path
                                (Merged_Index, With_Path (Base_Item, New_Path), 1);
                              Add_Staged_Conflict_Path
                                (Merged_Index, Current_New, 2);
                              Add_Staged_Conflict_Path
                                (Merged_Index, Target_New, 3);
                              Handle_Two_Sided_Conflict
                                (Repo          => Repo,
                                 Current_Name  => Current_Name,
                                 Target_Name   => Target_Name,
                                 Path_Text     => New_Path,
                                 Base_Item     => With_Path (Base_Item, New_Path),
                                 Has_Base      => False,
                                 Current_Item  => Current_New,
                                 Target_Item   => Target_New,
                                 Default_Kind  => Add_Add_Conflict,
                                 Merged_Index  => Merged_Index,
                                 Conflicts     => Conflicts,
                                 Behavior      => Behavior);
                           end;
                        else
                           if Behavior.Materialize_Virtual_Conflicts then
                              Add_Merged_Path (Merged_Index, Current_New);
                           end if;
                           Add_Staged_Conflict_Path
                             (Merged_Index, With_Path (Base_Item, New_Path), 1);
                           Add_Staged_Conflict_Path (Merged_Index, Current_New, 2);
                           Add_Conflict (Conflicts, New_Path, Delete_Modify_Conflict);
                           Maybe_Write_Worktree_Item (Repo, Current_New, Behavior);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Apply_Directory_Rename_Additions
        (Repo             => Repo,
         Base_Items       => Base_Items,
         Renamed_Items    => Target_Items,
         Other_Items      => Current_Items,
         Other_Is_Current => True,
         Merged_Index     => Merged_Index,
         Conflicts        => Conflicts,
         Behavior         => Behavior,
         Skip_Renamed     => Skip_Target,
         Skip_Other       => Skip_Current);

      Apply_Directory_Rename_Additions
        (Repo             => Repo,
         Base_Items       => Base_Items,
         Renamed_Items    => Current_Items,
         Other_Items      => Target_Items,
         Other_Is_Current => False,
         Merged_Index     => Merged_Index,
         Conflicts        => Conflicts,
         Behavior         => Behavior,
         Skip_Renamed     => Skip_Current,
         Skip_Other       => Skip_Target);
   end Apply_Rename_Detections;

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior)
   is
      Skip_Current : Path_Sets.Set;
      Skip_Target  : Path_Sets.Set;
   begin
      if Behavior.Update_Worktree then
         Preflight_Merge_Working_Writes
           (Repo          => Repo,
            Base_Items    => Base_Items,
            Current_Items => Current_Items,
            Target_Items  => Target_Items,
            Behavior      => Behavior);
      end if;

      if Behavior.Detect_Renames then
         Apply_Rename_Detections
           (Repo          => Repo,
            Current_Name  => Current_Name,
            Target_Name   => Target_Name,
            Base_Items    => Base_Items,
            Current_Items => Current_Items,
            Target_Items  => Target_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior,
            Skip_Current  => Skip_Current,
            Skip_Target   => Skip_Target);
      end if;

      if not Current_Items.Is_Empty then
         for I in Current_Items.First_Index .. Current_Items.Last_Index loop
            declare
               Current_Item : constant Version.Objects.Tree_Entry :=
                 Current_Items.Element (I);
               Path_Text : constant String := To_String (Current_Item.Path);
               Base_Pos : constant Natural := Find_Tree_Item (Base_Items, Path_Text);
               Target_Pos : constant Natural := Find_Tree_Item (Target_Items, Path_Text);
               Current_Changed : constant Boolean :=
                 Base_Pos = Natural'Last
                 or else not Same_Entry (Base_Items.Element (Base_Pos), Current_Item);
               Target_Changed : constant Boolean :=
                 Target_Pos /= Natural'Last
                 and then
                   (Base_Pos = Natural'Last
                    or else not Same_Entry
                      (Target_Items.Element (Target_Pos),
                       Base_Items.Element (Base_Pos)));
            begin
               if Skip_Current.Contains (Path_Text) then
                  null;
               else
                  Require_Safe_Path (Path_Text);

                  if Has_Directory_File_Conflict
                       (Path_Text, Current_Items, Target_Items)
                  then
                     if Behavior.Materialize_Virtual_Conflicts then
                        Add_Merged_Path (Merged_Index, Current_Item);
                     end if;
                     Add_Conflict (Conflicts, Path_Text, Directory_File_Conflict);
                     Add_Stage_If_Found (Merged_Index, Base_Items, Base_Pos, 1);
                     Add_Staged_Conflict_Path (Merged_Index, Current_Item, 2);
                     Add_Stage_If_Found (Merged_Index, Target_Items, Target_Pos, 3);
                     Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);

                  elsif Target_Pos = Natural'Last then
                     if Current_Changed and then Base_Pos /= Natural'Last then
                        if Behavior.Favor = Favor_Current then
                           Add_Merged_Path (Merged_Index, Current_Item);
                           Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
                        elsif Behavior.Favor = Favor_Target then
                           Maybe_Delete_Working_File (Repo, Path_Text, Behavior);
                        else
                           if Behavior.Materialize_Virtual_Conflicts then
                              Add_Merged_Path (Merged_Index, Current_Item);
                           end if;
                           Add_Conflict (Conflicts, Path_Text, Delete_Modify_Conflict);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Base_Items.Element (Base_Pos), 1);
                           Add_Staged_Conflict_Path (Merged_Index, Current_Item, 2);
                           Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
                        end if;
                     elsif Current_Changed and then Base_Pos = Natural'Last then
                        Add_Merged_Path (Merged_Index, Current_Item);
                     else
                        Maybe_Delete_Working_File (Repo, Path_Text, Behavior);
                     end if;

                  elsif Base_Pos = Natural'Last
                    and then not Same_Entry
                      (Current_Item, Target_Items.Element (Target_Pos))
                  then
                     declare
                        Target_Item : constant Version.Objects.Tree_Entry :=
                          Target_Items.Element (Target_Pos);
                        Copy_Base_Pos : constant Natural :=
                          Find_Copy_Base_For_Add_Add
                            (Repo         => Repo,
                             Base_Items   => Base_Items,
                             Current_Item => Current_Item,
                             Target_Item  => Target_Item,
                             New_Path     => Path_Text,
                             Behavior     => Behavior);
                        Copy_Has_Base : constant Boolean :=
                          Copy_Base_Pos /= Natural'Last;
                        Copy_Base_Item : constant Version.Objects.Tree_Entry :=
                          (if Copy_Has_Base
                           then With_Path (Base_Items.Element (Copy_Base_Pos), Path_Text)
                           else Current_Item);
                     begin
                        if Copy_Has_Base then
                           Add_Staged_Conflict_Path
                             (Merged_Index, Copy_Base_Item, 1);
                        end if;
                        Add_Staged_Conflict_Path (Merged_Index, Current_Item, 2);
                        Add_Staged_Conflict_Path (Merged_Index, Target_Item, 3);
                        Handle_Two_Sided_Conflict
                          (Repo          => Repo,
                           Current_Name  => Current_Name,
                           Target_Name   => Target_Name,
                           Path_Text     => Path_Text,
                           Base_Item     => Copy_Base_Item,
                           Has_Base      => Copy_Has_Base,
                           Current_Item  => Current_Item,
                           Target_Item   => Target_Item,
                           Default_Kind  => Add_Add_Conflict,
                           Merged_Index  => Merged_Index,
                           Conflicts     => Conflicts,
                           Behavior      => Behavior);
                     end;

                  elsif Current_Changed
                    and then Target_Changed
                    and then not Same_Entry
                      (Target_Items.Element (Target_Pos), Current_Item)
                  then
                     declare
                        Base_Item  : constant Version.Objects.Tree_Entry :=
                          Base_Items.Element (Base_Pos);
                        Target_Item : constant Version.Objects.Tree_Entry :=
                          Target_Items.Element (Target_Pos);
                     begin
                        if Current_Item.Id = Target_Item.Id
                          and then To_String (Current_Item.Mode)
                                   /= To_String (Target_Item.Mode)
                          and then To_String (Current_Item.Mode)
                                   /= To_String (Base_Item.Mode)
                          and then To_String (Target_Item.Mode)
                                   = To_String (Base_Item.Mode)
                        then
                           Add_Merged_Path (Merged_Index, Current_Item);
                           Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
                        elsif Current_Item.Id = Target_Item.Id
                          and then To_String (Current_Item.Mode)
                                   /= To_String (Target_Item.Mode)
                          and then To_String (Current_Item.Mode)
                                   = To_String (Base_Item.Mode)
                          and then To_String (Target_Item.Mode)
                                   /= To_String (Base_Item.Mode)
                        then
                           Add_Merged_Path (Merged_Index, Target_Item);
                           Maybe_Write_Worktree_Item (Repo, Target_Item, Behavior);
                        elsif Current_Item.Id = Base_Item.Id
                          and then Target_Item.Id /= Base_Item.Id
                          and then To_String (Current_Item.Mode)
                                   /= To_String (Base_Item.Mode)
                          and then To_String (Target_Item.Mode)
                                   = To_String (Base_Item.Mode)
                        then
                           declare
                              Merged_Item : Version.Objects.Tree_Entry := Target_Item;
                           begin
                              Merged_Item.Mode := Current_Item.Mode;
                              Add_Merged_Path (Merged_Index, Merged_Item);
                              Maybe_Write_Worktree_Item (Repo, Merged_Item, Behavior);
                           end;
                        elsif Target_Item.Id = Base_Item.Id
                          and then Current_Item.Id /= Base_Item.Id
                          and then To_String (Target_Item.Mode)
                                   /= To_String (Base_Item.Mode)
                          and then To_String (Current_Item.Mode)
                                   = To_String (Base_Item.Mode)
                        then
                           declare
                              Merged_Item : Version.Objects.Tree_Entry := Current_Item;
                           begin
                              Merged_Item.Mode := Target_Item.Mode;
                              Add_Merged_Path (Merged_Index, Merged_Item);
                              Maybe_Write_Worktree_Item (Repo, Merged_Item, Behavior);
                           end;
                        else
                           Add_Stage_If_Found
                             (Merged_Index, Base_Items, Base_Pos, 1);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Current_Item, 2);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Target_Item, 3);
                           Handle_Two_Sided_Conflict
                             (Repo          => Repo,
                              Current_Name  => Current_Name,
                              Target_Name   => Target_Name,
                              Path_Text     => Path_Text,
                              Base_Item     => Base_Item,
                              Has_Base      => True,
                              Current_Item  => Current_Item,
                              Target_Item   => Target_Item,
                              Default_Kind  => Content_Conflict,
                              Merged_Index  => Merged_Index,
                              Conflicts     => Conflicts,
                              Behavior      => Behavior);
                        end if;
                     end;

                  elsif Target_Changed and then not Current_Changed then
                     Add_Merged_Path (Merged_Index, Target_Items.Element (Target_Pos));
                     Maybe_Write_Worktree_Item (Repo, Target_Items.Element (Target_Pos), Behavior);

                  else
                     Add_Merged_Path (Merged_Index, Current_Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Target_Items.Is_Empty then
         for I in Target_Items.First_Index .. Target_Items.Last_Index loop
            declare
               Target_Item : constant Version.Objects.Tree_Entry := Target_Items.Element (I);
               Path_Text : constant String := To_String (Target_Item.Path);
               Base_Pos : constant Natural := Find_Tree_Item (Base_Items, Path_Text);
               Current_Pos : constant Natural := Find_Tree_Item (Current_Items, Path_Text);
            begin
               if Skip_Target.Contains (Path_Text) then
                  null;
               else
                  Require_Safe_Path (Path_Text);

                  if Current_Pos = Natural'Last then
                     if Has_Directory_File_Conflict
                          (Path_Text, Current_Items, Target_Items)
                     then
                        if Behavior.Materialize_Virtual_Conflicts then
                           Add_Merged_Path (Merged_Index, Target_Item);
                        end if;
                        Add_Conflict (Conflicts, Path_Text, Directory_File_Conflict);
                        Add_Stage_If_Found (Merged_Index, Base_Items, Base_Pos, 1);
                        Add_Staged_Conflict_Path (Merged_Index, Target_Item, 3);

                     elsif Base_Pos /= Natural'Last
                       and then not Same_Entry
                         (Target_Item, Base_Items.Element (Base_Pos))
                     then
                        if Behavior.Favor = Favor_Current then
                           Maybe_Delete_Working_File (Repo, Path_Text, Behavior);
                        elsif Behavior.Favor = Favor_Target then
                           Add_Merged_Path (Merged_Index, Target_Item);
                           Maybe_Write_Worktree_Item (Repo, Target_Item, Behavior);
                        else
                           if Behavior.Materialize_Virtual_Conflicts then
                              Add_Merged_Path (Merged_Index, Target_Item);
                           end if;
                           Add_Conflict (Conflicts, Path_Text, Delete_Modify_Conflict);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Base_Items.Element (Base_Pos), 1);
                           Add_Staged_Conflict_Path (Merged_Index, Target_Item, 3);
                           Maybe_Write_Worktree_Item (Repo, Target_Item, Behavior);
                        end if;

                     elsif Base_Pos = Natural'Last then
                        Add_Merged_Path (Merged_Index, Target_Item);
                        Maybe_Write_Worktree_Item (Repo, Target_Item, Behavior);
                     end if;
                  end if;
               end if;
            end;
         end loop;
      end if;
   end Merge_Trees;

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Favor         : Conflict_Favor := Favor_Neither)
   is
      Behavior : Merge_Behavior;
   begin
      Behavior.Favor := Favor;
      Merge_Trees
        (Repo          => Repo,
         Current_Name  => Current_Name,
         Target_Name   => Target_Name,
         Base_Items    => Base_Items,
         Current_Items => Current_Items,
         Target_Items  => Target_Items,
         Merged_Index  => Merged_Index,
         Conflicts     => Conflicts,
         Behavior      => Behavior);
   end Merge_Trees;

   procedure Record_Rerere_Resolutions
     (Repo : Version.Repository.Repository_Handle; Conflicts : Conflict_Vectors.Vector)
   is
      MR : constant String := Merge_RR_Path (Repo);

      --  Look up the rr-cache key recorded for Want in the MERGE_RR map text
      --  (lines of "<key>\t<path>"); returns "" if absent.
      function Key_For_Path (Map_Text : String; Want : String) return String is
         Start : Natural := Map_Text'First;
         Found : Unbounded_String := Null_Unbounded_String;
      begin
         while Start <= Map_Text'Last loop
            declare
               EOL : Natural := Start;
            begin
               while EOL <= Map_Text'Last
                 and then Map_Text (EOL) /= Character'Val (10)
               loop
                  EOL := EOL + 1;
               end loop;
               declare
                  Line : constant String := Map_Text (Start .. EOL - 1);
                  HT   : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Line, String'(1 => Character'Val (9)));
               begin
                  if HT /= 0 and then Line (HT + 1 .. Line'Last) = Want then
                     Found := To_Unbounded_String (Line (Line'First .. HT - 1));
                  end if;
               end;
               Start := EOL + 1;
            end;
         end loop;
         return To_String (Found);
      end Key_For_Path;
   begin
      if Conflicts.Is_Empty
        or else not Rerere_Enabled (Repo, Merge_Behavior'(others => <>))
        or else not Ada.Directories.Exists (MR)
      then
         return;
      end if;

      declare
         Map_Text : constant String := Version.Files.Read_Binary_File (MR);
      begin
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            declare
               Path : constant String := To_String (Conflicts.Element (I).Path);
               Key  : constant String := Key_For_Path (Map_Text, Path);
               Absolute_Path : constant String :=
                 Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
            begin
               if Key'Length > 0
                 and then Ada.Directories.Exists (Absolute_Path)
                 and then Ada.Directories.Kind (Absolute_Path)
                   = Ada.Directories.Ordinary_File
               then
                  declare
                     Content : constant String :=
                       Version.Files.Read_Binary_File (Absolute_Path);
                  begin
                     if not Has_Conflict_Markers (Content) then
                        Ada.Directories.Create_Path
                          (Version.Files.Join
                             (Version.Files.Join
                                (Version.Repository.Common_Git_Dir (Repo), "rr-cache"),
                              Key));
                        Version.Files.Write_Binary_File_Atomic
                          (Path    => Rerere_Postimage_Path (Repo, Key),
                           Content => Content);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;

      Version.Files.Delete_File_If_Exists (MR);
   end Record_Rerere_Resolutions;

end Version.Merge;
