with Ada.Containers.Indefinite_Ordered_Maps;
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
with Version.Console;
with Version.Files;
with Version.Hash;
with Version.History;
with Version.LFS;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Path_Safety;
with Version.Platform;
with Version.Revisions;
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

   --  Line -> equivalence class, git's minimal-perfect-hash of a record.
   package Class_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => Natural);

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

   type Changed_Array is array (Integer range <>) of Boolean;

   --  git's xdl_fall_back_diff: run the classic (Myers) diff over one region
   --  of the two files as if it were a pair of standalone files, overwriting
   --  that region's changed flags.  Histogram diff falls back to this, and so
   --  does change compaction when it has merged two groups.
   procedure Myers_Region
     (Lines1, Lines2         : Line_Vectors.Vector;
      First1, Count1         : Integer;
      First2, Count2         : Integer;
      Changed1, Changed2     : in out Changed_Array);

   --  A group of changed lines: Start is the first changed line, Stop the
   --  first unchanged line after it (Stop = Start for an empty group).
   type Change_Group is record
      Start : Integer;
      Stop  : Integer;
   end record;

   function Is_Changed (Flags : Changed_Array; Index : Integer) return Boolean
   is (Index in Flags'Range and then Flags (Index));

   procedure Group_Init (Flags : Changed_Array; Group : out Change_Group) is
   begin
      Group := (Start => 0, Stop => 0);
      while Is_Changed (Flags, Group.Stop) loop
         Group.Stop := Group.Stop + 1;
      end loop;
   end Group_Init;

   function Group_Next
     (Flags : Changed_Array;
      Count : Natural;
      Group : in out Change_Group) return Boolean is
   begin
      if Group.Stop = Count then
         return False;
      end if;

      Group.Start := Group.Stop + 1;
      Group.Stop := Group.Start;
      while Is_Changed (Flags, Group.Stop) loop
         Group.Stop := Group.Stop + 1;
      end loop;

      return True;
   end Group_Next;

   function Group_Previous
     (Flags : Changed_Array;
      Group : in out Change_Group) return Boolean is
   begin
      if Group.Start = 0 then
         return False;
      end if;

      Group.Stop := Group.Start - 1;
      Group.Start := Group.Stop;
      while Is_Changed (Flags, Group.Start - 1) loop
         Group.Start := Group.Start - 1;
      end loop;

      return True;
   end Group_Previous;

   function Group_Slide_Down
     (Flags : in out Changed_Array;
      Lines : Line_Vectors.Vector;
      Count : Natural;
      Group : in out Change_Group) return Boolean is
   begin
      if Group.Stop < Count
        and then Lines.Element (Group.Start) = Lines.Element (Group.Stop)
      then
         Flags (Group.Start) := False;
         Group.Start := Group.Start + 1;
         Flags (Group.Stop) := True;
         Group.Stop := Group.Stop + 1;
         while Is_Changed (Flags, Group.Stop) loop
            Group.Stop := Group.Stop + 1;
         end loop;
         return True;
      else
         return False;
      end if;
   end Group_Slide_Down;

   function Group_Slide_Up
     (Flags : in out Changed_Array;
      Lines : Line_Vectors.Vector;
      Group : in out Change_Group) return Boolean is
   begin
      if Group.Start > 0
        and then Lines.Element (Group.Start - 1)
                 = Lines.Element (Group.Stop - 1)
      then
         Group.Start := Group.Start - 1;
         Flags (Group.Start) := True;
         Group.Stop := Group.Stop - 1;
         Flags (Group.Stop) := False;
         while Is_Changed (Flags, Group.Start - 1) loop
            Group.Start := Group.Start - 1;
         end loop;
         return True;
      else
         return False;
      end if;
   end Group_Slide_Up;

   --  git's indent heuristic (xdiff/xdiffi.c).  `git diff` enables it by
   --  default (diff.indentHeuristic, on since git 2.14); the merge machinery
   --  runs xdiff with flags = 0 and does not.  When a change group can slide,
   --  it scores every position it could sit at and picks the one that reads
   --  best -- preferring splits at blank lines and at sensible indentation.
   Max_Indent : constant := 200;
   Max_Blanks : constant := 20;

   Start_Of_File_Penalty : constant := 1;
   End_Of_File_Penalty   : constant := 21;
   Total_Blank_Weight    : constant := -30;
   Post_Blank_Weight     : constant := 6;
   Relative_Indent_Penalty            : constant := -4;
   Relative_Indent_With_Blank_Penalty : constant := 10;
   Relative_Outdent_Penalty            : constant := 24;
   Relative_Outdent_With_Blank_Penalty : constant := 17;
   Relative_Dedent_Penalty             : constant := 23;
   Relative_Dedent_With_Blank_Penalty  : constant := 17;
   Indent_Weight : constant := 60;
   Indent_Heuristic_Max_Sliding : constant := 100;

   --  Indent of a line in columns (TAB advances to the next multiple of 8),
   --  or -1 when the line is blank or all whitespace.
   function Get_Indent (Line : String) return Integer is
      Result : Integer := 0;
   begin
      for C of Line loop
         if not (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
                 or else C = ASCII.CR or else C = ASCII.VT
                 or else C = ASCII.FF)
         then
            return Result;
         elsif C = ' ' then
            Result := Result + 1;
         elsif C = ASCII.HT then
            Result := Result + 8 - (Result mod 8);
         end if;
         if Result >= Max_Indent then
            return Max_Indent;
         end if;
      end loop;
      return -1;   --  whitespace only
   end Get_Indent;

   type Split_Measurement is record
      End_Of_File : Boolean := False;
      Indent      : Integer := -1;
      Pre_Blank   : Integer := 0;
      Pre_Indent  : Integer := -1;
      Post_Blank  : Integer := 0;
      Post_Indent : Integer := -1;
   end record;

   type Split_Score is record
      Effective_Indent : Integer := 0;
      Penalty          : Integer := 0;
   end record;

   procedure Measure_Split
     (Lines : Line_Vectors.Vector;
      Split : Integer;
      M     : out Split_Measurement)
   is
      Count : constant Integer := Integer (Lines.Length);
   begin
      M := (others => <>);

      if Split >= Count then
         M.End_Of_File := True;
         M.Indent := -1;
      else
         M.End_Of_File := False;
         M.Indent := Get_Indent (Lines.Element (Split));
      end if;

      M.Pre_Blank := 0;
      M.Pre_Indent := -1;
      for I in reverse 0 .. Split - 1 loop
         M.Pre_Indent := Get_Indent (Lines.Element (I));
         exit when M.Pre_Indent /= -1;
         M.Pre_Blank := M.Pre_Blank + 1;
         if M.Pre_Blank = Max_Blanks then
            M.Pre_Indent := 0;
            exit;
         end if;
      end loop;

      M.Post_Blank := 0;
      M.Post_Indent := -1;
      for I in Split + 1 .. Count - 1 loop
         M.Post_Indent := Get_Indent (Lines.Element (I));
         exit when M.Post_Indent /= -1;
         M.Post_Blank := M.Post_Blank + 1;
         if M.Post_Blank = Max_Blanks then
            M.Post_Indent := 0;
            exit;
         end if;
      end loop;
   end Measure_Split;

   procedure Score_Add_Split
     (M : Split_Measurement; S : in out Split_Score)
   is
      Post_Blank, Total_Blank, Indent : Integer;
      Any_Blanks : Boolean;
   begin
      if M.Pre_Indent = -1 and then M.Pre_Blank = 0 then
         S.Penalty := S.Penalty + Start_Of_File_Penalty;
      end if;

      if M.End_Of_File then
         S.Penalty := S.Penalty + End_Of_File_Penalty;
      end if;

      Post_Blank := (if M.Indent = -1 then 1 + M.Post_Blank else 0);
      Total_Blank := M.Pre_Blank + Post_Blank;

      S.Penalty := S.Penalty + Total_Blank_Weight * Total_Blank;
      S.Penalty := S.Penalty + Post_Blank_Weight * Post_Blank;

      Indent := (if M.Indent /= -1 then M.Indent else M.Post_Indent);
      Any_Blanks := Total_Blank /= 0;

      S.Effective_Indent := S.Effective_Indent + Indent;

      if Indent = -1 or else M.Pre_Indent = -1 then
         null;
      elsif Indent > M.Pre_Indent then
         S.Penalty := S.Penalty +
           (if Any_Blanks then Relative_Indent_With_Blank_Penalty
            else Relative_Indent_Penalty);
      elsif Indent = M.Pre_Indent then
         null;
      elsif M.Post_Indent /= -1 and then M.Post_Indent > Indent then
         S.Penalty := S.Penalty +
           (if Any_Blanks then Relative_Outdent_With_Blank_Penalty
            else Relative_Outdent_Penalty);
      else
         S.Penalty := S.Penalty +
           (if Any_Blanks then Relative_Dedent_With_Blank_Penalty
            else Relative_Dedent_Penalty);
      end if;
   end Score_Add_Split;

   function Score_Cmp (S1, S2 : Split_Score) return Integer is
      Cmp : constant Integer :=
        (if S1.Effective_Indent > S2.Effective_Indent then 1
         elsif S1.Effective_Indent < S2.Effective_Indent then -1
         else 0);
   begin
      return Indent_Weight * Cmp + (S1.Penalty - S2.Penalty);
   end Score_Cmp;

   --  git's xdl_change_compact (xdiff/xdiffi.c): slide every change group as
   --  far down as it will go, then back up to the last position where it lines
   --  up with a change group on the other side.  Both sides are compacted the
   --  same way, so the two change scripts agree on where a change begins --
   --  which is what keeps merge hunks (and rerere's preimage) aligned with
   --  git's.  git runs the merge diff with flags = 0, so the indent heuristic
   --  is deliberately not applied here.
   procedure Change_Compact
     (Flags            : in out Changed_Array;
      Lines            : Line_Vectors.Vector;
      Other_Flags      : in out Changed_Array;
      Other_Lines      : Line_Vectors.Vector;
      Histogram        : Boolean;
      Indent_Heuristic : Boolean := False)
   is
      Count       : constant Natural := Natural (Lines.Length);
      Other_Count : constant Natural := Natural (Other_Lines.Length);
      Group, Other_Group : Change_Group;
      Group_Origin       : Change_Group;
      Earliest_Stop      : Integer;
      Matching_Other     : Integer;
      Group_Size         : Integer;
   begin
      Group_Init (Flags, Group);
      Group_Init (Other_Flags, Other_Group);

      loop
         if Group.Stop /= Group.Start then
            Group_Origin := Group;

            loop
               Group_Size := Group.Stop - Group.Start;
               Matching_Other := -1;

               --  Shift the group as far up as it goes.
               while Group_Slide_Up (Flags, Lines, Group) loop
                  exit when not Group_Previous (Other_Flags, Other_Group);
               end loop;

               Earliest_Stop := Group.Stop;
               if Other_Group.Stop > Other_Group.Start then
                  Matching_Other := Group.Stop;
               end if;

               --  Then as far down as it goes, remembering the last stop that
               --  aligned with a non-empty group on the other side.
               while Group_Slide_Down (Flags, Lines, Count, Group) loop
                  exit when not Group_Next
                    (Other_Flags, Other_Count, Other_Group);
                  if Other_Group.Stop > Other_Group.Start then
                     Matching_Other := Group.Stop;
                  end if;
               end loop;

               --  Sliding may have swallowed a neighbouring group; redo.
               exit when Group_Size = Group.Stop - Group.Start;
            end loop;

            if Group.Stop = Earliest_Stop then
               null;   --  the group could not be shifted at all
            elsif Matching_Other /= -1 then
               --  Slide back up to line up with the other side's group, so a
               --  single change does not get split into an add and a delete.
               while Other_Group.Stop = Other_Group.Start loop
                  exit when not Group_Slide_Up (Flags, Lines, Group);
                  exit when not Group_Previous (Other_Flags, Other_Group);
               end loop;

            elsif Indent_Heuristic then
               --  Nothing to line up with, but the group can move: score every
               --  position it could sit at and slide back to the best one.
               --  (The group is currently as far down as it will go, so only
               --  upward shifts are considered.)
               declare
                  Shift      : Integer;
                  Best_Shift : Integer := -1;
                  Best_Score : Split_Score;
                  Size       : constant Integer := Group.Stop - Group.Start;
               begin
                  Shift := Earliest_Stop;
                  if Group.Stop - Size - 1 > Shift then
                     Shift := Group.Stop - Size - 1;
                  end if;
                  if Group.Stop - Indent_Heuristic_Max_Sliding > Shift then
                     Shift := Group.Stop - Indent_Heuristic_Max_Sliding;
                  end if;

                  while Shift <= Group.Stop loop
                     declare
                        M     : Split_Measurement;
                        Score : Split_Score;
                     begin
                        Measure_Split (Lines, Shift, M);
                        Score_Add_Split (M, Score);
                        Measure_Split (Lines, Shift - Size, M);
                        Score_Add_Split (M, Score);

                        if Best_Shift = -1
                          or else Score_Cmp (Score, Best_Score) <= 0
                        then
                           Best_Score := Score;
                           Best_Shift := Shift;
                        end if;
                     end;
                     Shift := Shift + 1;
                  end loop;

                  while Group.Stop > Best_Shift loop
                     exit when not Group_Slide_Up (Flags, Lines, Group);
                     exit when not Group_Previous (Other_Flags, Other_Group);
                  end loop;
               end;
            end if;

            --  Sliding may have merged groups, and the combined group can now
            --  have matching lines on both sides that the original groups did
            --  not.  git re-diffs it -- but only for histogram diff, whose LCS
            --  admits that; Myers is already minimal, so it cannot happen.
            if Histogram
              and then Other_Group.Stop /= Other_Group.Start
              and then (Group.Start /= Group_Origin.Start
                        or else Group.Stop /= Group_Origin.Stop)
            then
               Myers_Region
                 (Lines1   => Lines,
                  Lines2   => Other_Lines,
                  First1   => Group.Start,
                  Count1   => Group.Stop - Group.Start,
                  First2   => Other_Group.Start,
                  Count2   => Other_Group.Stop - Other_Group.Start,
                  Changed1 => Flags,
                  Changed2 => Other_Flags);
            end if;
         end if;

         exit when not Group_Next (Flags, Count, Group);
         exit when not Group_Next (Other_Flags, Other_Count, Other_Group);
      end loop;
   end Change_Compact;

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.CR or else C = ASCII.VT or else C = ASCII.FF);

   --  The whitespace-folded form of a line: two lines compare equal under a
   --  given ignore-whitespace mode exactly when their folded forms are equal.
   --  This is git's xdl_recmatch expressed as a normalisation, which is how
   --  xdiff itself hashes records (whitespace flags feed the record hash), so
   --  every comparison downstream -- classification, change compaction,
   --  conflict refinement -- folds the same way.  Emission always uses the
   --  original, unfolded lines.
   function Normalize_Line
     (Line : String; Mode : Whitespace_Mode) return String is
   begin
      case Mode is
         when Whitespace_Strict =>
            return Line;

         when Whitespace_Ignore_All_Space =>
            declare
               Result : String (1 .. Line'Length);
               Last   : Natural := 0;
            begin
               for C of Line loop
                  if not Is_Space (C) then
                     Last := Last + 1;
                     Result (Last) := C;
                  end if;
               end loop;
               return Result (1 .. Last);
            end;

         when Whitespace_Ignore_Space_Change =>
            --  Every run of whitespace collapses to one space; trailing
            --  whitespace drops out entirely.
            declare
               Result : String (1 .. Line'Length);
               Last   : Natural := 0;
               I      : Natural := Line'First;
            begin
               while I <= Line'Last loop
                  if Is_Space (Line (I)) then
                     while I <= Line'Last and then Is_Space (Line (I)) loop
                        I := I + 1;
                     end loop;
                     if I <= Line'Last then
                        Last := Last + 1;
                        Result (Last) := ' ';
                     end if;
                  else
                     Last := Last + 1;
                     Result (Last) := Line (I);
                     I := I + 1;
                  end if;
               end loop;
               return Result (1 .. Last);
            end;

         when Whitespace_Ignore_Space_At_EOL =>
            declare
               Last : Natural := Line'Last;
            begin
               while Last >= Line'First and then Is_Space (Line (Last)) loop
                  Last := Last - 1;
               end loop;
               return Line (Line'First .. Last);
            end;

         when Whitespace_Ignore_CR_At_EOL =>
            --  Only a CR that terminates a complete line is ignorable; a CR
            --  ending an incomplete last line is content.
            if Line'Length >= 2
              and then Line (Line'Last) = ASCII.LF
              and then Line (Line'Last - 1) = ASCII.CR
            then
               return Line (Line'First .. Line'Last - 2) & ASCII.LF;
            end if;
            return Line;
      end case;
   end Normalize_Line;

   function Normalize_Lines
     (Lines : Line_Vectors.Vector; Mode : Whitespace_Mode)
      return Line_Vectors.Vector
   is
      Result : Line_Vectors.Vector;
   begin
      if Mode = Whitespace_Strict then
         return Lines;
      end if;

      for Line of Lines loop
         Result.Append (Normalize_Line (Line, Mode));
      end loop;
      return Result;
   end Normalize_Lines;

   --  git's xdl_bogosqrt: the shift-based integer square-root approximation
   --  xdiff uses to size its heuristic limits.
   function Bogosqrt (N : Natural) return Natural is
      Result    : Natural := 1;
      Remaining : Natural := N;
   begin
      while Remaining > 0 loop
         Result := Result * 2;
         Remaining := Remaining / 4;
      end loop;
      return Result;
   end Bogosqrt;

   --  git's xdl_do_diff (xdiff/xdiffi.c + xprepare.c): classify the lines into
   --  equivalence classes, trim the common head and tail, discard records that
   --  cannot possibly match (xdl_cleanup_records), then run Myers' O(ND)
   --  divide-and-conquer (xdl_recs_cmp/xdl_split) over what is left, marking
   --  the changed lines on each side.  Reproducing xdiff here -- rather than
   --  taking any equally minimal script -- is what makes version's hunks (and
   --  therefore its conflicts) land where git's do.
   procedure Myers_Changed
     (Lines1, Lines2 : Line_Vectors.Vector;
      Need_Min       : Boolean;
      Changed1       : in out Changed_Array;
      Changed2       : in out Changed_Array)
   is
      Snake_Cnt : constant := 20;    --  XDL_SNAKE_CNT
      Heur_Min  : constant := 256;   --  XDL_HEUR_MIN_COST
      Max_Eqlimit    : constant := 1024;  --  XDL_MAX_EQLIMIT
      Simscan_Window : constant := 100;   --  XDL_SIMSCAN_WINDOW
      Kpdis_Run      : constant := 4;     --  XDL_KPDIS_RUN
      Line_Max : constant Integer := Integer'Last / 4;

      N1 : constant Natural := Natural (Lines1.Length);
      N2 : constant Natural := Natural (Lines2.Length);

      type Index_Array is array (Integer range <>) of Integer;

      --  Equivalence class of each line, and how often each class occurs on
      --  either side (git's minimal_perfect_hash + rcrec->len1/len2).
      Class1 : Index_Array (0 .. N1 - 1) := [others => 0];
      Class2 : Index_Array (0 .. N2 - 1) := [others => 0];
      Count1 : Index_Array (0 .. N1 + N2) := [others => 0];
      Count2 : Index_Array (0 .. N1 + N2) := [others => 0];

      Classes    : Class_Maps.Map;
      Next_Class : Natural := 0;

      procedure Classify
        (Lines : Line_Vectors.Vector;
         Class : in out Index_Array;
         Count : in out Index_Array)
      is
         use Class_Maps;
      begin
         for I in 0 .. Natural (Lines.Length) - 1 loop
            declare
               Line   : constant String := Lines.Element (I);
               Cursor : constant Class_Maps.Cursor := Classes.Find (Line);
               Id     : Natural;
            begin
               if Cursor = No_Element then
                  Id := Next_Class;
                  Classes.Insert (Line, Id);
                  Next_Class := Next_Class + 1;
               else
                  Id := Element (Cursor);
               end if;
               Class (I) := Id;
               Count (Id) := Count (Id) + 1;
            end;
         end loop;
      end Classify;

      --  Records surviving the cleanup, as indices into the original lines
      --  (git's reference_index); the diff proper runs over these only.
      Ref1 : Index_Array (0 .. N1) := [others => 0];
      Ref2 : Index_Array (0 .. N2) := [others => 0];
      NRef1 : Natural := 0;
      NRef2 : Natural := 0;

      function Hash1 (I : Integer) return Integer is (Class1 (Ref1 (I)));
      function Hash2 (I : Integer) return Integer is (Class2 (Ref2 (I)));

      type Action_Kind is (Discard, Keep, Investigate);
      type Action_Array is array (Integer range <>) of Action_Kind;

      --  git's xdl_clean_mmatch: a multi-match line is only discarded when it
      --  sits inside a run of non-matching lines.
      function Clean_Mmatch
        (Action : Action_Array; I : Integer; Len : Integer) return Boolean
      is
         S : Integer := 0;
         E : Integer := Len - 1;
         R : Integer;
         RDis0, RPDis0, RDis1, RPDis1 : Integer;
      begin
         if I - S > Simscan_Window then
            S := I - Simscan_Window;
         end if;
         if E - I > Simscan_Window then
            E := I + Simscan_Window;
         end if;

         R := 1;
         RDis0 := 0;
         RPDis0 := 1;
         while I - R >= S loop
            exit when Action (I - R) = Keep;
            if Action (I - R) = Discard then
               RDis0 := RDis0 + 1;
            else
               RPDis0 := RPDis0 + 1;
            end if;
            R := R + 1;
         end loop;

         if RDis0 = 0 then
            return False;
         end if;

         R := 1;
         RDis1 := 0;
         RPDis1 := 1;
         while I + R <= E loop
            exit when Action (I + R) = Keep;
            if Action (I + R) = Discard then
               RDis1 := RDis1 + 1;
            else
               RPDis1 := RPDis1 + 1;
            end if;
            R := R + 1;
         end loop;

         if RDis1 = 0 then
            return False;
         end if;

         RDis1 := RDis1 + RDis0;
         RPDis1 := RPDis1 + RPDis0;
         return RPDis1 * Kpdis_Run < RPDis1 + RDis1;
      end Clean_Mmatch;
   begin
      if N1 = 0 and then N2 = 0 then
         return;
      end if;

      Classify (Lines1, Class1, Count1);
      Classify (Lines2, Class2, Count2);

      --  xdl_trim_ends: the common head and tail can never change.
      declare
         Limit  : constant Integer := Integer'Min (N1, N2);
         DStart : Integer := 0;
         Suffix : Integer := 0;
         Off, Len1, Len2 : Integer;
      begin
         while DStart < Limit
           and then Class1 (DStart) = Class2 (DStart)
         loop
            DStart := DStart + 1;
         end loop;

         while Suffix < Limit - DStart
           and then Class1 (N1 - Suffix - 1) = Class2 (N2 - Suffix - 1)
         loop
            Suffix := Suffix + 1;
         end loop;

         Off := DStart;
         Len1 := (N1 - Suffix - 1) - Off + 1;
         Len2 := (N2 - Suffix - 1) - Off + 1;
         if Len1 < 0 then
            Len1 := 0;
         end if;
         if Len2 < 0 then
            Len2 := 0;
         end if;

         --  xdl_cleanup_records: lines with no counterpart at all are changed
         --  outright; lines with too many counterparts are only discarded when
         --  they sit in a run of such lines.
         declare
            Action1 : Action_Array (0 .. Integer'Max (Len1 - 1, 0));
            Action2 : Action_Array (0 .. Integer'Max (Len2 - 1, 0));
            MLim1 : constant Integer :=
              (if Need_Min then Integer'Last
               else Integer'Min (Bogosqrt (N1), Max_Eqlimit));
            MLim2 : constant Integer :=
              (if Need_Min then Integer'Last
               else Integer'Min (Bogosqrt (N2), Max_Eqlimit));
            NM : Integer;
            Act : Action_Kind;
         begin
            for I in 0 .. Len1 - 1 loop
               NM := Count2 (Class1 (I + Off));
               Action1 (I) :=
                 (if NM = 0 then Discard
                  elsif NM < MLim1 then Keep
                  else Investigate);
            end loop;
            for I in 0 .. Len2 - 1 loop
               NM := Count1 (Class2 (I + Off));
               Action2 (I) :=
                 (if NM = 0 then Discard
                  elsif NM < MLim2 then Keep
                  else Investigate);
            end loop;

            for I in 0 .. Len1 - 1 loop
               Act := Action1 (I);
               if Act = Investigate then
                  Act := (if Clean_Mmatch (Action1, I, Len1)
                          then Discard else Keep);
               end if;
               if Act = Keep then
                  Ref1 (NRef1) := I + Off;
                  NRef1 := NRef1 + 1;
               else
                  Changed1 (I + Off) := True;
               end if;
            end loop;

            for I in 0 .. Len2 - 1 loop
               Act := Action2 (I);
               if Act = Investigate then
                  Act := (if Clean_Mmatch (Action2, I, Len2)
                          then Discard else Keep);
               end if;
               if Act = Keep then
                  Ref2 (NRef2) := I + Off;
                  NRef2 := NRef2 + 1;
               else
                  Changed2 (I + Off) := True;
               end if;
            end loop;
         end;
      end;

      --  The Myers search itself, over the surviving records.
      declare
         NDiags : constant Integer := NRef1 + NRef2 + 3;
         MxCost : constant Integer :=
           Integer'Max (Bogosqrt (NDiags), 256);   --  XDL_MAX_COST_MIN
         KVDF : Index_Array (-(NRef2 + 1) .. NRef1 + 1) := [others => 0];
         KVDB : Index_Array (-(NRef2 + 1) .. NRef1 + 1) := [others => 0];

         procedure Split
           (Off1, Lim1, Off2, Lim2 : Integer;
            Want_Min               : Boolean;
            Split1, Split2         : out Integer;
            Min_Lo, Min_Hi         : out Boolean)
         is
            DMin : constant Integer := Off1 - Lim2;
            DMax : constant Integer := Lim1 - Off2;
            FMid : constant Integer := Off1 - Off2;
            BMid : constant Integer := Lim1 - Lim2;
            Odd  : constant Boolean := ((FMid - BMid) mod 2) /= 0;
            FMin : Integer := FMid;
            FMax : Integer := FMid;
            BMin : Integer := BMid;
            BMax : Integer := BMid;
            EC   : Integer := 1;
            Got_Snake : Boolean;
            D, I1, I2, Prev1, Best, DD, V, K : Integer;
         begin
            Split1 := 0;
            Split2 := 0;
            Min_Lo := False;
            Min_Hi := False;
            KVDF (FMid) := Off1;
            KVDB (BMid) := Lim1;

            loop
               Got_Snake := False;

               --  Extend the forward diagonal band by one.
               if FMin > DMin then
                  FMin := FMin - 1;
                  KVDF (FMin - 1) := -1;
               else
                  FMin := FMin + 1;
               end if;
               if FMax < DMax then
                  FMax := FMax + 1;
                  KVDF (FMax + 1) := -1;
               else
                  FMax := FMax - 1;
               end if;

               D := FMax;
               while D >= FMin loop
                  if KVDF (D - 1) >= KVDF (D + 1) then
                     I1 := KVDF (D - 1) + 1;
                  else
                     I1 := KVDF (D + 1);
                  end if;
                  Prev1 := I1;
                  I2 := I1 - D;
                  while I1 < Lim1 and then I2 < Lim2
                    and then Hash1 (I1) = Hash2 (I2)
                  loop
                     I1 := I1 + 1;
                     I2 := I2 + 1;
                  end loop;
                  if I1 - Prev1 > Snake_Cnt then
                     Got_Snake := True;
                  end if;
                  KVDF (D) := I1;
                  if Odd and then BMin <= D and then D <= BMax
                    and then KVDB (D) <= I1
                  then
                     Split1 := I1;
                     Split2 := I2;
                     Min_Lo := True;
                     Min_Hi := True;
                     return;
                  end if;
                  D := D - 2;
               end loop;

               --  Extend the backward diagonal band by one.
               if BMin > DMin then
                  BMin := BMin - 1;
                  KVDB (BMin - 1) := Line_Max;
               else
                  BMin := BMin + 1;
               end if;
               if BMax < DMax then
                  BMax := BMax + 1;
                  KVDB (BMax + 1) := Line_Max;
               else
                  BMax := BMax - 1;
               end if;

               D := BMax;
               while D >= BMin loop
                  if KVDB (D - 1) < KVDB (D + 1) then
                     I1 := KVDB (D - 1);
                  else
                     I1 := KVDB (D + 1) - 1;
                  end if;
                  Prev1 := I1;
                  I2 := I1 - D;
                  while I1 > Off1 and then I2 > Off2
                    and then Hash1 (I1 - 1) = Hash2 (I2 - 1)
                  loop
                     I1 := I1 - 1;
                     I2 := I2 - 1;
                  end loop;
                  if Prev1 - I1 > Snake_Cnt then
                     Got_Snake := True;
                  end if;
                  KVDB (D) := I1;
                  if not Odd and then FMin <= D and then D <= FMax
                    and then I1 <= KVDF (D)
                  then
                     Split1 := I1;
                     Split2 := I2;
                     Min_Lo := True;
                     Min_Hi := True;
                     return;
                  end if;
                  D := D - 2;
               end loop;

               if not Want_Min then
                  --  A long snake means we may already be on a good path:
                  --  sample the diagonals for one that has reached far enough
                  --  to be worth cutting the search short (git's XDL_K_HEUR).
                  if Got_Snake and then EC > Heur_Min then
                     Best := 0;
                     D := FMax;
                     while D >= FMin loop
                        DD := (if D > FMid then D - FMid else FMid - D);
                        I1 := KVDF (D);
                        I2 := I1 - D;
                        V := (I1 - Off1) + (I2 - Off2) - DD;
                        if V > 4 * EC and then V > Best
                          and then Off1 + Snake_Cnt <= I1 and then I1 < Lim1
                          and then Off2 + Snake_Cnt <= I2 and then I2 < Lim2
                        then
                           K := 1;
                           while Hash1 (I1 - K) = Hash2 (I2 - K) loop
                              if K = Snake_Cnt then
                                 Best := V;
                                 Split1 := I1;
                                 Split2 := I2;
                                 exit;
                              end if;
                              K := K + 1;
                           end loop;
                        end if;
                        D := D - 2;
                     end loop;
                     if Best > 0 then
                        Min_Lo := True;
                        Min_Hi := False;
                        return;
                     end if;

                     Best := 0;
                     D := BMax;
                     while D >= BMin loop
                        DD := (if D > BMid then D - BMid else BMid - D);
                        I1 := KVDB (D);
                        I2 := I1 - D;
                        V := (Lim1 - I1) + (Lim2 - I2) - DD;
                        if V > 4 * EC and then V > Best
                          and then Off1 < I1 and then I1 <= Lim1 - Snake_Cnt
                          and then Off2 < I2 and then I2 <= Lim2 - Snake_Cnt
                        then
                           K := 0;
                           while Hash1 (I1 + K) = Hash2 (I2 + K) loop
                              if K = Snake_Cnt - 1 then
                                 Best := V;
                                 Split1 := I1;
                                 Split2 := I2;
                                 exit;
                              end if;
                              K := K + 1;
                           end loop;
                        end if;
                        D := D - 2;
                     end loop;
                     if Best > 0 then
                        Min_Lo := False;
                        Min_Hi := True;
                        return;
                     end if;
                  end if;

                  --  Too expensive: settle for the furthest reaching path.
                  if EC >= MxCost then
                     declare
                        FBest, FBest1, BBest, BBest1 : Integer;
                     begin
                        FBest := -1;
                        FBest1 := -1;
                        D := FMax;
                        while D >= FMin loop
                           I1 := Integer'Min (KVDF (D), Lim1);
                           I2 := I1 - D;
                           if Lim2 < I2 then
                              I1 := Lim2 + D;
                              I2 := Lim2;
                           end if;
                           if FBest < I1 + I2 then
                              FBest := I1 + I2;
                              FBest1 := I1;
                           end if;
                           D := D - 2;
                        end loop;

                        BBest := Line_Max;
                        BBest1 := Line_Max;
                        D := BMax;
                        while D >= BMin loop
                           I1 := Integer'Max (Off1, KVDB (D));
                           I2 := I1 - D;
                           if I2 < Off2 then
                              I1 := Off2 + D;
                              I2 := Off2;
                           end if;
                           if I1 + I2 < BBest then
                              BBest := I1 + I2;
                              BBest1 := I1;
                           end if;
                           D := D - 2;
                        end loop;

                        if (Lim1 + Lim2) - BBest < FBest - (Off1 + Off2) then
                           Split1 := FBest1;
                           Split2 := FBest - FBest1;
                           Min_Lo := True;
                           Min_Hi := False;
                        else
                           Split1 := BBest1;
                           Split2 := BBest - BBest1;
                           Min_Lo := False;
                           Min_Hi := True;
                        end if;
                        return;
                     end;
                  end if;
               end if;

               EC := EC + 1;
            end loop;
         end Split;

         procedure Recs_Cmp
           (First1, Last1, First2, Last2 : Integer; Want_Min : Boolean)
         is
            Off1 : Integer := First1;
            Lim1 : Integer := Last1;
            Off2 : Integer := First2;
            Lim2 : Integer := Last2;
            Split1, Split2 : Integer;
            Min_Lo, Min_Hi : Boolean;
         begin
            --  Shrink the box along its leading and trailing snakes.
            while Off1 < Lim1 and then Off2 < Lim2
              and then Hash1 (Off1) = Hash2 (Off2)
            loop
               Off1 := Off1 + 1;
               Off2 := Off2 + 1;
            end loop;
            while Off1 < Lim1 and then Off2 < Lim2
              and then Hash1 (Lim1 - 1) = Hash2 (Lim2 - 1)
            loop
               Lim1 := Lim1 - 1;
               Lim2 := Lim2 - 1;
            end loop;

            if Off1 = Lim1 then
               for I in Off2 .. Lim2 - 1 loop
                  Changed2 (Ref2 (I)) := True;
               end loop;
            elsif Off2 = Lim2 then
               for I in Off1 .. Lim1 - 1 loop
                  Changed1 (Ref1 (I)) := True;
               end loop;
            else
               Split (Off1, Lim1, Off2, Lim2, Want_Min,
                      Split1, Split2, Min_Lo, Min_Hi);
               Recs_Cmp (Off1, Split1, Off2, Split2, Min_Lo);
               Recs_Cmp (Split1, Lim1, Split2, Lim2, Min_Hi);
            end if;
         end Recs_Cmp;
      begin
         Recs_Cmp (0, NRef1, 0, NRef2, Need_Min);
      end;
   end Myers_Changed;

   procedure Myers_Region
     (Lines1, Lines2         : Line_Vectors.Vector;
      First1, Count1         : Integer;
      First2, Count2         : Integer;
      Changed1, Changed2     : in out Changed_Array)
   is
      Sub1, Sub2 : Line_Vectors.Vector;
   begin
      if Count1 <= 0 and then Count2 <= 0 then
         return;
      end if;

      for K in 0 .. Count1 - 1 loop
         Sub1.Append (Lines1.Element (First1 + K));
      end loop;
      for K in 0 .. Count2 - 1 loop
         Sub2.Append (Lines2.Element (First2 + K));
      end loop;

      declare
         Sub_Changed1 : Changed_Array (0 .. Count1 - 1) := [others => False];
         Sub_Changed2 : Changed_Array (0 .. Count2 - 1) := [others => False];
      begin
         Myers_Changed
           (Lines1   => Sub1,
            Lines2   => Sub2,
            Need_Min => False,
            Changed1 => Sub_Changed1,
            Changed2 => Sub_Changed2);

         --  git memcpy's the region's flags back, overwriting them.
         for K in 0 .. Count1 - 1 loop
            Changed1 (First1 + K) := Sub_Changed1 (K);
         end loop;
         for K in 0 .. Count2 - 1 loop
            Changed2 (First2 + K) := Sub_Changed2 (K);
         end loop;
      end;
   end Myers_Region;

   --  git's xdl_do_histogram_diff (xdiff/xhistogram.c) -- the algorithm `git
   --  merge` actually uses (merge-ort sets HISTOGRAM_DIFF; only merge-file
   --  defaults to Myers).  It indexes the occurrences of each line of side 1,
   --  finds the common region built from the *least* repeated line, and
   --  recurses either side of it; if the region is too repetitive (or nothing
   --  common was found) it falls back to Myers.  Lines are numbered from 1
   --  here, as in git, so that 0 can mean "none".
   procedure Histogram_Changed
     (Lines1, Lines2     : Line_Vectors.Vector;
      Changed1, Changed2 : in out Changed_Array)
   is
      Max_Chain_Length : constant := 64;

      type Record_Entry is record
         Ptr : Natural;   --  lowest line (1-based) holding this content
         Cnt : Natural;   --  how many times it occurs in side 1's region
      end record;

      package Record_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Record_Entry);

      function Same_1_2 (A, B : Integer) return Boolean is
        (Lines1.Element (A - 1) = Lines2.Element (B - 1));

      procedure Histogram_Region (First1, Num1, First2, Num2 : Integer);

      procedure Histogram_Region (First1, Num1, First2, Num2 : Integer) is
         Line1  : Integer := First1;
         Count1 : Integer := Num1;
         Line2  : Integer := First2;
         Count2 : Integer := Num2;
      begin
         loop
            if Count1 <= 0 and then Count2 <= 0 then
               return;
            end if;

            if Count1 = 0 then
               for K in 0 .. Count2 - 1 loop
                  Changed2 (Line2 + K - 1) := True;
               end loop;
               return;
            elsif Count2 = 0 then
               for K in 0 .. Count1 - 1 loop
                  Changed1 (Line1 + K - 1) := True;
               end loop;
               return;
            end if;

            declare
               End1 : constant Integer := Line1 + Count1 - 1;
               End2 : constant Integer := Line2 + Count2 - 1;

               Records  : Record_Vectors.Vector;
               By_Line  : Class_Maps.Map;   --  line content -> record index
               Next_Ptr : array (Line1 .. End1) of Natural := [others => 0];
               Line_Map : array (Line1 .. End1) of Natural := [others => 0];

               Best_Begin1, Best_End1 : Natural := 0;
               Best_Begin2, Best_End2 : Natural := 0;
               Best_Cnt   : Natural := Max_Chain_Length + 1;
               Has_Common : Boolean := False;

               function Cnt_At (Ptr : Integer) return Natural is
                 (Records.Element (Line_Map (Ptr)).Cnt);

               procedure Scan_Side1 is
                  use Class_Maps;
               begin
                  --  Walk side 1 backwards so each record's Ptr ends up on its
                  --  first occurrence and Next_Ptr chains forward.
                  for Ptr in reverse Line1 .. End1 loop
                     declare
                        Key : constant String := Lines1.Element (Ptr - 1);
                        Pos : constant Class_Maps.Cursor := By_Line.Find (Key);
                     begin
                        if Pos = No_Element then
                           Records.Append (Record_Entry'(Ptr => Ptr, Cnt => 1));
                           By_Line.Insert (Key, Records.Last_Index);
                           Line_Map (Ptr) := Records.Last_Index;
                        else
                           declare
                              Id  : constant Positive := Element (Pos);
                              Rec : Record_Entry := Records.Element (Id);
                           begin
                              Next_Ptr (Ptr) := Rec.Ptr;
                              Rec.Ptr := Ptr;
                              Rec.Cnt := Rec.Cnt + 1;
                              Records.Replace_Element (Id, Rec);
                              Line_Map (Ptr) := Id;
                           end;
                        end if;
                     end;
                  end loop;
               end Scan_Side1;

               function Try_LCS (B_Ptr : Integer) return Integer is
                  use Class_Maps;
                  B_Next : Integer := B_Ptr + 1;
                  Pos    : constant Class_Maps.Cursor :=
                    By_Line.Find (Lines2.Element (B_Ptr - 1));
                  Id     : Positive;
                  Rec    : Record_Entry;
                  As, Ae, Bs, Be, Np, Rc : Integer;
                  Should_Break : Boolean;
               begin
                  if Pos = No_Element then
                     return B_Next;
                  end if;

                  Id  := Element (Pos);
                  Rec := Records.Element (Id);

                  --  Too repetitive to be a good anchor: note that something
                  --  is common and move on.
                  if Rec.Cnt > Best_Cnt then
                     Has_Common := True;
                     return B_Next;
                  end if;

                  Has_Common := True;
                  As := Rec.Ptr;

                  loop
                     Should_Break := False;
                     Np := Next_Ptr (As);
                     Bs := B_Ptr;
                     Ae := As;
                     Be := Bs;
                     Rc := Rec.Cnt;

                     while Line1 < As and then Line2 < Bs
                       and then Same_1_2 (As - 1, Bs - 1)
                     loop
                        As := As - 1;
                        Bs := Bs - 1;
                        if Rc > 1 then
                           Rc := Integer'Min (Rc, Cnt_At (As));
                        end if;
                     end loop;

                     while Ae < End1 and then Be < End2
                       and then Same_1_2 (Ae + 1, Be + 1)
                     loop
                        Ae := Ae + 1;
                        Be := Be + 1;
                        if Rc > 1 then
                           Rc := Integer'Min (Rc, Cnt_At (Ae));
                        end if;
                     end loop;

                     if B_Next <= Be then
                        B_Next := Be + 1;
                     end if;

                     --  Prefer a longer region, or an equally long one built
                     --  from a rarer line.
                     if Best_End1 - Best_Begin1 < Ae - As
                       or else Rc < Best_Cnt
                     then
                        Best_Begin1 := As;
                        Best_Begin2 := Bs;
                        Best_End1 := Ae;
                        Best_End2 := Be;
                        Best_Cnt := Rc;
                     end if;

                     exit when Np = 0;

                     --  Skip occurrences already covered by this region.
                     while Np <= Ae loop
                        Np := Next_Ptr (Np);
                        if Np = 0 then
                           Should_Break := True;
                           exit;
                        end if;
                     end loop;

                     exit when Should_Break;
                     As := Np;
                  end loop;

                  return B_Next;
               end Try_LCS;

               B_Ptr : Integer;
            begin
               Scan_Side1;

               B_Ptr := Line2;
               while B_Ptr <= End2 loop
                  B_Ptr := Try_LCS (B_Ptr);
               end loop;

               if Has_Common and then Max_Chain_Length < Best_Cnt then
                  --  Everything in common was too repetitive to anchor on.
                  Myers_Region
                    (Lines1   => Lines1,
                     Lines2   => Lines2,
                     First1   => Line1 - 1,
                     Count1   => Count1,
                     First2   => Line2 - 1,
                     Count2   => Count2,
                     Changed1 => Changed1,
                     Changed2 => Changed2);
                  return;

               elsif Best_Begin1 = 0 then
                  --  Nothing in common at all.
                  for K in 0 .. Count1 - 1 loop
                     Changed1 (Line1 + K - 1) := True;
                  end loop;
                  for K in 0 .. Count2 - 1 loop
                     Changed2 (Line2 + K - 1) := True;
                  end loop;
                  return;

               else
                  --  Recurse before the common region, then loop on what
                  --  follows it (git unrolls this tail recursion too).
                  Histogram_Region
                    (Line1, Best_Begin1 - Line1,
                     Line2, Best_Begin2 - Line2);
                  Count1 := End1 - Best_End1;
                  Line1  := Best_End1 + 1;
                  Count2 := End2 - Best_End2;
                  Line2  := Best_End2 + 1;
               end if;
            end;
         end loop;
      end Histogram_Region;
   begin
      Histogram_Region
        (1, Natural (Lines1.Length), 1, Natural (Lines2.Length));
   end Histogram_Changed;

   --  git's xdl_do_patience_diff (xdiff/xpatience.c): anchor on the lines that
   --  occur exactly once on each side, take the longest increasing sequence of
   --  those anchors, grow each anchor into a run of equal lines, and recurse in
   --  between.  A region with no unique common line falls back to Myers.
   --  Lines are numbered from 1, as in git, so 0 can mean "none".
   procedure Patience_Changed
     (Lines1, Lines2     : Line_Vectors.Vector;
      Changed1, Changed2 : in out Changed_Array)
   is
      Non_Unique : constant Natural := Natural'Last;

      type Patience_Entry is record
         Line1 : Natural := 0;
         Line2 : Natural := 0;   --  0 = no match, Non_Unique = ambiguous
         Prev  : Natural := 0;   --  1-based index into Entries, 0 = none
         Next  : Natural := 0;
      end record;

      package Entry_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Patience_Entry);

      function Match (L1, L2 : Integer) return Boolean is
        (Lines1.Element (L1 - 1) = Lines2.Element (L2 - 1));

      procedure Patience_Region (First1, Count1, First2, Count2 : Integer);

      procedure Patience_Region (First1, Count1, First2, Count2 : Integer) is
         Entries     : Entry_Vectors.Vector;
         By_Content  : Class_Maps.Map;
         Has_Matches : Boolean := False;
         Head        : Natural := 0;   --  first entry of the chosen sequence
      begin
         if Count1 = 0 then
            for K in 0 .. Count2 - 1 loop
               Changed2 (First2 + K - 1) := True;
            end loop;
            return;
         elsif Count2 = 0 then
            for K in 0 .. Count1 - 1 loop
               Changed1 (First1 + K - 1) := True;
            end loop;
            return;
         end if;

         --  Index side 1, in line order, then match side 2 against it.  A line
         --  repeated on either side is marked ambiguous and cannot anchor.
         declare
            use Class_Maps;
         begin
            for L in First1 .. First1 + Count1 - 1 loop
               declare
                  Key : constant String := Lines1.Element (L - 1);
                  Pos : constant Class_Maps.Cursor := By_Content.Find (Key);
               begin
                  if Pos = No_Element then
                     Entries.Append (Patience_Entry'(Line1 => L, others => 0));
                     By_Content.Insert (Key, Entries.Last_Index);
                  else
                     declare
                        Id : constant Positive := Element (Pos);
                        E  : Patience_Entry := Entries.Element (Id);
                     begin
                        E.Line2 := Non_Unique;
                        Entries.Replace_Element (Id, E);
                     end;
                  end if;
               end;
            end loop;

            for L in First2 .. First2 + Count2 - 1 loop
               declare
                  Pos : constant Class_Maps.Cursor :=
                    By_Content.Find (Lines2.Element (L - 1));
               begin
                  if Pos /= No_Element then
                     Has_Matches := True;
                     declare
                        Id : constant Positive := Element (Pos);
                        E  : Patience_Entry := Entries.Element (Id);
                     begin
                        if E.Line2 /= 0 then
                           E.Line2 := Non_Unique;
                        else
                           E.Line2 := L;
                        end if;
                        Entries.Replace_Element (Id, E);
                     end;
                  end if;
               end;
            end loop;
         end;

         if not Has_Matches then
            for K in 0 .. Count1 - 1 loop
               Changed1 (First1 + K - 1) := True;
            end loop;
            for K in 0 .. Count2 - 1 loop
               Changed2 (First2 + K - 1) := True;
            end loop;
            return;
         end if;

         --  Longest increasing subsequence over the anchors' side-2 lines.
         declare
            Sequence : array (0 .. Natural (Entries.Length)) of Natural :=
              [others => 0];
            Longest  : Natural := 0;

            function Line2_Of (Id : Natural) return Natural is
              (Entries.Element (Id).Line2);

            --  The longest sequence whose last element is smaller than E.
            function Binary_Search (E : Positive) return Integer is
               Left   : Integer := -1;
               Right  : Integer := Longest;
               Middle : Integer;
            begin
               while Left + 1 < Right loop
                  Middle := Left + (Right - Left) / 2;
                  if Line2_Of (Sequence (Middle)) > Line2_Of (E) then
                     Right := Middle;
                  else
                     Left := Middle;
                  end if;
               end loop;
               return Left;
            end Binary_Search;
         begin
            for Id in Entries.First_Index .. Entries.Last_Index loop
               declare
                  E : Patience_Entry := Entries.Element (Id);
                  I : Integer;
               begin
                  if E.Line2 /= 0 and then E.Line2 /= Non_Unique then
                     if Longest = 0
                       or else E.Line2 > Line2_Of (Sequence (Longest - 1))
                     then
                        I := Longest - 1;
                     else
                        I := Binary_Search (Id);
                     end if;

                     E.Prev := (if I < 0 then 0 else Sequence (I));
                     Entries.Replace_Element (Id, E);

                     I := I + 1;
                     Sequence (I) := Id;
                     if I = Longest then
                        Longest := Longest + 1;
                     end if;
                  end if;
               end;
            end loop;

            if Longest = 0 then
               Head := 0;
            else
               --  Thread the chain forward from the last element back.
               declare
                  Id : Natural := Sequence (Longest - 1);
                  E  : Patience_Entry := Entries.Element (Id);
               begin
                  E.Next := 0;
                  Entries.Replace_Element (Id, E);
                  while Entries.Element (Id).Prev /= 0 loop
                     declare
                        P  : constant Natural := Entries.Element (Id).Prev;
                        PE : Patience_Entry := Entries.Element (P);
                     begin
                        PE.Next := Id;
                        Entries.Replace_Element (P, PE);
                        Id := P;
                     end;
                  end loop;
                  Head := Id;
               end;
            end if;
         end;

         if Head = 0 then
            --  Nothing unique to anchor on: let Myers handle this region.
            Myers_Region
              (Lines1   => Lines1,
               Lines2   => Lines2,
               First1   => First1 - 1,
               Count1   => Count1,
               First2   => First2 - 1,
               Count2   => Count2,
               Changed1 => Changed1,
               Changed2 => Changed2);
            return;
         end if;

         --  Walk the anchors, growing each into a run of equal lines and
         --  recursing on the gaps between them.
         declare
            L1   : Integer := First1;
            L2   : Integer := First2;
            End1 : constant Integer := First1 + Count1;
            End2 : constant Integer := First2 + Count2;
            Cur  : Natural := Head;
            Next1, Next2 : Integer;
         begin
            loop
               if Cur /= 0 then
                  Next1 := Entries.Element (Cur).Line1;
                  Next2 := Entries.Element (Cur).Line2;
                  while Next1 > L1 and then Next2 > L2
                    and then Match (Next1 - 1, Next2 - 1)
                  loop
                     Next1 := Next1 - 1;
                     Next2 := Next2 - 1;
                  end loop;
               else
                  Next1 := End1;
                  Next2 := End2;
               end if;

               while L1 < Next1 and then L2 < Next2
                 and then Match (L1, L2)
               loop
                  L1 := L1 + 1;
                  L2 := L2 + 1;
               end loop;

               if Next1 > L1 or else Next2 > L2 then
                  Patience_Region (L1, Next1 - L1, L2, Next2 - L2);
               end if;

               exit when Cur = 0;

               --  Absorb the anchors that simply continue this run.
               while Entries.Element (Cur).Next /= 0
                 and then Entries.Element (Entries.Element (Cur).Next).Line1
                          = Entries.Element (Cur).Line1 + 1
                 and then Entries.Element (Entries.Element (Cur).Next).Line2
                          = Entries.Element (Cur).Line2 + 1
               loop
                  Cur := Entries.Element (Cur).Next;
               end loop;

               L1 := Entries.Element (Cur).Line1 + 1;
               L2 := Entries.Element (Cur).Line2 + 1;
               Cur := Entries.Element (Cur).Next;
            end loop;
         end;
      end Patience_Region;
   begin
      Patience_Region
        (1, Natural (Lines1.Length), 1, Natural (Lines2.Length));
   end Patience_Changed;

   function Diff_Edits
     (Base_Lines       : Line_Vectors.Vector;
      Variant_Lines    : Line_Vectors.Vector;
      Algorithm        : Diff_Algorithm;
      Indent_Heuristic : Boolean := False) return Edit_Span_Vectors.Vector
   is
      Base_Length    : constant Natural := Natural (Base_Lines.Length);
      Variant_Length : constant Natural := Natural (Variant_Lines.Length);

      Base_Changed    : Changed_Array (0 .. Base_Length - 1) :=
        [others => False];
      Variant_Changed : Changed_Array (0 .. Variant_Length - 1) :=
        [others => False];

      Result : Edit_Span_Vectors.Vector;
      I : Natural := 0;
      J : Natural := 0;
   begin
      if Base_Length = 0 and then Variant_Length = 0 then
         return Result;
      end if;

      case Algorithm is
         when Diff_Algorithm_Histogram =>
            --  What `git merge` actually uses.
            Histogram_Changed
              (Lines1   => Base_Lines,
               Lines2   => Variant_Lines,
               Changed1 => Base_Changed,
               Changed2 => Variant_Changed);

         when Diff_Algorithm_Patience =>
            Patience_Changed
              (Lines1   => Base_Lines,
               Lines2   => Variant_Lines,
               Changed1 => Base_Changed,
               Changed2 => Variant_Changed);

         when others =>
            --  Default/Myers/Minimal: git's own diff.
            Myers_Changed
              (Lines1   => Base_Lines,
               Lines2   => Variant_Lines,
               Need_Min => Algorithm = Diff_Algorithm_Minimal,
               Changed1 => Base_Changed,
               Changed2 => Variant_Changed);
      end case;

      --  Normalise the script the way git does before anything consumes it.
      Change_Compact
        (Flags            => Base_Changed,
         Lines            => Base_Lines,
         Other_Flags      => Variant_Changed,
         Other_Lines      => Variant_Lines,
         Histogram        => Algorithm = Diff_Algorithm_Histogram,
         Indent_Heuristic => Indent_Heuristic);
      Change_Compact
        (Flags            => Variant_Changed,
         Lines            => Variant_Lines,
         Other_Flags      => Base_Changed,
         Other_Lines      => Base_Lines,
         Histogram        => Algorithm = Diff_Algorithm_Histogram,
         Indent_Heuristic => Indent_Heuristic);

      --  Build the spans: unchanged lines pair up one-to-one and in order, so
      --  a run of changed lines on either side opens a span.
      while I < Base_Length or else J < Variant_Length loop
         if Is_Changed (Base_Changed, I)
           or else Is_Changed (Variant_Changed, J)
         then
            declare
               Base_Start    : constant Natural := I;
               Variant_Start : constant Natural := J;
            begin
               while Is_Changed (Base_Changed, I) loop
                  I := I + 1;
               end loop;
               while Is_Changed (Variant_Changed, J) loop
                  J := J + 1;
               end loop;
               Result.Append
                 (Edit_Span'
                    (Base_First    => Base_Start,
                     Base_After    => I,
                     Variant_First => Variant_Start,
                     Variant_After => J));
            end;
         else
            I := I + 1;
            J := J + 1;
         end if;
      end loop;

      return Result;
   end Diff_Edits;

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

   --  Whole-text equivalence under the merge's whitespace mode: fold each line
   --  the same way the diff does (Normalize_Line, i.e. git's xdl_recmatch), so
   --  a side whose only change is whitespace the mode ignores counts as
   --  unchanged -- which is what lets git resolve such a merge to the other
   --  side outright.  Renormalize additionally folds CRLF/CR to LF first.
   function Normalize_Text
     (Text : String; Behavior : Merge_Behavior) return String
   is
      Source : Unbounded_String;
      Result : Unbounded_String;
   begin
      if Behavior.Renormalize then
         declare
            I : Natural := Text'First;
         begin
            while I <= Text'Last loop
               if Text (I) = ASCII.CR then
                  if I < Text'Last and then Text (I + 1) = ASCII.LF then
                     null;   --  the LF that follows carries the line end
                  else
                     Append (Source, ASCII.LF);
                  end if;
               else
                  Append (Source, Text (I));
               end if;
               I := I + 1;
            end loop;
         end;
      else
         Source := To_Unbounded_String (Text);
      end if;

      if Behavior.Whitespace = Whitespace_Strict then
         return To_String (Source);
      end if;

      for Line of Split_Lines (To_String (Source)) loop
         Append (Result, Normalize_Line (Line, Behavior.Whitespace));
         --  Folding can strip a line's terminator (trailing whitespace
         --  includes the newline); keep lines apart so they cannot run
         --  together.
         Append (Result, ASCII.LF);
      end loop;

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
            Stage => 0, Skip_Worktree => False));
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
                     Stage => Stage, Skip_Worktree => False));
               return;
            end if;
         end loop;
      end if;

      Result.Append
        (Version.Staging.Index_Entry'
           (Path  => Item.Path,
            Id    => Item.Id,
            Mode  => Item.Mode,
            Stage => Stage, Skip_Worktree => False));
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

   --  Reduce a conflicted file to git's rerere preimage and conflict id.  Each
   --  conflict block is normalised: markers become bare (`<<<<<<<`, no label),
   --  a diff3 `|||||||` base is dropped, and the two sides are sorted so the
   --  same textual conflict hashes identically regardless of merge direction.
   --  The id = SHA-1 over, per conflict, `min_side & NUL & max_side & NUL`
   --  (each side keeps its trailing newline) -- byte-identical to git.
   procedure Rerere_Normalize
     (Content  : String;
      Preimage : out Unbounded_String;
      Conflict_Id : out Unbounded_String;
      Had_Conflict : out Boolean)
   is
      Marker_Size : constant := 7;
      Lines : constant Line_Vectors.Vector := Split_Lines (Content);

      function Is_Marker (Line : String; Ch : Character) return Boolean is
      begin
         if Line'Length < Marker_Size then
            return False;
         end if;
         for K in 0 .. Marker_Size - 1 loop
            if Line (Line'First + K) /= Ch then
               return False;
            end if;
         end loop;
         return Line'Length = Marker_Size
           or else Line (Line'First + Marker_Size) = ' '
           or else Line (Line'First + Marker_Size) = ASCII.LF
           or else Line (Line'First + Marker_Size) = ASCII.CR;
      end Is_Marker;

      type Parse_State is (Outside, In_Side1, In_Base, In_Side2);
      St : Parse_State := Outside;
      Side1, Side2 : Unbounded_String;
      Pre    : Unbounded_String;
      Hash_In : Unbounded_String;
      Bar_Marker   : constant String := [1 .. Marker_Size => '<'] & ASCII.LF;
      Eq_Marker    : constant String := [1 .. Marker_Size => '='] & ASCII.LF;
      Gt_Marker    : constant String := [1 .. Marker_Size => '>'] & ASCII.LF;
   begin
      Had_Conflict := False;
      for L of Lines loop
         if Is_Marker (L, '<') then
            St := In_Side1;
            Side1 := Null_Unbounded_String;
            Side2 := Null_Unbounded_String;
         elsif Is_Marker (L, '|') and then St = In_Side1 then
            St := In_Base;
         elsif Is_Marker (L, '=')
           and then (St = In_Side1 or else St = In_Base)
         then
            St := In_Side2;
         elsif Is_Marker (L, '>') and then St = In_Side2 then
            declare
               A : Unbounded_String := Side1;
               B : Unbounded_String := Side2;
            begin
               if A > B then
                  A := Side2;
                  B := Side1;
               end if;
               Append (Pre, Bar_Marker);
               Append (Pre, A);
               Append (Pre, Eq_Marker);
               Append (Pre, B);
               Append (Pre, Gt_Marker);
               Append (Hash_In, A);
               Append (Hash_In, ASCII.NUL);
               Append (Hash_In, B);
               Append (Hash_In, ASCII.NUL);
            end;
            Had_Conflict := True;
            St := Outside;
         else
            case St is
               when Outside  => Append (Pre, L);
               when In_Side1 => Append (Side1, L);
               when In_Base  => null;   --  drop diff3 base image
               when In_Side2 => Append (Side2, L);
            end case;
         end if;
      end loop;
      Preimage := Pre;
      Conflict_Id :=
        To_Unbounded_String (Version.Hash.Sha1_Hex (To_String (Hash_In)));
   end Rerere_Normalize;

   --  git's per-file conflict id for a conflicted file's content.
   function Rerere_Conflict_Id (Conflicted_Content : String) return String is
      Preimage    : Unbounded_String;
      Conflict_Id : Unbounded_String;
      Had         : Boolean;
   begin
      Rerere_Normalize (Conflicted_Content, Preimage, Conflict_Id, Had);
      return (if Had then To_String (Conflict_Id) else "");
   end Rerere_Conflict_Id;

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
         Content => Existing & Key & Character'Val (9) & Path & ASCII.NUL);
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
      pragma Unreferenced (Base_Id, Current, Target);
      Preimage_Text : Unbounded_String;
      Conflict_Id   : Unbounded_String;
      Had           : Boolean;
   begin
      if not Behavior.Update_Worktree or else not Rerere_Enabled (Repo, Behavior)
      then
         return;
      end if;

      Rerere_Normalize (Content, Preimage_Text, Conflict_Id, Had);
      if not Had then
         return;
      end if;

      declare
         Key : constant String := To_String (Conflict_Id);
         Dir : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo), "rr-cache"),
              Key);
         Path : constant String := Rerere_Preimage_Path (Repo, Key);
      begin
         Ada.Directories.Create_Path (Dir);
         if not Ada.Directories.Exists (Path) then
            Version.Files.Write_Binary_File_Atomic
              (Path => Path, Content => To_String (Preimage_Text));
         end if;
         Record_Merge_RR_Entry (Repo, Key, Rel_Path);
      end;
   end Record_Rerere_Preimage;

   function Has_Conflict_Markers (Content : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Content, "<<<<<<<") /= 0
        or else Ada.Strings.Fixed.Index (Content, "=======") /= 0
        or else Ada.Strings.Fixed.Index (Content, ">>>>>>>") /= 0;
   end Has_Conflict_Markers;

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
      pragma Unreferenced (Base_Id, Current_Id, Target_Id);
      Key : constant String := Rerere_Conflict_Id (Preimage_Content);
      Exact_Path : constant String :=
        (if Key = "" then "" else Rerere_Postimage_Path (Repo, Key));
      Path : Unbounded_String;
   begin
      if not Behavior.Update_Worktree
        or else not Rerere_Enabled (Repo, Behavior)
        or else Key = ""
      then
         return False;
      elsif Ada.Directories.Exists (Exact_Path)
        and then Ada.Directories.Kind (Exact_Path) = Ada.Directories.Ordinary_File
      then
         Path := To_Unbounded_String (Exact_Path);
      else
         return False;
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
      Args : GNAT.OS_Lib.Argument_List (1 .. 6) := [others => null];
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
      --  git only checks a submodule out when submodule.recurse is on; by
      --  default a merge moves the gitlink and leaves the working tree alone.
      if not Behavior.Update_Worktree
        or else not Behavior.Recurse_Submodules
        or else not Is_Gitlink (Item)
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
      Args (4) := new String'("-q");
      Args (5) := new String'("--detach");
      Args (6) := new String'(To_String (Item.Id));
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
            --  git says so even when it leaves the working tree untouched.
            if Behavior.Update_Worktree then
               Version.Console.Put
                 ("Note: Fast-forwarding submodule " & Path_Text
                  & " to " & To_String (Target_Item.Id) & Character'Val (10));
            end if;
            Add_Merged_Path (Result, Target_Result);
            Maybe_Update_Submodule_Worktree
              (Repo => Repo, Path_Text => Path_Text, Item => Target_Result,
               Behavior => Behavior);
            return True;
         elsif Current_Is_Descendant then
            --  Our side is already the newer commit; git still reports the
            --  submodule as fast-forwarded, naming the winning commit.
            if Behavior.Update_Worktree then
               Version.Console.Put
                 ("Note: Fast-forwarding submodule " & Path_Text
                  & " to " & To_String (Current_Item.Id) & Character'Val (10));
            end if;
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
      Result       : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicted   : out Boolean)
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
      Conflicted := False;
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
              Base_Name    => To_String (Behavior.Base_Label),
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
      end if;

      --  git: a non-zero exit means "conflicts remain", not "I did nothing" --
      --  whatever the driver left in %A is still the merge result.
      Conflicted := Status /= 0;

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
         if not Conflicted then
            Add_Merged_Path (Result, Merged_Item);
         end if;
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

   function Abbreviate
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return String
   is
      Full : constant String := To_String (Id);
      Len  : constant Natural :=
        Version.Revisions.Unique_Abbrev_Length (Repo, Id, 7);
   begin
      return Full (Full'First .. Full'First + Len - 1);
   end Abbreviate;

   function Base_Label_For
     (Repo    : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Hex_Object_Id) return String is
   begin
      if To_String (Base_Id) = "0000000000000000000000000000000000000000" then
         return "merged common ancestors";
      end if;

      return Abbreviate (Repo, Base_Id);
   exception
      when others =>
         return "merged common ancestors";
   end Base_Label_For;

   function Commit_Label_For
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String is
   begin
      return Abbreviate (Repo, Commit_Id)
        & " ("
        & Version.Objects.Commit_Message_First_Line
            (Version.Objects.Read_Object (Repo, Commit_Id))
        & ")";
   exception
      when others =>
         return To_String (Commit_Id);
   end Commit_Label_For;

   --  The one text-merge entry point (git's ll_merge): a hunk-level 3-way
   --  merge.  Merged comes back with the conflict markers already in place
   --  when Conflicts > 0, so the worktree file, the rerere preimage and the
   --  virtual-conflict blob are all built from exactly the same bytes.  An
   --  empty Base_Text is the add/add case, which git merges the same way.
   --  git's `merge.renormalize`: re-run the text clean filter on all three
   --  blobs before merging, so a side that merely re-committed the file with
   --  different line endings is not seen as having changed it.  CRLF becomes
   --  LF (a lone CR is content, and stays).
   function Renormalized (Text : String) return String is
      Result : Unbounded_String;
      I      : Natural := Text'First;
   begin
      while I <= Text'Last loop
         if Text (I) = ASCII.CR and then I < Text'Last
           and then Text (I + 1) = ASCII.LF
         then
            null;   --  drop the CR; the LF that follows ends the line
         else
            Append (Result, Text (I));
         end if;
         I := I + 1;
      end loop;
      return To_String (Result);
   end Renormalized;

   procedure Text_Merge
     (Current_Name : String;
      Current_Text : String;
      Base_Text    : String;
      Target_Name  : String;
      Target_Text  : String;
      Favor        : Merge_File_Favor;
      Behavior     : Merge_Behavior;
      Merged       : out Unbounded_String;
      Conflicts    : out Natural)
   is
      Ours   : constant String :=
        (if Behavior.Renormalize then Renormalized (Current_Text)
         else Current_Text);
      Basis  : constant String :=
        (if Behavior.Renormalize then Renormalized (Base_Text) else Base_Text);
      Theirs : constant String :=
        (if Behavior.Renormalize then Renormalized (Target_Text)
         else Target_Text);

      Options : constant Merge_File_Options :=
        (Ours_Label   => To_Unbounded_String (Current_Name),
         Base_Label   => Behavior.Base_Label,
         Theirs_Label => To_Unbounded_String (Target_Name),
         Style        => Behavior.Style,
         Favor        => Favor,
         Marker_Size  => Behavior.Marker_Size,
         --  git's merge machinery (merge-ort) runs the diff with
         --  HISTOGRAM_DIFF; only `git merge-file` defaults to Myers.
         Algorithm    =>
           (if Behavior.Algorithm = Diff_Algorithm_Default
            then Diff_Algorithm_Histogram
            else Behavior.Algorithm),
         Whitespace   => Behavior.Whitespace,
         --  `git merge` runs xdl_merge at XDL_MERGE_ZEALOUS.
         Simplify_No_Alnum => False);
   begin
      Conflicts := 0;

      --  Whitespace-equivalence short-cuts.  Merge_File compares lines
      --  verbatim, so the ignore-whitespace modes are honoured here.
      if Equivalent_Text (Basis, Ours, Behavior) then
         Merged := To_Unbounded_String (Theirs);
         return;
      elsif Equivalent_Text (Basis, Theirs, Behavior)
        or else Equivalent_Text (Ours, Theirs, Behavior)
      then
         Merged := To_Unbounded_String (Ours);
         return;
      end if;

      Merge_File
        (Ours_Text   => Ours,
         Base_Text   => Basis,
         Theirs_Text => Theirs,
         Options     => Options,
         Merged      => Merged,
         Conflicts   => Conflicts);
   end Text_Merge;

   --  Write out a conflicted path.  Conflict_Content is the already-merged
   --  text (markers in place) produced by Text_Merge; a binary conflict has no
   --  text form, so the working tree just keeps our side.
   procedure Write_Conflict_File
     (Repo             : Version.Repository.Repository_Handle;
      Relative_Path    : String;
      Base_Item        : Version.Objects.Tree_Entry;
      Has_Base         : Boolean;
      Current_Item     : Version.Objects.Tree_Entry;
      Target_Item      : Version.Objects.Tree_Entry;
      Conflict_Content : String;
      Is_Text          : Boolean;
      Behavior         : Merge_Behavior;
      Kind             : out Conflict_Kind)
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Require_Safe_Path (Relative_Path);
      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Relative_Path);

      if not Is_Text then
         Kind := Binary_Conflict;
         Maybe_Write_Worktree_Item (Repo, Current_Item, Behavior);
         return;
      end if;

      Kind := Content_Conflict;

      declare
         Base_Id : constant String :=
           (if Has_Base
            then To_String (Base_Item.Id)
            else "0000000000000000000000000000000000000000");
      begin
         if Behavior.Update_Worktree then
            Version.Files.Write_Binary_File_Atomic
              (Path => Absolute_Path, Content => Conflict_Content);
            Apply_Worktree_File_Mode
              (Absolute_Path, To_String (Current_Item.Mode));
         end if;
         Record_Rerere_Preimage
           (Repo     => Repo,
            Rel_Path => Relative_Path,
            Base_Id  => Base_Id,
            Current  => Current_Item.Id,
            Target   => Target_Item.Id,
            Content  => Conflict_Content,
            Behavior => Behavior);
      end;
   end Write_Conflict_File;

   procedure Handle_Two_Sided_Conflict
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Path_Text     : String;
      --  The path each side carried the content under, when a rename means
      --  that is not Path_Text.  Empty means "same as Path_Text".
      Ours_Origin   : String := "";
      Theirs_Origin : String := "";
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

      --  A path git can merge line by line: two real, non-binary blobs.  An
      --  add/add (no base) still qualifies -- git merges it against an empty
      --  base, so the common lines stay outside the markers.
      --  When the two sides carry the path under different names (a rename on
      --  one or both sides), git disambiguates the markers by appending each
      --  side's own path: `HEAD:old.txt` / `feature:new.txt`.  Sides that
      --  renamed to the same path keep the plain labels.
      Ours_Path   : constant String :=
        (if Ours_Origin = "" then Path_Text else Ours_Origin);
      Theirs_Path : constant String :=
        (if Theirs_Origin = "" then Path_Text else Theirs_Origin);
      Renamed     : constant Boolean := Ours_Path /= Theirs_Path;
      Ours_Label : constant String :=
        Current_Name & (if Renamed then ":" & Ours_Path else "");
      Theirs_Label : constant String :=
        Target_Name & (if Renamed then ":" & Theirs_Path else "");

      Is_Text : constant Boolean :=
        Current_Is_Blob
        and then Target_Is_Blob
        and then not Is_Gitlink (Current_Item)
        and then not Is_Gitlink (Target_Item)
        and then Attr /= Attribute_Binary
        and then not Is_Binary_Content (Current_Text)
        and then not Is_Binary_Content (Target_Text);

      --  -Xours/-Xtheirs and the `union` attribute resolve individual conflict
      --  hunks, they do not discard the other side's clean hunks.
      Text_Favor : constant Merge_File_Favor :=
        (if Attr = Attribute_Union then Favor_Union
         elsif Behavior.Favor = Favor_Current then Favor_File_Ours
         elsif Behavior.Favor = Favor_Target then Favor_File_Theirs
         else Favor_None);

      Merged_Text    : Unbounded_String;
      Text_Conflicts : Natural := 0;
      Actual_Kind    : Conflict_Kind;

      procedure Take_Whole_Side (Item : Version.Objects.Tree_Entry) is
         Side : constant Version.Objects.Tree_Entry := With_Path (Item, Path_Text);
      begin
         Add_Merged_Path (Merged_Index, Side);
         Maybe_Write_Worktree_Item (Repo, Side, Behavior);
      end Take_Whole_Side;
   begin
      --  The `merge=ours` attribute driver keeps our file whole -- that is what
      --  git's built-in "ours" driver does, unlike -Xours.
      if Attr = Attribute_Ours then
         Take_Whole_Side (Current_Item);
         return;
      elsif Attr = Attribute_Theirs then
         Take_Whole_Side (Target_Item);
         return;
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
         --  git's shortcut for "both sides did the same thing" compares object
         --  ids, i.e. exact bytes -- it must not fold whitespace, or a side
         --  whose only change is ignorable whitespace would win here instead
         --  of losing to the other side inside the merge itself.
         if Equivalent_Text
              (Current_Text, Target_Text,
               Merge_Behavior'(Behavior with delta Whitespace =>
                                 Whitespace_Strict))
         then
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
         else
            declare
               Driver_Conflicted : Boolean := False;
               Driver_Handled    : constant Boolean :=
                 Try_External_Merge_Driver
                   (Repo         => Repo,
                    Path_Text    => Path_Text,
                    Driver_Name  => Effective_External_Driver_Name
                      (Repo        => Repo,
                       Driver_Name => Driver_Name,
                       Behavior    => Behavior),
                    Base_Text    =>
                      (if Has_Base and then Base_Is_Blob then Base_Text else ""),
                    Current_Text => Current_Text,
                    Target_Text  => Target_Text,
                    Current_Name => Current_Name,
                    Target_Name  => Target_Name,
                    Current_Item => Result_Item,
                    Behavior     => Behavior,
                    Result       => Merged_Index,
                    Conflicted   => Driver_Conflicted);
            begin
               if Driver_Handled then
                  --  The driver's own output stands, markers and all; a
                  --  non-zero exit just means conflicts remain in it.
                  if Driver_Conflicted then
                     Add_Conflict (Conflicts, Path_Text, Default_Kind);
                  end if;
                  return;
               end if;
            end;
         end if;
      end if;

      if Is_Text then
         Text_Merge
           (Current_Name => Ours_Label,
            Current_Text => Current_Text,
            Base_Text    =>
              (if Has_Base and then Base_Is_Blob and then
                 not Is_Binary_Content (Base_Text)
               then Base_Text
               else ""),
            Target_Name  => Theirs_Label,
            Target_Text  => Target_Text,
            Favor        => Text_Favor,
            Behavior     => Behavior,
            Merged       => Merged_Text,
            Conflicts    => Text_Conflicts);

         if Text_Conflicts = 0 then
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

      --  Nothing to merge line by line, so -Xours/-Xtheirs falls back to
      --  taking a whole side, as git does for a binary conflict.
      elsif Behavior.Favor = Favor_Current then
         Take_Whole_Side (Current_Item);
         return;
      elsif Behavior.Favor = Favor_Target then
         Take_Whole_Side (Target_Item);
         return;
      end if;

      if Try_Rerere_Resolution
           (Repo             => Repo,
            Path_Text        => Path_Text,
            Base_Id          => Base_Id,
            Preimage_Content => (if Is_Text then To_String (Merged_Text) else ""),
            Result_Item      => Result_Item,
            Current_Id       => Current_Item.Id,
            Target_Id        => Target_Item.Id,
            Result           => Merged_Index,
            Behavior         => Behavior)
      then
         return;
      end if;

      Write_Conflict_File
        (Repo             => Repo,
         Relative_Path    => Path_Text,
         Base_Item        => Base_Item,
         Has_Base         => Has_Base,
         Current_Item     => Result_Item,
         Target_Item      => With_Path (Target_Item, Path_Text),
         Conflict_Content => To_String (Merged_Text),
         Is_Text          => Is_Text,
         Behavior         => Behavior,
         Kind             => Actual_Kind);

      if Actual_Kind = Binary_Conflict then
         if Behavior.Materialize_Virtual_Conflicts then
            Add_Merged_Path (Merged_Index, Result_Item);
         end if;
         Add_Conflict (Conflicts, Path_Text, Binary_Conflict);
      else
         if Behavior.Materialize_Virtual_Conflicts then
            declare
               Content : constant String := To_String (Merged_Text);
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
                           --  Stage 1/2/3 at the rename's destination, as git
                           --  does; a clean merge clears them again.
                           Add_Staged_Conflict_Path
                             (Merged_Index, With_Path (Base_Item, New_Path), 1);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Current_Moved, 2);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Target_New, 3);
                           Handle_Two_Sided_Conflict
                             (Repo          => Repo,
                              Current_Name  => Current_Name,
                              Target_Name   => Target_Name,
                              Path_Text     => New_Path,
                              Ours_Origin   => Old_Path,
                              Theirs_Origin => New_Path,
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
                           --  Stage 1/2/3 at the rename's destination, as git
                           --  does; a clean merge clears them again.
                           Add_Staged_Conflict_Path
                             (Merged_Index, With_Path (Base_Item, New_Path), 1);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Current_New, 2);
                           Add_Staged_Conflict_Path
                             (Merged_Index, Target_Moved, 3);
                           Handle_Two_Sided_Conflict
                             (Repo          => Repo,
                              Current_Name  => Current_Name,
                              Target_Name   => Target_Name,
                              Path_Text     => New_Path,
                              Ours_Origin   => New_Path,
                              Theirs_Origin => Old_Path,
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

   --  git resolves a file/directory collision by keeping the directory at the
   --  path and renaming the losing file to "<path>~<label>" (the label is the
   --  side that carried the file: Current_Name for a stage-2 file, else
   --  Target_Name), reported as one file/directory conflict at the new path,
   --  with the directory's files left clean at stage 0. The tree walk instead
   --  leaves the file at the original path (stage 2/3) and marks the directory
   --  files conflicted; this pass rewrites that shape to match git.
   procedure Resolve_Dir_File_Collisions
     (Repo         : Version.Repository.Repository_Handle;
      Target_Name  : String;
      Merged_Index : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts    : in out Conflict_Vectors.Vector;
      Behavior     : Merge_Behavior)
   is
      Colliding       : Path_Sets.Set;
      File_On_Current : Boolean;

      function Is_Dir_Prefix (P : String) return Boolean is
      begin
         for E of Merged_Index loop
            declare
               EP : constant String := To_String (E.Path);
            begin
               if EP'Length > P'Length + 1
                 and then EP (EP'First .. EP'First + P'Length) = P & "/"
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Is_Dir_Prefix;
   begin
      for E of Merged_Index loop
         if E.Stage in 2 | 3 then
            declare
               P : constant String := To_String (E.Path);
            begin
               if not Colliding.Contains (P) and then Is_Dir_Prefix (P) then
                  Colliding.Include (P);
               end if;
            end;
         end if;
      end loop;

      for P of Colliding loop
         File_On_Current := False;
         --  Rename the losing file entry to "<P>~<label>" and materialize it.
         for I in Merged_Index.First_Index .. Merged_Index.Last_Index loop
            if To_String (Merged_Index.Element (I).Path) = P
              and then Merged_Index.Element (I).Stage in 2 | 3
            then
               declare
                  E        : Version.Staging.Index_Entry :=
                    Merged_Index.Element (I);
                  --  git labels the current side "HEAD" (not the branch name)
                  --  and the incoming side by its merge name.
                  Label    : constant String :=
                    (if E.Stage = 2 then "HEAD" else Target_Name);
                  New_Path : constant String := P & "~" & Label;
               begin
                  File_On_Current := E.Stage = 2;
                  E.Path := To_Unbounded_String (New_Path);
                  Merged_Index.Replace_Element (I, E);
                  if Behavior.Update_Worktree then
                     Write_Worktree_Item
                       (Repo,
                        Version.Objects.Tree_Entry'
                          (Path => E.Path,
                           Id   => E.Id,
                           Kind => Version.Objects.Tree_Blob,
                           Mode => E.Mode));
                  end if;
                  Add_Conflict (Conflicts, New_Path, Directory_File_Conflict);
               end;
               exit;
            end if;
         end loop;

         --  When the file was on the current side the working tree still holds
         --  it at P, blocking the incoming directory; remove it so the
         --  directory's files can be written there.
         if File_On_Current then
            Maybe_Delete_Working_File (Repo, P, Behavior);
         end if;

         --  The directory's files become clean (stage 0), and are written to
         --  the working tree when the directory is the incoming side.
         for I in Merged_Index.First_Index .. Merged_Index.Last_Index loop
            declare
               EP : constant String := To_String (Merged_Index.Element (I).Path);
            begin
               if EP'Length > P'Length + 1
                 and then EP (EP'First .. EP'First + P'Length) = P & "/"
               then
                  if Merged_Index.Element (I).Stage /= 0 then
                     declare
                        E : Version.Staging.Index_Entry :=
                          Merged_Index.Element (I);
                     begin
                        E.Stage := 0;
                        Merged_Index.Replace_Element (I, E);
                     end;
                  end if;
                  if File_On_Current and then Behavior.Update_Worktree then
                     declare
                        E : constant Version.Staging.Index_Entry :=
                          Merged_Index.Element (I);
                     begin
                        Write_Worktree_Item
                          (Repo,
                           Version.Objects.Tree_Entry'
                             (Path => E.Path,
                              Id   => E.Id,
                              Kind => Version.Objects.Tree_Blob,
                              Mode => E.Mode));
                     end;
                  end if;
               end if;
            end;
         end loop;

         --  Drop the original file/directory conflicts at P and under P/.
         declare
            Kept : Conflict_Vectors.Vector;
         begin
            for C of Conflicts loop
               declare
                  CP : constant String := To_String (C.Path);
               begin
                  if CP = P
                    or else (CP'Length > P'Length + 1
                             and then CP (CP'First .. CP'First + P'Length)
                                      = P & "/")
                  then
                     null;
                  else
                     Kept.Append (C);
                  end if;
               end;
            end loop;
            Conflicts := Kept;
         end;
      end loop;
   end Resolve_Dir_File_Collisions;

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

      Resolve_Dir_File_Collisions
        (Repo         => Repo,
         Target_Name  => Target_Name,
         Merged_Index => Merged_Index,
         Conflicts    => Conflicts,
         Behavior     => Behavior);
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
      --  (git records "<key>\t<path>\0" entries); returns "" if absent.
      function Key_For_Path (Map_Text : String; Want : String) return String is
         Start : Natural := Map_Text'First;
         Found : Unbounded_String := Null_Unbounded_String;
      begin
         while Start <= Map_Text'Last loop
            declare
               EOL : Natural := Start;
            begin
               while EOL <= Map_Text'Last
                 and then Map_Text (EOL) /= ASCII.NUL
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

   ----------------------------------------------------------------------------
   --  git merge-file: a faithful port of xdiff/xmerge's xdl_do_merge.

   function Text_Changes
     (Old_Text         : String;
      New_Text         : String;
      Algorithm        : Diff_Algorithm := Diff_Algorithm_Myers;
      Indent_Heuristic : Boolean := False) return Text_Change_Vectors.Vector
   is
      Old_Lines : constant Line_Vectors.Vector := Split_Lines (Old_Text);
      New_Lines : constant Line_Vectors.Vector := Split_Lines (New_Text);
      Edits : constant Edit_Span_Vectors.Vector :=
        Diff_Edits (Old_Lines, New_Lines, Algorithm, Indent_Heuristic);
      Result : Text_Change_Vectors.Vector;
   begin
      for Span of Edits loop
         Result.Append
           (Text_Change'
              (Old_First => Span.Base_First,
               Old_After => Span.Base_After,
               New_First => Span.Variant_First,
               New_After => Span.Variant_After));
      end loop;
      return Result;
   end Text_Changes;

   function Align_Lines
     (Current_Text : String;
      Parent_Text  : String) return Line_Match_Vectors.Vector
   is
      Cur : constant Line_Vectors.Vector := Split_Lines (Current_Text);
      Par : constant Line_Vectors.Vector := Split_Lines (Parent_Text);

      --  Diff parent -> current, so the spans are keyed by parent lines.
      Edits : constant Edit_Span_Vectors.Vector :=
        Diff_Edits (Par, Cur, Diff_Algorithm_Myers, Indent_Heuristic => True);

      Result : Line_Match_Vectors.Vector;
      P, C   : Natural := 0;   --  0-based cursors into Par and Cur
   begin
      for K in 1 .. Natural (Cur.Length) loop
         Result.Append (0);
      end loop;

      for Span of Edits loop
         --  Lines before the span are unchanged and pair up one for one.
         while P < Span.Base_First and then C < Span.Variant_First loop
            Result.Replace_Element (C + 1, P + 1);
            P := P + 1;
            C := C + 1;
         end loop;
         --  Inside the span the current lines are new (they stay 0).
         P := Span.Base_After;
         C := Span.Variant_After;
      end loop;

      while P < Natural (Par.Length) and then C < Natural (Cur.Length) loop
         Result.Replace_Element (C + 1, P + 1);
         P := P + 1;
         C := C + 1;
      end loop;

      return Result;
   end Align_Lines;

   procedure Merge_File
     (Ours_Text   : String;
      Base_Text   : String;
      Theirs_Text : String;
      Options     : Merge_File_Options;
      Merged      : out Ada.Strings.Unbounded.Unbounded_String;
      Conflicts   : out Natural)
   is
      Base_Lines   : constant Line_Vectors.Vector := Split_Lines (Base_Text);
      Ours_Lines   : constant Line_Vectors.Vector := Split_Lines (Ours_Text);
      Theirs_Lines : constant Line_Vectors.Vector := Split_Lines (Theirs_Text);

      Base_N   : constant Integer := Integer (Base_Lines.Length);
      Ours_N   : constant Integer := Integer (Ours_Lines.Length);
      Theirs_N : constant Integer := Integer (Theirs_Lines.Length);

      --  Everything that *compares* lines does so on the whitespace-folded
      --  copies (git folds whitespace into the record hash); everything that
      --  *emits* lines uses the originals above.
      Base_Cmp   : constant Line_Vectors.Vector :=
        Normalize_Lines (Base_Lines, Options.Whitespace);
      Ours_Cmp   : constant Line_Vectors.Vector :=
        Normalize_Lines (Ours_Lines, Options.Whitespace);
      Theirs_Cmp : constant Line_Vectors.Vector :=
        Normalize_Lines (Theirs_Lines, Options.Whitespace);

      EO : constant Edit_Span_Vectors.Vector :=
        Diff_Edits (Base_Cmp, Ours_Cmp, Options.Algorithm);
      ET : constant Edit_Span_Vectors.Vector :=
        Diff_Edits (Base_Cmp, Theirs_Cmp, Options.Algorithm);

      --  A merge region in the three coordinate systems.  Mode: 0 conflict,
      --  1 take ours, 2 take theirs, 3 union.
      type Region is record
         Mode : Natural;
         I0, Chg0 : Integer;   --  base
         I1, Chg1 : Integer;   --  ours
         I2, Chg2 : Integer;   --  theirs
      end record;
      package Region_Vectors is new Ada.Containers.Vectors (Natural, Region);
      Regions : Region_Vectors.Vector;

      --  Edit-span accessors in git's (i1/chg1 base, i2/chg2 variant) terms.
      function B1 (E : Edit_Span) return Integer is (E.Base_First);
      function BC (E : Edit_Span) return Integer is
        (E.Base_After - E.Base_First);
      function V1 (E : Edit_Span) return Integer is (E.Variant_First);
      function VC (E : Edit_Span) return Integer is
        (E.Variant_After - E.Variant_First);

      procedure Append_Merge
        (Mode, I0, Chg0, I1, Chg1, I2, Chg2 : Integer) is
      begin
         if not Regions.Is_Empty then
            declare
               M : Region := Regions.Last_Element;
            begin
               if I1 <= M.I1 + M.Chg1 or else I2 <= M.I2 + M.Chg2 then
                  if Mode /= M.Mode then
                     M.Mode := 0;
                  end if;
                  M.Chg0 := I0 + Chg0 - M.I0;
                  M.Chg1 := I1 + Chg1 - M.I1;
                  M.Chg2 := I2 + Chg2 - M.I2;
                  Regions.Replace_Element (Regions.Last_Index, M);
                  return;
               end if;
            end;
         end if;
         Regions.Append (Region'(Mode, I0, Chg0, I1, Chg1, I2, Chg2));
      end Append_Merge;

      function Lines_Equal
        (A : Line_Vectors.Vector; A0, Count : Integer;
         B : Line_Vectors.Vector; B0 : Integer) return Boolean is
      begin
         for K in 0 .. Count - 1 loop
            if A.Element (A0 + K) /= B.Element (B0 + K) then
               return False;
            end if;
         end loop;
         return True;
      end Lines_Equal;

      OI : Integer := EO.First_Index;
      TI : Integer := ET.First_Index;
      Have_O : Boolean := not EO.Is_Empty;
      Have_T : Boolean := not ET.Is_Empty;
   begin
      Conflicts := 0;
      Merged := Ada.Strings.Unbounded.Null_Unbounded_String;

      --  Main walk over both change scripts.
      while OI <= EO.Last_Index and then TI <= ET.Last_Index loop
         declare
            E1 : constant Edit_Span := EO.Element (OI);
            E2 : constant Edit_Span := ET.Element (TI);
         begin
            if B1 (E1) + BC (E1) < B1 (E2) then
               --  ours change ends before theirs starts.
               Append_Merge
                 (1, B1 (E1), BC (E1), V1 (E1), VC (E1),
                  V1 (E2) - B1 (E2) + B1 (E1), BC (E1));
               OI := OI + 1;
            elsif B1 (E2) + BC (E2) < B1 (E1) then
               Append_Merge
                 (2, B1 (E2), BC (E2),
                  V1 (E1) - B1 (E1) + B1 (E2), BC (E2), V1 (E2), VC (E2));
               TI := TI + 1;
            else
               --  Overlap in base.  Conflict unless both made the same edit.
               declare
                  Identical : constant Boolean :=
                    B1 (E1) = B1 (E2) and then BC (E1) = BC (E2)
                    and then VC (E1) = VC (E2)
                    and then Lines_Equal (Ours_Cmp, V1 (E1), VC (E1),
                                          Theirs_Cmp, V1 (E2));
                  Off : constant Integer := B1 (E1) - B1 (E2);
                  Ffo : constant Integer := Off + BC (E1) - BC (E2);
                  I0 : Integer := B1 (E1);
                  I1 : Integer := V1 (E1);
                  I2 : Integer := V1 (E2);
                  C0, C1, C2 : Integer;
               begin
                  if not Identical then
                     if Off > 0 then
                        I0 := I0 - Off;
                        I1 := I1 - Off;
                     else
                        I2 := I2 + Off;
                     end if;
                     C0 := B1 (E1) + BC (E1) - I0;
                     C1 := V1 (E1) + VC (E1) - I1;
                     C2 := V1 (E2) + VC (E2) - I2;
                     if Ffo < 0 then
                        C0 := C0 - Ffo;
                        C1 := C1 - Ffo;
                     else
                        C2 := C2 + Ffo;
                     end if;
                     Append_Merge (0, I0, C0, I1, C1, I2, C2);
                  end if;
                  declare
                     End1 : constant Integer := B1 (E1) + BC (E1);
                     End2 : constant Integer := B1 (E2) + BC (E2);
                  begin
                     if End1 >= End2 then
                        TI := TI + 1;
                     end if;
                     if End2 >= End1 then
                        OI := OI + 1;
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;

      --  Tails: changes remaining on one side only.
      while OI <= EO.Last_Index loop
         declare
            E1 : constant Edit_Span := EO.Element (OI);
         begin
            Append_Merge
              (1, B1 (E1), BC (E1), V1 (E1), VC (E1),
               B1 (E1) + Theirs_N - Base_N, BC (E1));
            OI := OI + 1;
         end;
      end loop;
      while TI <= ET.Last_Index loop
         declare
            E2 : constant Edit_Span := ET.Element (TI);
         begin
            Append_Merge
              (2, B1 (E2), BC (E2),
               B1 (E2) + Ours_N - Base_N, BC (E2), V1 (E2), VC (E2));
            TI := TI + 1;
         end;
      end loop;

      pragma Unreferenced (Have_O, Have_T);

      --  Refine conflicts (git's xdl_refine_conflicts): re-diff the two sides
      --  of each conflict against each other and split it at the lines that
      --  really differ, so lines common to ours and theirs stay outside the
      --  markers.  git only does this for the default style -- diff3 shows the
      --  base, so it clamps the merge level below ZEALOUS and skips refining;
      --  zdiff3 instead gets the edge-trimming pass further down.
      if Options.Style = Conflict_Style_Merge then
         declare
            Refined : Region_Vectors.Vector;
         begin
            for M of Regions loop
               if M.Mode /= 0 or else M.Chg1 = 0 or else M.Chg2 = 0 then
                  Refined.Append (M);
               else
                  declare
                     Ours_Side, Theirs_Side : Line_Vectors.Vector;
                  begin
                     for K in 0 .. M.Chg1 - 1 loop
                        Ours_Side.Append (Ours_Cmp.Element (M.I1 + K));
                     end loop;
                     for K in 0 .. M.Chg2 - 1 loop
                        Theirs_Side.Append (Theirs_Cmp.Element (M.I2 + K));
                     end loop;

                     declare
                        Script : constant Edit_Span_Vectors.Vector :=
                          Diff_Edits
                            (Ours_Side, Theirs_Side, Options.Algorithm);
                     begin
                        if Script.Is_Empty then
                           --  The sides turn out to be identical: mode 4, which
                           --  emits the lines once, as context.
                           Refined.Append
                             (Region'
                                (Mode => 4,
                                 I0   => M.I0,   Chg0 => M.Chg0,
                                 I1   => M.I1,   Chg1 => M.Chg1,
                                 I2   => M.I2,   Chg2 => M.Chg2));
                        else
                           for S of Script loop
                              Refined.Append
                                (Region'
                                   (Mode => 0,
                                    I0   => M.I0,
                                    Chg0 => M.Chg0,
                                    I1   => M.I1 + S.Base_First,
                                    Chg1 => S.Base_After - S.Base_First,
                                    I2   => M.I2 + S.Variant_First,
                                    Chg2 => S.Variant_After - S.Variant_First));
                           end loop;
                        end if;
                     end;
                  end;
               end if;
            end loop;
            Regions := Refined;
         end;
      end if;

      --  Zealous simplify (git's xdl_simplify_non_conflicts): combine two
      --  adjacent conflicts when the common lines between them take up no more
      --  space than folding them into the conflict would.  That is at most
      --  three lines -- or any number of lines that carry no letter or digit,
      --  but only at git's ZEALOUS_ALNUM level, which `git merge-file` uses and
      --  `git merge` does not.  Applies to the default style only.
      declare
         I : Natural := Regions.First_Index;

         function Lines_Contain_Alnum (From, Count : Integer) return Boolean is
         begin
            for K in From .. From + Count - 1 loop
               for C of Ours_Lines.Element (K) loop
                  if (C in 'a' .. 'z') or else (C in 'A' .. 'Z')
                    or else (C in '0' .. '9')
                  then
                     return True;
                  end if;
               end loop;
            end loop;
            return False;
         end Lines_Contain_Alnum;
      begin
         while Options.Style = Conflict_Style_Merge
           and then not Regions.Is_Empty and then I < Regions.Last_Index
         loop
            declare
               M   : Region := Regions.Element (I);
               Nxt : constant Region := Regions.Element (I + 1);
               Gap_First : constant Integer := M.I1 + M.Chg1;
               Gap       : constant Integer := Nxt.I1 - Gap_First;
            begin
               if M.Mode = 0 and then Nxt.Mode = 0
                 and then (Gap <= 3
                           or else (Options.Simplify_No_Alnum
                                    and then not Lines_Contain_Alnum
                                                  (Gap_First, Gap)))
               then
                  M.Chg0 := Nxt.I0 + Nxt.Chg0 - M.I0;
                  M.Chg1 := Nxt.I1 + Nxt.Chg1 - M.I1;
                  M.Chg2 := Nxt.I2 + Nxt.Chg2 - M.I2;
                  Regions.Replace_Element (I, M);
                  Regions.Delete (I + 1);
               else
                  I := I + 1;
               end if;
            end;
         end loop;
      end;

      --  zdiff3: push lines common to both sides at a conflict's edges out of
      --  the markers (leading lines advance i1/i2 so the cursor emits them as
      --  context; trailing lines shrink chg1/chg2).
      if Options.Style = Conflict_Style_ZDiff3 then
         for M of Regions loop
            if M.Mode = 0 then
               declare
                  N : Region := M;
               begin
                  while N.Chg1 > 0 and then N.Chg2 > 0
                    and then Ours_Cmp.Element (N.I1)
                             = Theirs_Cmp.Element (N.I2)
                  loop
                     N.I1 := N.I1 + 1;
                     N.I2 := N.I2 + 1;
                     N.Chg1 := N.Chg1 - 1;
                     N.Chg2 := N.Chg2 - 1;
                  end loop;
                  while N.Chg1 > 0 and then N.Chg2 > 0
                    and then Ours_Cmp.Element (N.I1 + N.Chg1 - 1)
                             = Theirs_Cmp.Element (N.I2 + N.Chg2 - 1)
                  loop
                     N.Chg1 := N.Chg1 - 1;
                     N.Chg2 := N.Chg2 - 1;
                  end loop;
                  M := N;
               end;
            end if;
         end loop;
      end if;

      --  Emit the merged text.
      declare
         MS  : constant Positive := Options.Marker_Size;
         Cur : Integer := 0;   --  cursor in ours coordinates

         --  git's is_eol_crlf: 1 if line I ends CR/LF, 0 if LF-only, -1 when
         --  the line ending cannot be determined (empty file, or a sole line
         --  with no EOL).  A line with no EOL defers to the one before it.
         function Eol_Crlf
           (Lines : Line_Vectors.Vector; Index : Integer) return Integer
         is
            Count : constant Natural := Natural (Lines.Length);

            function Ends_CRLF (Line : String) return Integer is
              (if Line'Length > 1 and then Line (Line'Last - 1) = ASCII.CR
               then 1 else 0);
         begin
            if Count = 0 then
               return -1;
            end if;

            --  Every line but the last is known to end in LF.
            if Index < Count - 1 then
               return Ends_CRLF (Lines.Element (Index));
            end if;

            declare
               Last : constant String := Lines.Element (Index);
            begin
               if Last'Length > 0 and then Last (Last'Last) = ASCII.LF then
                  return Ends_CRLF (Last);
               end if;
            end;

            if Index = 0 then
               return -1;
            end if;

            return Ends_CRLF (Lines.Element (Index - 1));
         end Eol_Crlf;

         --  git's is_cr_needed: the markers follow the line-ending style of
         --  the line preceding each side's postimage, and of the base's first
         --  line.  Any side that is known to be LF-only settles it as LF;
         --  "undetermined" alone is not enough to choose CRLF.
         function Needs_CR (M : Region) return Boolean is
            State : Integer :=
              Eol_Crlf (Ours_Lines, (if M.I1 > 0 then M.I1 - 1 else 0));
         begin
            if State /= 0 then
               State :=
                 Eol_Crlf (Theirs_Lines, (if M.I2 > 0 then M.I2 - 1 else 0));
            end if;
            if State /= 0 then
               State := Eol_Crlf (Base_Lines, 0);
            end if;
            return State > 0;
         end Needs_CR;

         function Line_End (CR : Boolean) return String is
           (if CR then ASCII.CR & ASCII.LF else "" & ASCII.LF);

         function Marker
           (C : Character; Label : String; CR : Boolean) return String
         is (String'(1 .. MS => C)
             & (if Label = "" then "" else " " & Label) & Line_End (CR));

         function Eq_Marker (CR : Boolean) return String is
           (String'(1 .. MS => '=') & Line_End (CR));

         --  git puts every conflict marker on its own line: if the preceding
         --  section's last line lacked a trailing newline, add one first (in
         --  the file's line-ending style).
         procedure NL_Guard (CR : Boolean) is
            L : constant Natural := Length (Merged);
         begin
            if L > 0 and then Element (Merged, L) /= ASCII.LF then
               Append (Merged, Line_End (CR));
            end if;
         end NL_Guard;
      begin
         for M of Regions loop
            declare
               Mode : Natural := M.Mode;
               CR   : constant Boolean := Needs_CR (M);
            begin
               if Options.Favor /= Favor_None and then Mode = 0 then
                  Mode :=
                    (case Options.Favor is
                        when Favor_File_Ours   => 1,
                        when Favor_File_Theirs => 2,
                        when Favor_Union       => 3,
                        when others            => 0);
               end if;

               --  Mode 4 (refinement found the sides identical) contributes
               --  nothing of its own: leaving the cursor put emits its lines
               --  from ours as ordinary context.
               if Mode = 4 then
                  goto Next_Region;
               end if;

               --  Common lines before this region (from ours).
               Append_Line_Range (Merged, Ours_Lines, Cur, M.I1);

               if Mode = 0 then
                  NL_Guard (CR);
                  Append (Merged,
                          Marker ('<', To_String (Options.Ours_Label), CR));
                  Append_Line_Range
                    (Merged, Ours_Lines, M.I1, M.I1 + M.Chg1);
                  if Options.Style = Conflict_Style_Diff3
                    or else Options.Style = Conflict_Style_ZDiff3
                  then
                     NL_Guard (CR);
                     Append (Merged,
                             Marker ('|', To_String (Options.Base_Label), CR));
                     Append_Line_Range
                       (Merged, Base_Lines, M.I0, M.I0 + M.Chg0);
                  end if;
                  NL_Guard (CR);
                  Append (Merged, Eq_Marker (CR));
                  Append_Line_Range
                    (Merged, Theirs_Lines, M.I2, M.I2 + M.Chg2);
                  NL_Guard (CR);
                  Append (Merged,
                          Marker ('>', To_String (Options.Theirs_Label), CR));
                  Conflicts := Conflicts + 1;
               else
                  if Mode = 1 or else Mode = 3 then
                     Append_Line_Range
                       (Merged, Ours_Lines, M.I1, M.I1 + M.Chg1);
                     --  Union puts theirs straight after ours, so ours must
                     --  end in a newline even if the file did not.
                     if Mode = 3 then
                        NL_Guard (CR);
                     end if;
                  end if;
                  if Mode = 2 or else Mode = 3 then
                     Append_Line_Range
                       (Merged, Theirs_Lines, M.I2, M.I2 + M.Chg2);
                  end if;
               end if;
               Cur := M.I1 + M.Chg1;
               <<Next_Region>>
            end;
         end loop;
         --  Trailing common lines.
         Append_Line_Range (Merged, Ours_Lines, Cur, Ours_N);
      end;
   end Merge_File;

end Version.Merge;
