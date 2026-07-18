with Ada.Containers;
use type Ada.Containers.Count_Type;
with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Version.Merge;
with Version.Hash;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;

with Version.Files;
with Version.Ignore;
with Version.Platform;
with Version.Staging;
with Version.Working_Tree;
with Version.Object_Cache;
with Version.Ref_Cache;
with Version.Sparse;
with Version.Rename_Detect;
with Version.Compression;
with Interfaces; use type Interfaces.Unsigned_32;
with Version.Config;
with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Version.Tree_Cache;

package body Version.Diff is

   use Ada.Strings.Unbounded;
   use Version.Objects;

   type Side_Entry is record
      Path    : Unbounded_String;
      Id      : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Mode    : Unbounded_String := Null_Unbounded_String;
      Present : Boolean := False;
   end record;

   package Side_Entry_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Side_Entry);

   package Line_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Unbounded_String);

   package Side_Entry_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Side_Entry);

   package Path_Sets is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Boolean);

   function Short_Zero return Version.Objects.Hex_Object_Id is
      Z : constant Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      return Z;
   end Short_Zero;

   function Contains_Nul (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = Character'Val (0) then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Nul;

   function Blob_Content
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Version.Object_Cache.Object_Cache;
      Id    : Version.Objects.Hex_Object_Id) return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a blob: " & To_String (Id);
      end if;

      return Version.Objects.Content (Obj);
   end Blob_Content;

   function Working_Content
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
   begin
      return
        Version.Files.Read_Binary_File
          (Version.Files.Join (Version.Repository.Root_Path (Repo), Path));
   end Working_Content;

   function Split_Lines (Text : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Start  : Natural := Text'First;
      Pos    : Natural := Text'First;
   begin
      if Text'Length = 0 then
         return Result;
      end if;

      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10) then
            if Pos = Start then
               Result.Append (To_Unbounded_String (""));
            else
               Result.Append (To_Unbounded_String (Text (Start .. Pos - 1)));
            end if;
            Start := Pos + 1;
         end if;
         Pos := Pos + 1;
      end loop;

      if Start <= Text'Last then
         Result.Append (To_Unbounded_String (Text (Start .. Text'Last)));
      end if;

      return Result;
   end Split_Lines;

   function Count_Image (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Count_Image;

   procedure Append_Line (Out_Text : in out Unbounded_String; Line : String) is
   begin
      Append (Out_Text, Line);
      Append (Out_Text, Character'Val (10));
   end Append_Line;

   function Ends_With_Newline (Text : String) return Boolean is
   begin
      return Text'Length > 0 and then Text (Text'Last) = Character'Val (10);
   end Ends_With_Newline;

   function Abbrev (Id : Version.Objects.Hex_Object_Id) return String is
      Full : constant String := To_String (Id);
   begin
      if Full'Length >= 7 then
         return Full (Full'First .. Full'First + 6);
      else
         return Full;
      end if;
   end Abbrev;

   --  git's default hunk section heading (shown after the second "@@"): the
   --  nearest line before the hunk whose first character is a letter, '_' or
   --  '$' -- xdiff's built-in funcname heuristic when no diff driver applies.
   --  Trailing blanks are trimmed.
   function Section_Heading
     (Old_Lines : Line_Vectors.Vector; Before : Natural) return String is
   begin
      for K in reverse 0 .. Before - 1 loop
         declare
            L : constant String :=
              To_String (Old_Lines.Element (Old_Lines.First_Index + K));
         begin
            if L'Length > 0
              and then L (L'First) in 'a' .. 'z' | 'A' .. 'Z' | '_' | '$'
            then
               declare
                  Last : Natural := L'Last;
               begin
                  while Last >= L'First
                    and then (L (Last) = ' '
                              or else L (Last) = Character'Val (9))
                  loop
                     Last := Last - 1;
                  end loop;
                  return L (L'First .. Last);
               end;
            end if;
         end;
      end loop;
      return "";
   end Section_Heading;

   --  Largest per-side middle (after common prefix/suffix trimming) for which
   --  the O(n*m) LCS table is built; beyond it a change falls back to a whole
   --  block replace. 3000 mirrors the blame aligner's cap.

   type Op_Kind is (Op_Context, Op_Delete, Op_Insert);
   type Diff_Op is record
      Kind : Op_Kind;
      Text : Unbounded_String;
   end record;
   package Op_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Diff_Op);

   --  The edit script between two line vectors, from git's own diff engine
   --  (Version.Merge.Text_Changes, the ported xdiff).  `git diff` runs Myers
   --  with the indent heuristic on, so hunks land where git puts them; version
   --  used to use a home-grown LCS here and drifted from git on ~12% of inputs.
   function Diff_Ops
     (Old_Lines : Line_Vectors.Vector;
      New_Lines : Line_Vectors.Vector) return Op_Vectors.Vector
   is
      LF : constant Character := Character'Val (10);

      function Joined (Lines : Line_Vectors.Vector) return String is
         Buf : Unbounded_String;
      begin
         for L of Lines loop
            Append (Buf, L);
            Append (Buf, LF);
         end loop;
         return To_String (Buf);
      end Joined;

      Changes : constant Version.Merge.Text_Change_Vectors.Vector :=
        Version.Merge.Text_Changes
          (Old_Text         => Joined (Old_Lines),
           New_Text         => Joined (New_Lines),
           Algorithm        => Version.Merge.Diff_Algorithm_Myers,
           Indent_Heuristic => True);

      Ops : Op_Vectors.Vector;
      O   : Natural := 0;
      N   : Natural := 0;

      procedure Emit (Kind : Op_Kind; Text : Unbounded_String) is
      begin
         Ops.Append (Diff_Op'(Kind => Kind, Text => Text));
      end Emit;
   begin
      for C of Changes loop
         while O < C.Old_First loop
            Emit (Op_Context, Old_Lines.Element (O));
            O := O + 1;
            N := N + 1;
         end loop;

         --  git emits a hunk's deletions before its insertions.
         while O < C.Old_After loop
            Emit (Op_Delete, Old_Lines.Element (O));
            O := O + 1;
         end loop;
         while N < C.New_After loop
            Emit (Op_Insert, New_Lines.Element (N));
            N := N + 1;
         end loop;
      end loop;

      while O < Natural (Old_Lines.Length) loop
         Emit (Op_Context, Old_Lines.Element (O));
         O := O + 1;
         N := N + 1;
      end loop;

      return Ops;
   end Diff_Ops;

   --  git renders a submodule (gitlink) as the one-line text
   --  `Subproject commit <sha>` rather than reading an object -- the commit it
   --  names lives in the submodule, not in this repository.
   function Is_Gitlink_Mode (Mode : String) return Boolean is (Mode = "160000");

   function Side_Content
     (Repo    : Version.Repository.Repository_Handle;
      Cache   : in out Version.Object_Cache.Object_Cache;
      Present : Boolean;
      Id      : Version.Objects.Hex_Object_Id;
      Mode    : String) return String is
   begin
      if not Present then
         return "";
      elsif Is_Gitlink_Mode (Mode) then
         return "Subproject commit " & Version.Objects.To_String (Id)
           & Character'Val (10);
      else
         return Blob_Content (Repo, Cache, Id);
      end if;
   end Side_Content;

   function Unified_File_Diff
     (Path        : String;
      Old_Text    : String;
      New_Text    : String;
      Old_Present : Boolean;
      New_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Id      : Version.Objects.Hex_Object_Id;
      Old_Mode    : String;
      New_Mode    : String;
      Context     : Natural;
      Git_Header  : Boolean := True;
      --  Rename source path ("" when this is not a rename) and the score the
      --  pairing settled on, for git's "similarity index" block.
      Old_Path     : String := "";
      Rename_Score : Natural := 0) return String
   is
      --  git names the a/ side after the path the content came from.
      Head_A : constant String :=
        (if Old_Path'Length > 0 then Old_Path else Path);
      Result    : Unbounded_String;
      Old_Lines : constant Line_Vectors.Vector := Split_Lines (Old_Text);
      New_Lines : constant Line_Vectors.Vector := Split_Lines (New_Text);
      Old_NL    : constant Boolean := Ends_With_Newline (Old_Text);
      New_NL    : constant Boolean := Ends_With_Newline (New_Text);
      Old_Count : constant Natural := Natural (Old_Lines.Length);
      New_Count : constant Natural := Natural (New_Lines.Length);
      Ops       : constant Op_Vectors.Vector := Diff_Ops (Old_Lines, New_Lines);
      Num       : constant Natural := Natural (Ops.Length);
      No_NL     : constant String := "\ No newline at end of file";

      type Nat_Array is array (Natural range <>) of Natural;
      Old_At : Nat_Array (0 .. Num);
      New_At : Nat_Array (0 .. Num);

      function Changed (K : Natural) return Boolean is
        (Ops.Element (K).Kind /= Op_Context);

      function Rng (Start, Cnt : Natural) return String is
        (if Cnt = 1 then Count_Image (Start + 1)
         elsif Cnt = 0 then Count_Image (Start) & ",0"
         else Count_Image (Start + 1) & "," & Count_Image (Cnt));
   begin
      if Old_Text = New_Text then
         return "";
      end if;

      if Git_Header then
         Append_Line (Result, "diff --git a/" & Head_A & " b/" & Path);
         if Old_Path'Length > 0 then
            --  git orders a rename header as mode lines, then the similarity
            --  block, then index.
            if Old_Mode /= New_Mode then
               Append_Line (Result, "old mode " & Old_Mode);
               Append_Line (Result, "new mode " & New_Mode);
            end if;
            Append_Line
              (Result,
               "similarity index "
               & Count_Image
                   (Version.Rename_Detect.Similarity_Index (Rename_Score))
               & "%");
            Append_Line (Result, "rename from " & Old_Path);
            Append_Line (Result, "rename to " & Path);
            Append_Line
              (Result,
               "index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id)
               & (if Old_Mode = New_Mode then " " & New_Mode else ""));
         elsif not Old_Present then
            Append_Line (Result, "new file mode " & New_Mode);
            Append_Line
              (Result, "index " & Abbrev (Short_Zero) & ".." & Abbrev (New_Id));
         elsif not New_Present then
            Append_Line (Result, "deleted file mode " & Old_Mode);
            Append_Line
              (Result, "index " & Abbrev (Old_Id) & ".." & Abbrev (Short_Zero));
         else
            --  A mode change alongside content is announced with old/new mode
            --  lines, and then the index line drops its trailing mode (git
            --  shows the mode only once); an unchanged mode stays on index.
            if Old_Mode /= New_Mode then
               Append_Line (Result, "old mode " & Old_Mode);
               Append_Line (Result, "new mode " & New_Mode);
               Append_Line
                 (Result,
                  "index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id));
            else
               Append_Line
                 (Result,
                  "index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id)
                  & " " & New_Mode);
            end if;
         end if;
      end if;
      Append_Line
        (Result, "--- " & (if Old_Present then "a/" & Head_A else "/dev/null"));
      Append_Line
        (Result, "+++ " & (if New_Present then "b/" & Path else "/dev/null"));

      Old_At (0) := 0;
      New_At (0) := 0;
      for K in 0 .. Num - 1 loop
         Old_At (K + 1) :=
           Old_At (K) + (if Ops.Element (K).Kind = Op_Insert then 0 else 1);
         New_At (K + 1) :=
           New_At (K) + (if Ops.Element (K).Kind = Op_Delete then 0 else 1);
      end loop;

      declare
         K : Natural := 0;
      begin
         while K < Num loop
            if Changed (K) then
               declare
                  H_Start     : constant Natural :=
                    (if K >= Context then K - Context else 0);
                  Last_Change : Natural := K;
                  Look        : Natural;
                  H_End       : Natural;
               begin
                  loop
                     Look := Last_Change + 1;
                     while Look < Num and then not Changed (Look) loop
                        Look := Look + 1;
                     end loop;
                     exit when Look >= Num;
                     exit when Look - Last_Change - 1 > 2 * Context;
                     Last_Change := Look;
                  end loop;
                  H_End :=
                    (if Last_Change + Context <= Num - 1
                     then Last_Change + Context else Num - 1);

                  declare
                     O_Start : constant Natural := Old_At (H_Start);
                     N_Start : constant Natural := New_At (H_Start);
                     O_Cnt   : constant Natural := Old_At (H_End + 1) - O_Start;
                     N_Cnt   : constant Natural := New_At (H_End + 1) - N_Start;
                     Head    : constant String :=
                       Section_Heading (Old_Lines, O_Start);
                  begin
                     Append_Line
                       (Result,
                        "@@ -" & Rng (O_Start, O_Cnt)
                        & " +" & Rng (N_Start, N_Cnt) & " @@"
                        & (if Head'Length > 0 then " " & Head else ""));
                  end;

                  for I in H_Start .. H_End loop
                     declare
                        Op   : constant Diff_Op := Ops.Element (I);
                        Lead : constant Character :=
                          (case Op.Kind is
                              when Op_Context => ' ',
                              when Op_Delete  => '-',
                              when Op_Insert  => '+');
                     begin
                        Append_Line (Result, Lead & To_String (Op.Text));
                        if Op.Kind = Op_Delete
                          and then not Old_NL
                          and then Old_At (I + 1) = Old_Count
                          and then Old_Count > 0
                        then
                           Append_Line (Result, No_NL);
                        elsif Op.Kind = Op_Insert
                          and then not New_NL
                          and then New_At (I + 1) = New_Count
                          and then New_Count > 0
                        then
                           Append_Line (Result, No_NL);
                        elsif Op.Kind = Op_Context and then I = Num - 1 then
                           if not New_NL and then New_Count > 0 then
                              Append_Line (Result, No_NL);
                           elsif not Old_NL and then Old_Count > 0 then
                              Append_Line (Result, No_NL);
                           end if;
                        end if;
                     end;
                  end loop;

                  K := H_End + 1;
               end;
            else
               K := K + 1;
            end if;
         end loop;
      end;

      return To_String (Result);
   end Unified_File_Diff;

   --  git's base85 alphabet (base85.c).
   Base85_Alphabet : constant String :=
     "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
     & "abcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

   --  git's emit_binary_diff_body(): the deflated blob, base85 encoded in
   --  lines of at most 52 bytes, each prefixed by a length character.
   function Base85_Lines (Data : String) return String is
      LF     : constant Character := Character'Val (10);
      Result : Unbounded_String;
      Pos    : Natural := Data'First;
   begin
      while Pos <= Data'Last loop
         declare
            Bytes : constant Natural :=
              Natural'Min (52, Data'Last - Pos + 1);
            Line  : Unbounded_String;
            I     : Natural := Pos;
         begin
            --  Length prefix: 'A'..'Z' for 1..26 bytes, 'a'..'z' beyond.
            Append
              (Line,
               (if Bytes <= 26
                then Character'Val (Character'Pos ('A') + Bytes - 1)
                else Character'Val (Character'Pos ('a') + Bytes - 27)));

            --  Five base85 digits per (up to) four big-endian bytes.
            while I <= Pos + Bytes - 1 loop
               declare
                  Acc   : Interfaces.Unsigned_32 := 0;
                  Shift : Integer := 24;
                  Group : String (1 .. 5);
               begin
                  while Shift >= 0 loop
                     if I <= Pos + Bytes - 1 then
                        Acc := Acc or Interfaces.Shift_Left
                          (Interfaces.Unsigned_32
                             (Character'Pos (Data (I))), Shift);
                        I := I + 1;
                     end if;
                     exit when I > Pos + Bytes - 1 and then Shift <= 24;
                     Shift := Shift - 8;
                  end loop;

                  for K in reverse Group'Range loop
                     Group (K) :=
                       Base85_Alphabet
                         (Base85_Alphabet'First
                          + Natural (Acc mod 85));
                     Acc := Acc / 85;
                  end loop;
                  Append (Line, Group);
               end;
            end loop;

            Append (Result, To_String (Line) & LF);
            Pos := Pos + Bytes;
         end;
      end loop;

      return To_String (Result);
   end Base85_Lines;

   --  One direction of git's `GIT binary patch`: we always emit the "literal"
   --  form (git also considers a delta and keeps whichever is smaller; both
   --  are valid input to `git apply`). The deflated bytes are not expected to
   --  match git's -- a zlib stream is not canonical, only its content is.
   function Binary_Patch_Body (Content : String) return String is
      LF : constant Character := Character'Val (10);
   begin
      return "literal " & Count_Image (Content'Length) & LF
        & Base85_Lines (Version.Compression.Deflate_Zlib (Content))
        & LF;
   end Binary_Patch_Body;

   function One_File_Diff
     (Repo        : Version.Repository.Repository_Handle;
      Cache       : in out Version.Object_Cache.Object_Cache;
      Path        : String;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      Old_Mode    : String;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      New_Mode    : String;
      New_Working : Boolean;
      Context     : Natural;
      Old_Path     : String := "";
      Rename_Score : Natural := 0;
      Binary_Patch : Boolean := False) return String
   is
      Head_A : constant String :=
        (if Old_Path'Length > 0 then Old_Path else Path);
   begin
      if Old_Present and then New_Present and then Old_Id = New_Id then
         --  Identical content: a pure mode change still shows a git header
         --  ("old mode"/"new mode" and nothing else), and a rename shows its
         --  similarity block with no index or hunks at all; no change at all
         --  is empty.
         declare
            Eff_Old : constant String :=
              (if Old_Mode'Length > 0 then Old_Mode else "100644");
            Eff_New : constant String :=
              (if New_Mode'Length > 0 then New_Mode else Eff_Old);
            R : Unbounded_String;
         begin
            if Eff_Old = Eff_New and then Old_Path'Length = 0 then
               return "";
            end if;
            Append_Line (R, "diff --git a/" & Head_A & " b/" & Path);
            if Eff_Old /= Eff_New then
               Append_Line (R, "old mode " & Eff_Old);
               Append_Line (R, "new mode " & Eff_New);
            end if;
            if Old_Path'Length > 0 then
               Append_Line
                 (R,
                  "similarity index "
                  & Count_Image
                      (Version.Rename_Detect.Similarity_Index (Rename_Score))
                  & "%");
               Append_Line (R, "rename from " & Old_Path);
               Append_Line (R, "rename to " & Path);
            end if;
            return To_String (R);
         end;
      end if;

      declare
         Old_Text : constant String :=
           Side_Content (Repo, Cache, Old_Present, Old_Id, Old_Mode);
         New_Text : constant String :=
           (if not New_Present
            then ""
            elsif New_Working and then not Is_Gitlink_Mode (New_Mode)
            then Working_Content (Repo, Path)
            else Side_Content (Repo, Cache, New_Present, New_Id, New_Mode));
         Eff_Old_Mode : constant String :=
           (if Old_Mode'Length > 0 then Old_Mode else "100644");
         Eff_New_Mode : constant String :=
           (if New_Mode'Length > 0 then New_Mode else Eff_Old_Mode);
      begin
         if Contains_Nul (Old_Text) or else Contains_Nul (New_Text) then
            declare
               R : Unbounded_String;
            begin
               --  git prints the unabbreviated index with --binary: the
               --  patch has to name the blobs exactly.
               declare
                  function Ix (Id : Version.Objects.Hex_Object_Id)
                    return String
                  is (if Binary_Patch then Version.Objects.To_String (Id)
                      else Abbrev (Id));
               begin
                  Append_Line (R, "diff --git a/" & Head_A & " b/" & Path);
                  if Old_Path'Length > 0 then
                     Append_Line
                       (R,
                        "similarity index "
                        & Count_Image
                            (Version.Rename_Detect.Similarity_Index
                               (Rename_Score))
                        & "%");
                     Append_Line (R, "rename from " & Old_Path);
                     Append_Line (R, "rename to " & Path);
                     Append_Line
                       (R,
                        "index " & Ix (Old_Id) & ".." & Ix (New_Id)
                        & (if Eff_Old_Mode = Eff_New_Mode
                           then " " & Eff_New_Mode else ""));
                  elsif not Old_Present then
                     Append_Line (R, "new file mode " & Eff_New_Mode);
                     Append_Line
                       (R, "index " & Ix (Short_Zero) & ".." & Ix (New_Id));
                  elsif not New_Present then
                     Append_Line (R, "deleted file mode " & Eff_Old_Mode);
                     Append_Line
                       (R, "index " & Ix (Old_Id) & ".." & Ix (Short_Zero));
                  else
                     Append_Line
                       (R,
                        "index " & Ix (Old_Id) & ".." & Ix (New_Id)
                        & " " & Eff_New_Mode);
                  end if;
               end;
               if Binary_Patch then
                  --  git's `--binary` (implied by format-patch): the full
                  --  index, then the forward and reverse literal blocks.
                  Append_Line (R, "GIT binary patch");
                  Append (R, Binary_Patch_Body (New_Text));
                  Append (R, Binary_Patch_Body (Old_Text));
               else
                  Append_Line
                    (R,
                     "Binary files "
                     & (if Old_Present then "a/" & Head_A else "/dev/null")
                     & " and "
                     & (if New_Present then "b/" & Path else "/dev/null")
                     & " differ");
               end if;
               return To_String (R);
            end;
         end if;

         return
           Unified_File_Diff
             (Path        => Path,
              Old_Text    => Old_Text,
              New_Text    => New_Text,
              Old_Present => Old_Present,
              New_Present => New_Present,
              Old_Id      => Old_Id,
              New_Id      => New_Id,
              Old_Mode    => Eff_Old_Mode,
              New_Mode    => Eff_New_Mode,
              Context     => Context,
              Old_Path     => Old_Path,
              Rename_Score => Rename_Score);
      end;
   end One_File_Diff;

   function To_Map
     (Items : Side_Entry_Vectors.Vector) return Side_Entry_Maps.Map
   is
      Result : Side_Entry_Maps.Map;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               Result.Include (Path, Items.Element (I));
            end;
         end loop;
      end if;

      return Result;
   end To_Map;

   function Less_Side_Entry
     (Left : Side_Entry; Right : Side_Entry) return Boolean is
   begin
      return To_String (Left.Path) < To_String (Right.Path);
   end Less_Side_Entry;

   procedure Sort (Items : in out Side_Entry_Vectors.Vector) is
      package Side_Sorting is new
        Side_Entry_Vectors.Generic_Sorting ("<" => Less_Side_Entry);
   begin
      if Items.Length < 2 then
         return;
      end if;

      Side_Sorting.Sort (Items);
   end Sort;

   function Head_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Refs    : in out Version.Ref_Cache.Ref_Cache;
      Objects : in out Version.Object_Cache.Object_Cache;
      Trees   : in out Version.Tree_Cache.Tree_Cache)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Empty  : Version.Objects.Tree_Entry_Vectors.Vector;
      Commit : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Commit'Length = 0 then
         return Empty;
      end if;

      declare
         Commit_Obj : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object
             (Repo  => Repo,
              Cache => Objects,
              Id    => Version.Objects.To_Object_Id (Commit));
      begin
         return
           Version.Tree_Cache.Flatten_Tree
             (Repo    => Repo,
              Cache   => Trees,
              Tree_Id => Version.Objects.Commit_Tree_Id (Commit_Obj));
      end;
   end Head_Tree;

   function Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Commit_Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Objects, Id => Commit_Id);
   begin
      return
        Version.Tree_Cache.Flatten_Tree
          (Repo    => Repo,
           Cache   => Trees,
           Tree_Id => Version.Objects.Commit_Tree_Id (Commit_Obj));
   end Tree_For_Commit;

   function From_Index
     (Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            if Entries.Element (I).Stage = 0 then
               Result.Append
                 (Side_Entry'
                    (Path    => Entries.Element (I).Path,
                     Id      => Entries.Element (I).Id,
                     Mode    => Entries.Element (I).Mode,
                     Present => True));
            end if;
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Index;

   function From_Working
     (Entries : Version.Working_Tree.Working_File_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Append
              (Side_Entry'
                 (Path    => Entries.Element (I).Path,
                  Id      => Entries.Element (I).Id,
                  Mode    => Null_Unbounded_String,
                  Present => True));
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Working;

   function From_Tree
     (Entries : Version.Objects.Tree_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Append
              (Side_Entry'
                 (Path    => Entries.Element (I).Path,
                  Id      => Entries.Element (I).Id,
                  Mode    => Entries.Element (I).Mode,
                  Present => True));
         end loop;
      end if;
      Sort (Result);
      return Result;
   end From_Tree;

   --  The mode git would record for the working file at Path right now:
   --  symlink -> 120000, an executable regular file -> 100755, else 100644.
   --  Mirrors Version.Status.Working_Index_Mode so a chmod (a mode-only
   --  change) is visible to diff, not silently masked by the index mode.
   function Working_Disk_Mode
     (Repo : Version.Repository.Repository_Handle;
      Path : String) return String
   is
      Full : constant String :=
        Version.Files.To_Native_Path
          (Version.Files.Join (Version.Repository.Root_Path (Repo), Path));
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Full) then
         return "120000";
      elsif Version.Platform.Supports_Executable_Bit
        and then GNAT.OS_Lib.Is_Executable_File (Full)
      then
         return "100755";
      else
         return "100644";
      end if;
   exception
      when others =>
         return "100644";
   end Working_Disk_Mode;

   function From_Working_For_Index
     (Working : Version.Working_Tree.Working_File_Vectors.Vector;
      Index   : Version.Staging.Index_Entry_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result      : Side_Entry_Vectors.Vector;
      Repo        : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Working_Map : constant Side_Entry_Maps.Map :=
        To_Map (From_Working (Working));
   begin
      if not Index.Is_Empty then
         for I in Index.First_Index .. Index.Last_Index loop
            declare
               Path   : constant String := To_String (Index.Element (I).Path);
               Cursor : constant Side_Entry_Maps.Cursor :=
                 Working_Map.Find (Path);
            begin
               if Side_Entry_Maps.Has_Element (Cursor) then
                  declare
                     Entry_Copy : Side_Entry := Side_Entry_Maps.Element (Cursor);
                     Idx_Mode   : constant String :=
                       To_String (Index.Element (I).Mode);
                  begin
                     --  Working_File carries no mode. A gitlink keeps the
                     --  index's 160000; any other path takes the mode it has
                     --  on disk now, so a chmod shows as a mode change and the
                     --  "index <o>..<n> <mode>" line stays accurate otherwise.
                     Entry_Copy.Mode :=
                       (if Idx_Mode = "160000"
                        then Index.Element (I).Mode
                        else To_Unbounded_String
                               (Working_Disk_Mode (Repo, Path)));
                     Result.Append (Entry_Copy);
                  end;
               end if;
            end;
         end loop;
      end if;

      Sort (Result);
      return Result;
   end From_Working_For_Index;

   function Filter_Side
     (Side      : Side_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if Side.Is_Empty then
         return Result;
      end if;

      for I in Side.First_Index .. Side.Last_Index loop
         declare
            Path : constant String := To_String (Side.Element (I).Path);
         begin
            if Version.Pathspec.Matches_Any (Pathspecs, Path) then
               Result.Append (Side.Element (I));
            end if;
         end;
      end loop;

      return Result;
   end Filter_Side;

   function Repeat (C : Character; N : Natural) return String is
      S : constant String (1 .. N) := (others => C);
   begin
      return S;
   end Repeat;

   --  git's pprint_rename(): collapse the shared head and tail of the two
   --  paths into "pfx{old-mid => new-mid}sfx", falling back to "old => new"
   --  when they share nothing. A common prefix always ends at a '/'.
   function Pretty_Rename (Old_Path, New_Path : String) return String is
      Len_A : constant Natural := Old_Path'Length;
      Len_B : constant Natural := New_Path'Length;
      Pfx   : Natural := 0;
      Sfx   : Natural := 0;
      I     : Natural := 0;
   begin
      while I < Natural'Min (Len_A, Len_B)
        and then Old_Path (Old_Path'First + I) = New_Path (New_Path'First + I)
      loop
         if Old_Path (Old_Path'First + I) = '/' then
            Pfx := I + 1;
         end if;
         I := I + 1;
      end loop;

      --  Walk back from the ends. Both scans start on the (virtual) string
      --  terminator, and with a common prefix the scan may run one character
      --  into it, to see that same slash again.
      declare
         NUL : constant Character := Character'Val (0);

         function Char_A (K : Integer) return Character is
           (if K >= Len_A then NUL else Old_Path (Old_Path'First + K));

         function Char_B (K : Integer) return Character is
           (if K >= Len_B then NUL else New_Path (New_Path'First + K));

         Adjust : constant Integer := (if Pfx > 0 then 1 else 0);
         A      : Integer := Len_A;
         B      : Integer := Len_B;
      begin
         while A >= Integer (Pfx) - Adjust
           and then B >= Integer (Pfx) - Adjust
           and then Char_A (A) = Char_B (B)
         loop
            if Char_A (A) = '/' then
               Sfx := Len_A - A;
            end if;
            A := A - 1;
            B := B - 1;
         end loop;
      end;

      declare
         A_Mid : constant Natural :=
           Natural'Max (0, Len_A - Pfx - Sfx);
         B_Mid : constant Natural :=
           Natural'Max (0, Len_B - Pfx - Sfx);
         Head  : constant String :=
           Old_Path (Old_Path'First .. Old_Path'First + Pfx - 1);
         Tail  : constant String :=
           Old_Path (Old_Path'Last - Sfx + 1 .. Old_Path'Last);
         Mid_A : constant String :=
           Old_Path (Old_Path'First + Pfx .. Old_Path'First + Pfx + A_Mid - 1);
         Mid_B : constant String :=
           New_Path (New_Path'First + Pfx .. New_Path'First + Pfx + B_Mid - 1);
      begin
         if Pfx + Sfx > 0 then
            return Head & "{" & Mid_A & " => " & Mid_B & "}" & Tail;
         end if;
         return Mid_A & " => " & Mid_B;
      end;
   end Pretty_Rename;

   --  Resolve Diff_Options.Detect_Renames: an explicit -M/--no-renames wins,
   --  otherwise `diff.renames` decides, defaulting to on as git does.
   function Renames_Enabled
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options) return Boolean
   is
      Text : constant String :=
        (if Version.Config.Has_Key (Repo, "diff.renames")
         then Version.Config.Get_Value (Repo, "diff.renames") else "");
      Lower : String := Text;
   begin
      case Options.Detect_Renames is
         when Renames_On  => return True;
         when Renames_Off => return False;
         when Renames_Default =>
            for I in Lower'Range loop
               Lower (I) := Ada.Characters.Handling.To_Lower (Lower (I));
            end loop;
            return not (Lower = "false" or else Lower = "0"
                        or else Lower = "no");
      end case;
   exception
      when others =>
         return True;
   end Renames_Enabled;

   --  git's R<nnn>/C<nnn> code: the similarity percentage, zero padded to
   --  three digits.
   function Score_Image (Score : Natural) return String is
      Pct : constant Natural :=
        Version.Rename_Detect.Similarity_Index (Score);
      Img : constant String := Count_Image (Pct);
   begin
      return [1 .. 3 - Img'Length => '0'] & Img;
   end Score_Image;

   --  Where a created path's content came from, and how similar it was.
   type Rename_Target is record
      Source : Unbounded_String;
      Score  : Natural := 0;
   end record;

   type Stat_Entry is record
      Path         : Unbounded_String;
      --  Set only for a rename: the path the content came from.
      Old_Path     : Unbounded_String := Null_Unbounded_String;
      Rename_Score : Natural := 0;
      Ins          : Natural := 0;
      Del          : Natural := 0;
      Binary       : Boolean := False;
      Old_Size     : Natural := 0;
      New_Size     : Natural := 0;
      Old_Present  : Boolean := False;
      New_Present  : Boolean := False;
      Old_Mode     : Unbounded_String := Null_Unbounded_String;
      New_Mode     : Unbounded_String := Null_Unbounded_String;
   end record;

   function Is_Rename (F : Stat_Entry) return Boolean is
     (Length (F.Old_Path) > 0);

   --  The name git prints for the entry in --stat and --summary.
   function Stat_Name (F : Stat_Entry) return String is
     (if Is_Rename (F)
      then Pretty_Rename (To_String (F.Old_Path), To_String (F.Path))
      else To_String (F.Path));
   package Stat_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Stat_Entry);

   procedure One_File_Stat
     (Repo        : Version.Repository.Repository_Handle;
      Cache       : in out Version.Object_Cache.Object_Cache;
      Path        : String;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      Old_Mode    : String;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      New_Mode    : String;
      New_Working : Boolean;
      Result      : out Stat_Entry;
      Changed     : out Boolean) is
   begin
      Result  :=
        (Path        => To_Unbounded_String (Path),
         Old_Present => Old_Present,
         New_Present => New_Present,
         Old_Mode    =>
           To_Unbounded_String (if Old_Mode'Length > 0 then Old_Mode
                                else "100644"),
         New_Mode    =>
           To_Unbounded_String (if New_Mode'Length > 0 then New_Mode
                                elsif Old_Mode'Length > 0 then Old_Mode
                                else "100644"),
         others      => <>);
      Changed := False;
      if Old_Present and then New_Present and then Old_Id = New_Id then
         --  Identical content: still a change if the mode moved, and git
         --  reports it (as "M", with a zero-width stat bar).
         Changed := Result.Old_Mode /= Result.New_Mode;
         return;
      end if;

      declare
         Old_Text : constant String :=
           Side_Content (Repo, Cache, Old_Present, Old_Id, Old_Mode);
         New_Text : constant String :=
           (if not New_Present
            then ""
            elsif New_Working and then not Is_Gitlink_Mode (New_Mode)
            then Working_Content (Repo, Path)
            else Side_Content (Repo, Cache, New_Present, New_Id, New_Mode));
      begin
         if Old_Text = New_Text then
            return;
         end if;
         Changed := True;

         if Contains_Nul (Old_Text) or else Contains_Nul (New_Text) then
            Result.Binary   := True;
            Result.Old_Size := Old_Text'Length;
            Result.New_Size := New_Text'Length;
            return;
         end if;

         declare
            Ops : constant Op_Vectors.Vector :=
              Diff_Ops (Split_Lines (Old_Text), Split_Lines (New_Text));
         begin
            for K in 0 .. Natural (Ops.Length) - 1 loop
               case Ops.Element (K).Kind is
                  when Op_Insert  => Result.Ins := Result.Ins + 1;
                  when Op_Delete  => Result.Del := Result.Del + 1;
                  when Op_Context => null;
               end case;
            end loop;
         end;
      end;
   end One_File_Stat;

   --  Render git's `--stat` block (per-file change bars + a "N files changed"
   --  footer) when Show_Stat, followed by git's `--summary` lines
   --  (create/delete mode, mode change) when Show_Summary.
   function Emit_Stat
     (Files        : Stat_Vectors.Vector;
      Show_Stat    : Boolean;
      Show_Summary : Boolean) return String
   is
      Result    : Unbounded_String;
      Name_W    : Natural := 0;
      Count_W   : Natural := 0;
      Total_Ins : Natural := 0;
      Total_Del : Natural := 0;
      LF        : constant Character := Character'Val (10);

      Max_Change : Natural := 0;
      Bin_W      : Natural := 0;
      Graph_W    : Integer := 0;
      Width      : Integer;

      --  git's term_columns(): $COLUMNS when it parses as a positive number,
      --  otherwise 80 (the ioctl only applies when stdout is a terminal, and
      --  every byte-compared run is piped).
      function Term_Columns return Integer is
         Text : constant String :=
           (if Ada.Environment_Variables.Exists ("COLUMNS")
            then Ada.Environment_Variables.Value ("COLUMNS") else "");
      begin
         if Text'Length > 0 then
            declare
               N : constant Integer := Integer'Value (Text);
            begin
               if N > 0 then
                  return N;
               end if;
            end;
         end if;
         return 80;
      exception
         when Constraint_Error =>
            return 80;
      end Term_Columns;

      --  git's scale_linear(): at least one mark whenever there is a change.
      function Scale_Linear (It, W, Max : Natural) return Natural is
        (if It = 0 then 0 else 1 + (It * (W - 1)) / Max);
   begin
      if Files.Is_Empty then
         return "";
      end if;

      for I in Files.First_Index .. Files.Last_Index loop
         declare
            F : constant Stat_Entry := Files.Element (I);
         begin
            Name_W := Natural'Max (Name_W, Stat_Name (F)'Length);
            if F.Binary then
               --  "Bin XXX -> YYY bytes" is not scaled, but it does set the
               --  width the graph column has to accommodate.
               Bin_W :=
                 Natural'Max
                   (Bin_W,
                    14 + Count_Image (F.Old_Size)'Length
                    + Count_Image (F.New_Size)'Length);
               Count_W := Natural'Max (Count_W, 3);
            else
               Max_Change := Natural'Max (Max_Change, F.Ins + F.Del);
               Total_Ins := Total_Ins + F.Ins;
               Total_Del := Total_Del + F.Del;
            end if;
         end;
      end loop;

      Count_W :=
        Natural'Max (Count_W, Count_Image (Max_Change)'Length);

      --  git's width budget: name + number + 6 constant columns + graph.
      Width := Term_Columns;
      if Width < 16 + 6 + Count_W then
         Width := 16 + 6 + Count_W;
      end if;

      Graph_W :=
        (if Max_Change + 4 > Bin_W then Max_Change else Bin_W - 4);

      if Name_W + Count_W + 6 + Graph_W > Width then
         if Graph_W > Width * 3 / 8 - Count_W - 6 then
            Graph_W := Width * 3 / 8 - Count_W - 6;
            if Graph_W < 6 then
               Graph_W := 6;
            end if;
         end if;
         if Name_W > Width - Count_W - 6 - Graph_W then
            Name_W := Natural'Max (0, Width - Count_W - 6 - Graph_W);
         else
            Graph_W := Width - Count_W - 6 - Name_W;
         end if;
      end if;

      if Show_Stat then
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               F    : constant Stat_Entry := Files.Element (I);
               Full : constant String := Stat_Name (F);

               --  git elides the head of an over-long name as "...", cutting
               --  back to a path separator when there is one.
               function Display_Name return String is
                  Budget : constant Integer := Name_W - 3;
                  Cut    : Integer;
               begin
                  if Full'Length <= Name_W then
                     return Full;
                  end if;
                  Cut := Full'Last - Integer'Max (Budget, 0) + 1;
                  for J in Cut .. Full'Last loop
                     if Full (J) = '/' then
                        return "..." & Full (J .. Full'Last);
                     end if;
                  end loop;
                  return "..." & Full (Cut .. Full'Last);
               end Display_Name;

               Name     : constant String := Display_Name;
               Pad_Name : constant String :=
                 Name & Repeat (' ', Integer'Max (0, Name_W - Name'Length));
            begin
               if F.Binary then
                  declare
                     Bin : constant String := "Bin";
                  begin
                     Append
                       (Result,
                        " " & Pad_Name & " | "
                        & Repeat (' ', Integer'Max (0, Count_W - Bin'Length))
                        & Bin & " "
                        & Count_Image (F.Old_Size) & " -> "
                        & Count_Image (F.New_Size) & " bytes" & LF);
                  end;
               else
                  declare
                     Num : constant String := Count_Image (F.Ins + F.Del);
                     Add : Natural := F.Ins;
                     Del_N : Natural := F.Del;
                  begin
                     --  git scales the bar graph into the graph column when
                     --  the largest change does not fit.
                     if Graph_W <= Max_Change and then Max_Change > 0 then
                        declare
                           Total : Natural :=
                             Scale_Linear (Add + Del_N, Graph_W, Max_Change);
                        begin
                           if Total < 2 and then Add > 0 and then Del_N > 0 then
                              Total := 2;
                           end if;
                           if Add < Del_N then
                              Add := Scale_Linear (Add, Graph_W, Max_Change);
                              Del_N := Total - Add;
                           else
                              Del_N := Scale_Linear (Del_N, Graph_W, Max_Change);
                              Add := Total - Del_N;
                           end if;
                        end;
                     end if;

                     Append
                       (Result,
                        " " & Pad_Name & " | "
                        & Repeat (' ', Integer'Max (0, Count_W - Num'Length))
                        & Num
                        --  git separates the count from the bars only when
                        --  there are bars (a pure rename shows a bare "0").
                        & (if F.Ins + F.Del > 0 then " " else "")
                        & Repeat ('+', Add) & Repeat ('-', Del_N) & LF);
                  end;
               end if;
            end;
         end loop;

         declare
            N : constant Natural := Natural (Files.Length);
         begin
            Append
              (Result,
               " " & Count_Image (N) & " file"
               & (if N = 1 then "" else "s") & " changed");
            --  git's print_stat_summary(): each clause appears when its own
            --  count is non-zero, or when the other one is zero -- so a
            --  change with neither (a pure rename) still prints both zeros.
            if Total_Ins > 0 or else Total_Del = 0 then
               Append
                 (Result,
                  ", " & Count_Image (Total_Ins) & " insertion"
                  & (if Total_Ins = 1 then "" else "s") & "(+)");
            end if;
            if Total_Del > 0 or else Total_Ins = 0 then
               Append
                 (Result,
                  ", " & Count_Image (Total_Del) & " deletion"
                  & (if Total_Del = 1 then "" else "s") & "(-)");
            end if;
            Append (Result, LF);
         end;
      end if;

      if Show_Summary then
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               F    : constant Stat_Entry := Files.Element (I);
               Name : constant String := Stat_Name (F);
            begin
               if Is_Rename (F) then
                  Append
                    (Result,
                     " rename " & Name & " ("
                     & Count_Image
                         (Version.Rename_Detect.Similarity_Index
                            (F.Rename_Score))
                     & "%)" & LF);
                  --  git's show_mode_change with show_name = 0: a rename's
                  --  mode change is reported without repeating the path.
                  if F.Old_Mode /= F.New_Mode then
                     Append
                       (Result,
                        " mode change " & To_String (F.Old_Mode) & " => "
                        & To_String (F.New_Mode) & LF);
                  end if;
               elsif not F.Old_Present then
                  Append
                    (Result,
                     " create mode " & To_String (F.New_Mode) & " "
                     & Name & LF);
               elsif not F.New_Present then
                  Append
                    (Result,
                     " delete mode " & To_String (F.Old_Mode) & " "
                     & Name & LF);
               elsif F.Old_Mode /= F.New_Mode then
                  Append
                    (Result,
                     " mode change " & To_String (F.Old_Mode) & " => "
                     & To_String (F.New_Mode) & " " & Name & LF);
               end if;
            end;
         end loop;
      end if;

      return To_String (Result);
   end Emit_Stat;

   function Diff_Sides
     (Repo        : Version.Repository.Repository_Handle;
      Objects     : in out Version.Object_Cache.Object_Cache;
      Old_Side    : Side_Entry_Vectors.Vector;
      New_Side    : Side_Entry_Vectors.Vector;
      New_Working : Boolean;
      Context     : Natural := 3;
      Stat        : Boolean := False;
      Summary     : Boolean := False;
      Name_Only   : Boolean := False;
      Name_Status : Boolean := False;
      Detect_Renames : Boolean := False;
      Rename_Score   : Natural := 0;
      Rename_Limit   : Natural := 0;
      Binary_Patch   : Boolean := False) return String
   is
      HT       : constant Character := Character'Val (9);
      NL       : constant Character := Character'Val (10);
      Old_Map  : constant Side_Entry_Maps.Map := To_Map (Old_Side);
      New_Map  : constant Side_Entry_Maps.Map := To_Map (New_Side);
      As_Stat  : constant Boolean := Stat or else Summary;
      As_List  : constant Boolean := Name_Only or else Name_Status;
      Paths    : Path_Sets.Map;
      Result   : Unbounded_String;
      Stats    : Stat_Vectors.Vector;

      --  Rename pairing state: for a created path, where its content came
      --  from; for a deleted path, that it has been consumed as a source and
      --  must not be reported as a deletion of its own.
      package Rename_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Rename_Target);
      Renamed_To   : Rename_Maps.Map;
      Renamed_From : Path_Sets.Map;

      function Side_Text
        (Side : Version.Rename_Detect.Rename_Side) return String
      is
         Path : constant String := To_String (Side.Path);
         Mode : constant String := To_String (Side.Mode);
      begin
         if New_Working
           and then New_Map.Contains (Path)
           and then not Is_Gitlink_Mode (Mode)
         then
            return Working_Content (Repo, Path);
         end if;
         return Side_Content (Repo, Objects, True, Side.Id, Mode);
      exception
         when others =>
            return "";
      end Side_Text;

      function Detect_Pairs is
        new Version.Rename_Detect.Detect (Content_Of => Side_Text);

      procedure Pair_Renames is
         Sources, Dests : Version.Rename_Detect.Side_Vectors.Vector;
      begin
         for I in Old_Side.First_Index .. Old_Side.Last_Index loop
            declare
               E    : constant Side_Entry := Old_Side.Element (I);
               Path : constant String := To_String (E.Path);
            begin
               --  A sparse-excluded path is missing from the working tree by
               --  design, not deleted, so it is not a rename source either.
               if not New_Map.Contains (Path)
                 and then not (New_Working
                               and then not Version.Sparse.Included
                                              (Repo, Path))
               then
                  Sources.Append
                    (Version.Rename_Detect.Rename_Side'
                       (Path => E.Path, Id => E.Id, Mode => E.Mode));
               end if;
            end;
         end loop;

         for I in New_Side.First_Index .. New_Side.Last_Index loop
            declare
               E    : constant Side_Entry := New_Side.Element (I);
               Path : constant String := To_String (E.Path);
            begin
               if not Old_Map.Contains (Path) then
                  Dests.Append
                    (Version.Rename_Detect.Rename_Side'
                       (Path => E.Path, Id => E.Id, Mode => E.Mode));
               end if;
            end;
         end loop;

         declare
            Pairs : constant Version.Rename_Detect.Pair_Vectors.Vector :=
              Detect_Pairs
                (Sources, Dests,
                 Minimum_Score =>
                   (if Rename_Score = 0
                    then Version.Rename_Detect.Default_Rename_Score
                    else Rename_Score),
                 Rename_Limit =>
                   (if Rename_Limit = 0
                    then Version.Rename_Detect.Default_Rename_Limit
                    else Rename_Limit));
         begin
            for P of Pairs loop
               declare
                  Src : constant Version.Rename_Detect.Rename_Side :=
                    Sources.Element (P.Source);
                  Dst : constant Version.Rename_Detect.Rename_Side :=
                    Dests.Element (P.Dest);
               begin
                  Renamed_To.Include
                    (To_String (Dst.Path),
                     Rename_Target'(Source => Src.Path, Score => P.Score));
                  Renamed_From.Include (To_String (Src.Path), True);
               end;
            end loop;
         end;
      end Pair_Renames;
   begin
      if not Old_Side.Is_Empty then
         for I in Old_Side.First_Index .. Old_Side.Last_Index loop
            Paths.Include (To_String (Old_Side.Element (I).Path), True);
         end loop;
      end if;

      if not New_Side.Is_Empty then
         for I in New_Side.First_Index .. New_Side.Last_Index loop
            Paths.Include (To_String (New_Side.Element (I).Path), True);
         end loop;
      end if;

      if Detect_Renames then
         Pair_Renames;
      end if;

      declare
         Cursor : Path_Sets.Cursor := Paths.First;
      begin
         while Path_Sets.Has_Element (Cursor) loop
            declare
               Path       : constant String := Path_Sets.Key (Cursor);
               Old_Cursor : constant Side_Entry_Maps.Cursor :=
                 Old_Map.Find (Path);
               New_Cursor : constant Side_Entry_Maps.Cursor :=
                 New_Map.Find (Path);
               Old_E      : constant Side_Entry :=
                 (if not Side_Entry_Maps.Has_Element (Old_Cursor)
                  then
                    Side_Entry'
                      (Path    => To_Unbounded_String (Path),
                       Id      => Short_Zero,
                       Mode    => Null_Unbounded_String,
                       Present => False)
                  else Side_Entry_Maps.Element (Old_Cursor));
               New_E      : constant Side_Entry :=
                 (if not Side_Entry_Maps.Has_Element (New_Cursor)
                  then
                    Side_Entry'
                      (Path    => To_Unbounded_String (Path),
                       Id      => Short_Zero,
                       Mode    => Null_Unbounded_String,
                       Present => False)
                  else Side_Entry_Maps.Element (New_Cursor));

               --  Rename role of this path, if any.
               Rn_Cursor : constant Rename_Maps.Cursor :=
                 Renamed_To.Find (Path);
               Is_Rename_Dest : constant Boolean :=
                 Rename_Maps.Has_Element (Rn_Cursor);
               Rn : constant Rename_Target :=
                 (if Is_Rename_Dest then Rename_Maps.Element (Rn_Cursor)
                  else (Source => Null_Unbounded_String, Score => 0));
               Rn_Path : constant String := To_String (Rn.Source);
               --  For a rename the "old" side is the source path's entry.
               Src_E : constant Side_Entry :=
                 (if Is_Rename_Dest and then Old_Map.Contains (Rn_Path)
                  then Old_Map.Element (Rn_Path) else Old_E);
            begin
               if Renamed_From.Contains (Path) then
                  --  Consumed as a rename source; reported at its destination.
                  null;
               elsif New_Working
                 and then Old_E.Present
                 and then not New_E.Present
                 and then not Version.Sparse.Included (Repo, Path)
               then
                  --  Sparse-excluded (skip-worktree) paths are absent from the
                  --  working tree by design, not deleted; git omits them.
                  null;
               elsif As_List then
                  declare
                     Entry_Stat : Stat_Entry;
                     Changed    : Boolean;
                  begin
                     One_File_Stat
                       (Repo        => Repo,
                        Cache       => Objects,
                        Path        => Path,
                        Old_Present => Src_E.Present or else Is_Rename_Dest,
                        Old_Id      => Src_E.Id,
                        Old_Mode    => To_String (Src_E.Mode),
                        New_Present => New_E.Present,
                        New_Id      => New_E.Id,
                        New_Mode    => To_String (New_E.Mode),
                        New_Working => New_Working,
                        Result      => Entry_Stat,
                        Changed     => Changed);
                     if Changed or else Is_Rename_Dest then
                        if Name_Status then
                           if Is_Rename_Dest then
                              --  git pads the score to three digits and names
                              --  both sides.
                              Append
                                (Result,
                                 "R" & Score_Image (Rn.Score) & HT
                                 & Rn_Path & HT);
                           else
                              Append
                                (Result,
                                 (if not Entry_Stat.Old_Present then 'A'
                                  elsif not Entry_Stat.New_Present then 'D'
                                  else 'M')
                                 & HT);
                           end if;
                        end if;
                        Append (Result, Path & NL);
                     end if;
                  end;
               elsif As_Stat then
                  declare
                     Entry_Stat : Stat_Entry;
                     Changed    : Boolean;
                  begin
                     One_File_Stat
                       (Repo        => Repo,
                        Cache       => Objects,
                        Path        => Path,
                        Old_Present => Src_E.Present or else Is_Rename_Dest,
                        Old_Id      => Src_E.Id,
                        Old_Mode    => To_String (Src_E.Mode),
                        New_Present => New_E.Present,
                        New_Id      => New_E.Id,
                        New_Mode    => To_String (New_E.Mode),
                        New_Working => New_Working,
                        Result      => Entry_Stat,
                        Changed     => Changed);
                     if Is_Rename_Dest then
                        Entry_Stat.Old_Path := Rn.Source;
                        Entry_Stat.Rename_Score := Rn.Score;
                     end if;
                     if Changed or else Is_Rename_Dest then
                        Stats.Append (Entry_Stat);
                     end if;
                  end;
               else
                  Append
                    (Result,
                     One_File_Diff
                       (Repo        => Repo,
                        Cache       => Objects,
                        Path        => Path,
                        Old_Present => Src_E.Present or else Is_Rename_Dest,
                        Old_Id      => Src_E.Id,
                        Old_Mode    => To_String (Src_E.Mode),
                        New_Present => New_E.Present,
                        New_Id      => New_E.Id,
                        New_Mode    => To_String (New_E.Mode),
                        New_Working => New_Working,
                        Context     => Context,
                        Old_Path     =>
                          (if Is_Rename_Dest then Rn_Path else ""),
                        Rename_Score => Rn.Score,
                        Binary_Patch => Binary_Patch));
               end if;
            end;

            Path_Sets.Next (Cursor);
         end loop;
      end;

      if As_Stat then
         return Emit_Stat (Stats, Show_Stat => Stat, Show_Summary => Summary);
      end if;
      return To_String (Result);
   end Diff_Sides;

   function Diff_Working_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String
   is
   begin
      declare
         Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
         Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
           Version.Working_Tree.Scan
             (Repo => Repo, Ignore_Rules => Ignore, Tracked_Paths => Index);
      begin
         declare
            Objects : Version.Object_Cache.Object_Cache;
         begin
            return
              Diff_Sides
                (Repo        => Repo,
                 Objects     => Objects,
                 Old_Side    => From_Index (Index),
                 New_Side    => From_Working_For_Index (Working, Index),
                 New_Working => True,
                 Context     => Options.Context_Lines,
                 Stat        => Options.Stat,
                 Summary     => Options.Summary,
                 Name_Only   => Options.Name_Only,
                 Name_Status => Options.Name_Status,
                 Detect_Renames => Renames_Enabled (Repo, Options),
                 Rename_Score   => Options.Rename_Score,
                 Rename_Limit   => Options.Rename_Limit,
                 Binary_Patch   => Options.Binary_Patch);
         end;
      end;
   end Diff_Working_Tree;

   function Diff_Working_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
   begin
      declare
         Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
         Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
           Version.Working_Tree.Scan
             (Repo          => Repo,
              Ignore_Rules  => Ignore,
              Tracked_Paths => Index,
              Pathspecs     => Pathspecs);
      begin
         declare
            Objects : Version.Object_Cache.Object_Cache;
         begin
            return
              Diff_Sides
                (Repo        => Repo,
                 Objects     => Objects,
                 Old_Side    => Filter_Side (From_Index (Index), Pathspecs),
                 New_Side    =>
                   Filter_Side
                     (From_Working_For_Index (Working, Index), Pathspecs),
                 New_Working => True,
                 Context     => Options.Context_Lines,
                 Stat        => Options.Stat,
                 Summary     => Options.Summary,
                 Name_Only   => Options.Name_Only,
                 Name_Status => Options.Name_Status,
                 Detect_Renames => Renames_Enabled (Repo, Options),
                 Rename_Score   => Options.Rename_Score,
                 Rename_Limit   => Options.Rename_Limit,
                 Binary_Patch   => Options.Binary_Patch);
         end;
      end;
   end Diff_Working_Tree;

   function Diff_Staged
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String
   is
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                From_Tree
                  (Head_Tree
                     (Repo    => Repo,
                      Refs    => Refs,
                      Objects => Objects,
                      Trees   => Trees)),
              New_Side    => From_Index (Version.Staging.Load (Repo)),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Staged;

   function Diff_Staged
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Refs    : Version.Ref_Cache.Ref_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                Filter_Side
                  (From_Tree
                     (Head_Tree
                        (Repo    => Repo,
                         Refs    => Refs,
                         Objects => Objects,
                         Trees   => Trees)),
                   Pathspecs),
              New_Side    =>
                Filter_Side
                  (From_Index (Version.Staging.Load (Repo)), Pathspecs),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Staged;

   function Diff_Cached
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>)) return String is
   begin
      return Diff_Staged (Repo, Options);
   end Diff_Cached;

   function Diff_Cached
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String is
   begin
      return Diff_Staged (Repo, Pathspecs, Options);
   end Diff_Cached;

   function Diff_Tree_Vs_Working
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>)) return String
   is
      Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
      Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan
          (Repo => Repo, Ignore_Rules => Ignore, Tracked_Paths => Index);
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      return
        Diff_Sides
          (Repo        => Repo,
           Objects     => Objects,
           Old_Side    =>
             From_Tree
               (Version.Tree_Cache.Flatten_Tree
                  (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id)),
           New_Side    => From_Working_For_Index (Working, Index),
           New_Working => True,
           Context     => Options.Context_Lines,
           Stat        => Options.Stat, Summary => Options.Summary,
           Name_Only   => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch);
   end Diff_Tree_Vs_Working;

   function Diff_Tree_Vs_Index
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>)) return String
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      return
        Diff_Sides
          (Repo        => Repo,
           Objects     => Objects,
           Old_Side    =>
             From_Tree
               (Version.Tree_Cache.Flatten_Tree
                  (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id)),
           New_Side    => From_Index (Version.Staging.Load (Repo)),
           New_Working => False,
           Context     => Options.Context_Lines,
           Stat        => Options.Stat, Summary => Options.Summary,
           Name_Only   => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch);
   end Diff_Tree_Vs_Index;

   function Diff_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>)) return String
   is
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => Old_Id)),
              New_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => New_Id)),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Commits;

   function Diff_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : Version.Objects.Hex_Object_Id;
      New_Id    : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
   begin
      if Pathspecs.Is_Empty then
         return Diff_Commits (Repo, Old_Id, New_Id);
      end if;

      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => Old_Id)),
                   Pathspecs),
              New_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => New_Id)),
                   Pathspecs),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Commits;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Diff_Options := (others => <>)) return String
   is
      Empty : Side_Entry_Vectors.Vector;
   begin
      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    => Empty,
              New_Side    =>
                From_Tree
                  (Tree_For_Commit
                     (Repo      => Repo,
                      Objects   => Objects,
                      Trees     => Trees,
                      Commit_Id => Commit_Id)),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Root_Commit;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      Empty : Side_Entry_Vectors.Vector;
   begin
      if Pathspecs.Is_Empty then
         return Diff_Root_Commit (Repo, Commit_Id);
      end if;

      declare
         Objects : Version.Object_Cache.Object_Cache;
         Trees   : Version.Tree_Cache.Tree_Cache;
      begin
         return
           Diff_Sides
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    => Empty,
              New_Side    =>
                Filter_Side
                  (From_Tree
                     (Tree_For_Commit
                        (Repo      => Repo,
                         Objects   => Objects,
                         Trees     => Trees,
                         Commit_Id => Commit_Id)),
                   Pathspecs),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch);
      end;
   end Diff_Root_Commit;

   function Raw_Diff_Trees
     (Repo      : Version.Repository.Repository_Handle;
      Base      : Version.Objects.Hex_Object_Id;
      Has_Base  : Boolean;
      Target    : Version.Objects.Hex_Object_Id;
      Recursive : Boolean := True)
      return String
   is
      type Blob_Info is record
         Mode : Unbounded_String;
         Sha  : Unbounded_String;
      end record;

      package Entry_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Blob_Info);

      Target_Hex : constant String := Version.Objects.To_String (Target);
      Zeros      : constant String (1 .. Target_Hex'Length) := [others => '0'];

      function Pad6 (Mode : String) return String is
        ((1 .. 6 - Mode'Length => '0') & Mode);

      function Load (Tid : Version.Objects.Hex_Object_Id) return Entry_Maps.Map
      is
         M : Entry_Maps.Map;
      begin
         --  Recursive: flatten subtrees (only blobs/symlinks/gitlinks remain).
         --  Non-recursive: a changed subdirectory is a single 040000 entry.
         declare
            Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              (if Recursive then Version.Objects.Flatten_Tree (Repo, Tid)
               else Version.Objects.Tree_Entries (Repo, Tid));
         begin
            for E of Entries loop
               M.Include
                 (To_String (E.Path),
                  (Mode => E.Mode,
                   Sha  =>
                     To_Unbounded_String
                       (Version.Objects.To_String (E.Id))));
            end loop;
         end;
         return M;
      end Load;

      Base_Map   : constant Entry_Maps.Map :=
        (if Has_Base then Load (Base) else Entry_Maps.Empty_Map);
      Target_Map : constant Entry_Maps.Map := Load (Target);

      package Path_Sets is new
        Ada.Containers.Indefinite_Ordered_Sets (String);
      Paths  : Path_Sets.Set;
      Result : Unbounded_String;

      procedure Emit
        (Mode1, Mode2, Sha1, Sha2, Status, Path : String) is
      begin
         Append
           (Result,
            ":" & Mode1 & " " & Mode2 & " " & Sha1 & " " & Sha2 & " "
            & Status & Character'Val (9) & Path & Character'Val (10));
      end Emit;
   begin
      for C in Base_Map.Iterate loop
         Paths.Include (Entry_Maps.Key (C));
      end loop;
      for C in Target_Map.Iterate loop
         Paths.Include (Entry_Maps.Key (C));
      end loop;

      for Path of Paths loop
         declare
            In_Base   : constant Boolean := Base_Map.Contains (Path);
            In_Target : constant Boolean := Target_Map.Contains (Path);
         begin
            if In_Base and then In_Target then
               declare
                  B  : constant Blob_Info := Base_Map (Path);
                  Tg : constant Blob_Info := Target_Map (Path);
               begin
                  if B.Sha /= Tg.Sha or else B.Mode /= Tg.Mode then
                     Emit
                       (Pad6 (To_String (B.Mode)), Pad6 (To_String (Tg.Mode)),
                        To_String (B.Sha), To_String (Tg.Sha), "M", Path);
                  end if;
               end;
            elsif In_Base then
               declare
                  B : constant Blob_Info := Base_Map (Path);
               begin
                  Emit
                    (Pad6 (To_String (B.Mode)), "000000",
                     To_String (B.Sha), Zeros, "D", Path);
               end;
            else
               declare
                  Tg : constant Blob_Info := Target_Map (Path);
               begin
                  Emit
                    ("000000", Pad6 (To_String (Tg.Mode)),
                     Zeros, To_String (Tg.Sha), "A", Path);
               end;
            end if;
         end;
      end loop;

      return To_String (Result);
   end Raw_Diff_Trees;

   --  Shared helpers for the index/working raw diffs below.
   function Pad6 (Mode : String) return String is
     ((1 .. 6 - Mode'Length => '0') & Mode);

   function Working_Blob_Id
     (Repo : Version.Repository.Repository_Handle; Content : String)
      return String
   is
      Header : constant String :=
        "blob" & Natural'Image (Content'Length) & Character'Val (0);
   begin
      return Version.Hash.Object_Hash_Hex
        (Version.Repository.Algorithm (Repo), Header & Content);
   end Working_Blob_Id;

   package Raw_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);
   --  path -> "mode<HT>sha" (packed to keep one map type for both sides).

   function Raw_Diff_Index
     (Repo   : Version.Repository.Repository_Handle;
      Tree   : Version.Objects.Hex_Object_Id;
      Cached : Boolean)
      return String
   is
      Algo  : constant Version.Hash.Hash_Algorithm :=
        Version.Repository.Algorithm (Repo);
      Zeros : constant String (1 .. Version.Hash.Hex_Length (Algo)) :=
        [others => '0'];

      Tree_Mode : Raw_Maps.Map;
      Tree_Sha  : Raw_Maps.Map;
      Idx_Mode  : Raw_Maps.Map;   --  stage-0 index path -> mode
      Idx_Sha   : Raw_Maps.Map;   --  stage-0 index path -> sha

      package Path_Sets is new
        Ada.Containers.Indefinite_Ordered_Sets (String);
      Paths  : Path_Sets.Set;
      Result : Unbounded_String;

      procedure Emit (M1, M2, S1, S2, Status, Path : String) is
      begin
         Append
           (Result,
            ":" & M1 & " " & M2 & " " & S1 & " " & S2 & " " & Status
            & Character'Val (9) & Path & Character'Val (10));
      end Emit;
   begin
      for E of Version.Objects.Flatten_Tree (Repo, Tree) loop
         Tree_Mode.Include (To_String (E.Path), Pad6 (To_String (E.Mode)));
         Tree_Sha.Include
           (To_String (E.Path), Version.Objects.To_String (E.Id));
      end loop;

      for E of Version.Staging.Load (Repo) loop
         if E.Stage = 0 then
            Idx_Mode.Include
              (To_String (E.Path), Pad6 (To_String (E.Mode)));
            Idx_Sha.Include
              (To_String (E.Path), Version.Objects.To_String (E.Id));
         end if;
      end loop;

      for C in Tree_Mode.Iterate loop
         Paths.Include (Raw_Maps.Key (C));
      end loop;
      for C in Idx_Mode.Iterate loop
         Paths.Include (Raw_Maps.Key (C));
      end loop;

      for Path of Paths loop
         declare
            In_Tree : constant Boolean := Tree_Mode.Contains (Path);
            Tracked : constant Boolean := Idx_Mode.Contains (Path);
         begin
            if Cached then
               --  Compare the tree to the index directly.
               if In_Tree and then Tracked then
                  if Tree_Sha (Path) /= Idx_Sha (Path)
                    or else Tree_Mode (Path) /= Idx_Mode (Path)
                  then
                     Emit
                       (Tree_Mode (Path), Idx_Mode (Path),
                        Tree_Sha (Path), Idx_Sha (Path), "M", Path);
                  end if;
               elsif In_Tree then
                  Emit
                    (Tree_Mode (Path), "000000", Tree_Sha (Path), Zeros,
                     "D", Path);
               else
                  Emit
                    ("000000", Idx_Mode (Path), Zeros, Idx_Sha (Path),
                     "A", Path);
               end if;
            else
               --  Compare the tree to the working tree (git prints a zero id
               --  for the working side). Only tracked paths are considered.
               declare
                  W_Present : Boolean := False;
                  W_Id      : Unbounded_String;
               begin
                  if Tracked then
                     begin
                        W_Id :=
                          To_Unbounded_String
                            (Working_Blob_Id
                               (Repo, Working_Content (Repo, Path)));
                        W_Present := True;
                     exception
                        when others =>
                           W_Present := False;  --  file gone
                     end;
                  end if;

                  --  git prints the index sha when the working file still
                  --  matches the index (a staged change), and a zero id when
                  --  it differs from the index (an unstaged modification).
                  declare
                     --  The new side is the working file's mode, not the
                     --  index mode -- so an unstaged chmod is reported. A
                     --  gitlink keeps its 160000.
                     W_Mode : constant String :=
                       (if not W_Present then "000000"
                        elsif Tracked and then Idx_Mode (Path) = "160000"
                        then Idx_Mode (Path)
                        else Pad6 (Working_Disk_Mode (Repo, Path)));
                     --  git prints the index sha only when the working file is
                     --  fully up to date with the index (content AND mode); an
                     --  unstaged content or mode change prints a zero id.
                     Sha2 : constant String :=
                       (if W_Present and then Tracked
                          and then To_String (W_Id) = Idx_Sha (Path)
                          and then W_Mode = Idx_Mode (Path)
                        then Idx_Sha (Path) else Zeros);
                  begin
                     if In_Tree and then W_Present then
                        if To_String (W_Id) /= Tree_Sha (Path)
                          or else W_Mode /= Tree_Mode (Path)
                        then
                           Emit
                             (Tree_Mode (Path), W_Mode,
                              Tree_Sha (Path), Sha2, "M", Path);
                        end if;
                     elsif In_Tree then
                        --  In the tree but absent from the working tree.
                        Emit
                          (Tree_Mode (Path), "000000", Tree_Sha (Path), Zeros,
                           "D", Path);
                     elsif Tracked and then W_Present then
                        Emit
                          ("000000", W_Mode, Zeros, Sha2, "A", Path);
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;

      return To_String (Result);
   end Raw_Diff_Index;

   function Raw_Diff_Files
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String
   is
      Algo  : constant Version.Hash.Hash_Algorithm :=
        Version.Repository.Algorithm (Repo);
      Zeros : constant String (1 .. Version.Hash.Hex_Length (Algo)) :=
        [others => '0'];

      Mode_Map     : Raw_Maps.Map;   --  index (old) mode
      New_Mode_Map : Raw_Maps.Map;   --  working (new) mode
      Sha_Map      : Raw_Maps.Map;
      Del_Map      : Raw_Maps.Map;   --  path -> "1" when working file is gone

      package Path_Sets is new
        Ada.Containers.Indefinite_Ordered_Sets (String);
      Paths  : Path_Sets.Set;
      Result : Unbounded_String;
   begin
      for E of Version.Staging.Load (Repo) loop
         if E.Stage = 0 then
            declare
               Path : constant String := To_String (E.Path);
               ISha : constant String := Version.Objects.To_String (E.Id);
               IMode : constant String := Pad6 (To_String (E.Mode));
            begin
               begin
                  declare
                     WSha : constant String :=
                       Working_Blob_Id (Repo, Working_Content (Repo, Path));
                     --  A chmod is a change even with identical content; a
                     --  gitlink keeps its index mode (no worktree file mode).
                     WMode : constant String :=
                       (if To_String (E.Mode) = "160000" then IMode
                        else Pad6 (Working_Disk_Mode (Repo, Path)));
                  begin
                     if WSha /= ISha or else WMode /= IMode then
                        Mode_Map.Include (Path, IMode);
                        New_Mode_Map.Include (Path, WMode);
                        Sha_Map.Include (Path, ISha);
                        Paths.Include (Path);
                     end if;
                  end;
               exception
                  when others =>
                     Mode_Map.Include (Path, IMode);
                     Sha_Map.Include (Path, ISha);
                     Del_Map.Include (Path, "1");
                     Paths.Include (Path);
               end;
            end;
         end if;
      end loop;

      for Path of Paths loop
         if not Pathspecs.Is_Empty
           and then not Version.Pathspec.Matches_Any (Pathspecs, Path)
         then
            null;   --  filtered out by the pathspec
         elsif Del_Map.Contains (Path) then
            Append
              (Result,
               ":" & Mode_Map (Path) & " 000000 " & Sha_Map (Path) & " "
               & Zeros & " D" & Character'Val (9) & Path
               & Character'Val (10));
         else
            Append
              (Result,
               ":" & Mode_Map (Path) & " " & New_Mode_Map (Path) & " "
               & Sha_Map (Path) & " " & Zeros & " M" & Character'Val (9)
               & Path & Character'Val (10));
         end if;
      end loop;

      return To_String (Result);
   end Raw_Diff_Files;

   function Unified_Blob_Diff
     (Path        : String;
      Old_Text    : String;
      New_Text    : String;
      Old_Present : Boolean;
      New_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Id      : Version.Objects.Hex_Object_Id;
      Old_Mode    : String;
      New_Mode    : String;
      Context     : Natural := 3)
      return String
   is
   begin
      return Unified_File_Diff
        (Path        => Path,
         Old_Text    => Old_Text,
         New_Text    => New_Text,
         Old_Present => Old_Present,
         New_Present => New_Present,
         Old_Id      => Old_Id,
         New_Id      => New_Id,
         Old_Mode    => Old_Mode,
         New_Mode    => New_Mode,
         Context     => Context);
   end Unified_Blob_Diff;

   function Unified_Text_Diff
     (Path     : String;
      Old_Text : String;
      New_Text : String;
      Context  : Natural := 3) return String is
   begin
      return Unified_File_Diff
        (Path        => Path,
         Old_Text    => Old_Text,
         New_Text    => New_Text,
         Old_Present => True,
         New_Present => True,
         Old_Id      => Short_Zero,
         New_Id      => Short_Zero,
         Old_Mode    => "100644",
         New_Mode    => "100644",
         Context     => Context,
         Git_Header  => False);
   end Unified_Text_Diff;

end Version.Diff;
