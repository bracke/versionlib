with Ada.Containers;
use type Ada.Containers.Count_Type;
with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Version.Hash;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with GNAT.OS_Lib;
with GNAT.Regpat;

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
with Version.Attributes;
with Version.Submodules;
with Version.History;
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
      --  The content lives in the working tree (read by path, not by Id), so
      --  a side swap (-R) keeps reading it from disk.
      Working : Boolean := False;
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
   --  isspace() for the whitespace-error and funcname rules.
   function Is_WS (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.CR or else C = ASCII.VT or else C = ASCII.FF);

   --  xdiff's def_ff: a line that starts a "section" (function).
   function Is_Func_Line (L : String) return Boolean is
     (L'Length > 0
      and then L (L'First) in 'a' .. 'z' | 'A' .. 'Z' | '_' | '$');

   --  xdiff's is_empty_rec: nothing but whitespace.
   function Is_Blank_Line (L : String) return Boolean is
     (for all C of L => Is_WS (C));

   function Section_Heading
     (Old_Lines : Line_Vectors.Vector; Before : Natural) return String is
   begin
      for K in reverse 0 .. Before - 1 loop
         declare
            L : constant String :=
              To_String (Old_Lines.Element (Old_Lines.First_Index + K));
         begin
            if Is_Func_Line (L) then
               declare
                  --  def_ff copies at most 80 bytes, then trims blanks.
                  Last : Natural := Natural'Min (L'Last, L'First + 79);
               begin
                  while Last >= L'First and then Is_WS (L (Last)) loop
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
     (Old_Lines  : Line_Vectors.Vector;
      New_Lines  : Line_Vectors.Vector;
      Algorithm  : Version.Merge.Diff_Algorithm :=
        Version.Merge.Diff_Algorithm_Myers;
      Whitespace : Version.Merge.Whitespace_Mode :=
        Version.Merge.Whitespace_Strict;
      --  Whether each side's last line ends in a newline: an incomplete
      --  last line is a different record from the complete one (xdiff
      --  compares the terminator too).
      Old_NL     : Boolean := True;
      New_NL     : Boolean := True;
      Indent_Heuristic : Boolean := True) return Op_Vectors.Vector
   is
      LF : constant Character := Character'Val (10);
      use type Version.Merge.Diff_Algorithm;

      function Joined
        (Lines : Line_Vectors.Vector; Complete : Boolean) return String
      is
         Buf : Unbounded_String;
      begin
         for L of Lines loop
            Append (Buf, L);
            Append (Buf, LF);
         end loop;
         if not Complete and then Length (Buf) > 0 then
            Head (Buf, Length (Buf) - 1);
         end if;
         return To_String (Buf);
      end Joined;

      Changes : constant Version.Merge.Text_Change_Vectors.Vector :=
        Version.Merge.Text_Changes
          (Old_Text         => Joined (Old_Lines, Old_NL),
           New_Text         => Joined (New_Lines, New_NL),
           Algorithm        =>
             (if Algorithm = Version.Merge.Diff_Algorithm_Default
              then Version.Merge.Diff_Algorithm_Myers else Algorithm),
           Indent_Heuristic => Indent_Heuristic,
           Whitespace       => Whitespace);

      Ops : Op_Vectors.Vector;
      O   : Natural := 0;
      N   : Natural := 0;

      procedure Emit (Kind : Op_Kind; Text : Unbounded_String) is
      begin
         Ops.Append (Diff_Op'(Kind => Kind, Text => Text));
      end Emit;
   begin
      --  Context lines carry the new side's text: under a whitespace mode
      --  the two may differ, and git shows the post-image.
      for C of Changes loop
         while O < C.Old_First loop
            Emit (Op_Context, New_Lines.Element (N));
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
         Emit (Op_Context, New_Lines.Element (N));
         O := O + 1;
         N := N + 1;
      end loop;

      return Ops;
   end Diff_Ops;

   --  git's --word-diff body for one hunk: diff the pre-image against the
   --  post-image at word granularity and render the result. Old_Text/New_Text
   --  are the hunk's context+deleted and context+inserted lines (each ending
   --  in LF). A "word" is a maximal non-whitespace run; runs of whitespace and
   --  each newline are their own tokens so they diff and render like git's.
   function Word_Diff_Body
     (Old_Text, New_Text : String; Mode : Word_Diff_Kind) return String
   is
      LF     : constant Character := Character'Val (10);
      NL_Tok : constant String := Character'Val (1) & Character'Val (1);

      function Is_Space (C : Character) return Boolean is
        (C = ' ' or else C = Character'Val (9) or else C = Character'Val (13));

      function Tokenize (Text : String) return Line_Vectors.Vector is
         Result : Line_Vectors.Vector;
         I      : Positive := Text'First;
      begin
         while I <= Text'Last loop
            if Text (I) = LF then
               Result.Append (To_Unbounded_String (NL_Tok));
               I := I + 1;
            elsif Is_Space (Text (I)) then
               declare
                  J : Positive := I;
               begin
                  while J <= Text'Last and then Text (J) /= LF
                    and then Is_Space (Text (J))
                  loop
                     J := J + 1;
                  end loop;
                  Result.Append (To_Unbounded_String (Text (I .. J - 1)));
                  I := J;
               end;
            else
               declare
                  J : Positive := I;
               begin
                  while J <= Text'Last and then Text (J) /= LF
                    and then not Is_Space (Text (J))
                  loop
                     J := J + 1;
                  end loop;
                  Result.Append (To_Unbounded_String (Text (I .. J - 1)));
                  I := J;
               end;
            end if;
         end loop;
         return Result;
      end Tokenize;

      Ops    : constant Op_Vectors.Vector :=
        Diff_Ops (Tokenize (Old_Text), Tokenize (New_Text));
      Result : Unbounded_String;
   begin
      if Mode = WD_Porcelain then
         declare
            Ctx : Unbounded_String;   --  pending context words/spaces
            procedure Flush_Ctx is
            begin
               if Length (Ctx) > 0 then
                  Append (Result, " " & To_String (Ctx) & LF);
                  Ctx := Null_Unbounded_String;
               end if;
            end Flush_Ctx;
         begin
            for Op of Ops loop
               declare
                  T : constant String := To_String (Op.Text);
               begin
                  if T = NL_Tok then
                     Flush_Ctx;
                     Append (Result, "~" & LF);
                  elsif Op.Kind = Op_Context then
                     Append (Ctx, T);
                  elsif Op.Kind = Op_Delete then
                     Flush_Ctx;
                     Append (Result, "-" & T & LF);
                  else
                     Flush_Ctx;
                     Append (Result, "+" & T & LF);
                  end if;
               end;
            end loop;
            Flush_Ctx;
         end;
      else
         --  Plain: reconstruct each line, marking [-deleted-]{+inserted+}.
         declare
            Line : Unbounded_String;
            Pend_Del, Pend_Ins : Unbounded_String;
            procedure Flush_Changes is
            begin
               if Length (Pend_Del) > 0 then
                  Append (Line, "[-" & To_String (Pend_Del) & "-]");
                  Pend_Del := Null_Unbounded_String;
               end if;
               if Length (Pend_Ins) > 0 then
                  Append (Line, "{+" & To_String (Pend_Ins) & "+}");
                  Pend_Ins := Null_Unbounded_String;
               end if;
            end Flush_Changes;
         begin
            for Op of Ops loop
               declare
                  T : constant String := To_String (Op.Text);
               begin
                  if T = NL_Tok then
                     Flush_Changes;
                     Append (Result, To_String (Line) & LF);
                     Line := Null_Unbounded_String;
                  elsif Op.Kind = Op_Context then
                     Flush_Changes;
                     Append (Line, T);
                  elsif Op.Kind = Op_Delete then
                     Append (Pend_Del, T);
                  else
                     Append (Pend_Ins, T);
                  end if;
               end;
            end loop;
            Flush_Changes;
            if Length (Line) > 0 then
               Append (Result, To_String (Line) & LF);
            end if;
         end;
      end if;

      return To_String (Result);
   end Word_Diff_Body;

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

   --  A hunk, as the op indices it spans.
   type Hunk_Range is record
      First, Last : Natural;
   end record;
   package Hunk_Vectors is new
     Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Hunk_Range);

   --  xdiff's hunk assembly (xdl_get_hunk + the xdl_emit_diff loop with
   --  --function-context): which op ranges make up the hunks of Ops under
   --  Context, --inter-hunk-context, --ignore-blank-lines / -I and -W.  The
   --  patch and the stat both count from these, so a change the ignore
   --  rules drop is invisible to both.
   function Hunk_Ranges
     (Ops       : Op_Vectors.Vector;
      Old_Lines : Line_Vectors.Vector;
      New_Lines : Line_Vectors.Vector;
      Old_NL    : Boolean;
      New_NL    : Boolean;
      Context   : Natural;
      Opts      : Diff_Options) return Hunk_Vectors.Vector
   is
      use type Version.Merge.Whitespace_Mode;
      Old_Count : constant Natural := Natural (Old_Lines.Length);
      New_Count : constant Natural := Natural (New_Lines.Length);
      Num       : constant Natural := Natural (Ops.Length);
      Ranges    : Hunk_Vectors.Vector;

      type Nat_Array is array (Natural range <>) of Natural;
      Old_At : Nat_Array (0 .. Num);
      New_At : Nat_Array (0 .. Num);

      function Changed (K : Natural) return Boolean is
        (Ops.Element (K).Kind /= Op_Context);

      --  xdiff's xdchange_t: a run of changed ops, with the line ranges it
      --  covers on each side and whether --ignore-blank-lines / -I marked it
      --  ignorable (dropped unless another hunk's context reaches it).
      type Change_Rec is record
         First, Last        : Natural;
         I1, Chg1, I2, Chg2 : Natural;
         Ignore             : Boolean := False;
      end record;
      package Change_Vectors is new
        Ada.Containers.Vectors (Index_Type => Natural, Element_Type => Change_Rec);
      Changes : Change_Vectors.Vector;

      --  xdl_blankline: without a whitespace mode a line is blank when it is
      --  at most one byte long *including* its newline -- so an incomplete
      --  last line of a single byte counts too (git's quirk); with one, any
      --  whitespace-only line is.
      function Ignorable_Blank (K : Natural) return Boolean is
         Op : constant Diff_Op := Ops.Element (K);
         L  : constant String := To_String (Op.Text);
         Incomplete : constant Boolean :=
           (case Op.Kind is
               when Op_Delete  => not Old_NL and then Old_At (K + 1) = Old_Count,
               when Op_Insert  => not New_NL and then New_At (K + 1) = New_Count,
               when Op_Context => False);
      begin
         if Opts.Whitespace = Version.Merge.Whitespace_Strict then
            return L'Length + (if Incomplete then 0 else 1) <= 1;
         end if;
         return Is_Blank_Line (L);
      end Ignorable_Blank;

      function Matches_Ignore_Regex (L : String) return Boolean is
      begin
         for Pattern of Opts.Ignore_Regexes loop
            if GNAT.Regpat.Match (Pattern, L) then
               return True;
            end if;
         end loop;
         return False;
      end Matches_Ignore_Regex;

      function Change_Ignored (First, Last : Natural) return Boolean is
         Blank : Boolean := Opts.Ignore_Blank_Lines;
         Regex : Boolean := not Opts.Ignore_Regexes.Is_Empty;
      begin
         for K in First .. Last loop
            declare
               L : constant String := To_String (Ops.Element (K).Text);
            begin
               Blank := Blank and then Ignorable_Blank (K);
               Regex := Regex and then Matches_Ignore_Regex (L);
            end;
         end loop;
         return Blank or else Regex;
      end Change_Ignored;

      --  Hunk assembly (xdl_get_hunk): from change Start, the last change
      --  this hunk swallows; Start moves past leading ignorable changes that
      --  sit too far before anything else. Last is -1 when nothing remains.
      Max_Common    : constant Natural := 2 * Context + Opts.Inter_Hunk_Context;
      Max_Ignorable : constant Natural := Context;

      function Dist (P, C : Natural) return Natural is
        (Changes.Element (C).I1
         - (Changes.Element (P).I1 + Changes.Element (P).Chg1));

      procedure Get_Hunk (Start : in out Natural; Last : out Integer) is
         Count   : constant Natural := Natural (Changes.Length);
         S       : Natural := Start;
         P       : Natural := Start;
         L       : Natural;
         Ignored : Natural := 0;
      begin
         while P < Count and then Changes.Element (P).Ignore loop
            if P + 1 >= Count or else Dist (P, P + 1) >= Max_Ignorable then
               S := P + 1;
            end if;
            P := P + 1;
         end loop;
         Start := S;
         if S >= Count then
            Last := -1;
            return;
         end if;

         L := S;
         P := S;
         for C in S + 1 .. Count - 1 loop
            declare
               D : constant Natural := Dist (P, C);
               Ch : constant Change_Rec := Changes.Element (C);
            begin
               exit when D > Max_Common;
               if D < Max_Ignorable and then (not Ch.Ignore or else L = P) then
                  L := C;
                  Ignored := 0;
               elsif D < Max_Ignorable and then Ch.Ignore then
                  Ignored := Ignored + Ch.Chg2;
               elsif L /= P
                 and then Ch.I1 + Ignored
                          > Changes.Element (L).I1 + Changes.Element (L).Chg1
                            + Max_Common
               then
                  exit;
               elsif not Ch.Ignore then
                  L := C;
                  Ignored := 0;
               else
                  Ignored := Ignored + Ch.Chg2;
               end if;
               P := C;
            end;
         end loop;
         Last := L;
      end Get_Hunk;

      --  xdiff's get_func_line over the old side: the first line from Start
      --  towards Limit (exclusive) that starts a section, or -1.
      function Func_Line (Start, Limit : Integer) return Integer is
         Step : constant Integer := (if Start > Limit then -1 else 1);
         L    : Integer := Start;
      begin
         while L /= Limit and then L >= 0 and then L < Old_Count loop
            if Is_Func_Line (To_String (Old_Lines.Element (L))) then
               return L;
            end if;
            L := L + Step;
         end loop;
         return -1;
      end Func_Line;

      function Old_Blank (L : Natural) return Boolean is
        (Is_Blank_Line (To_String (Old_Lines.Element (L))));


      --  The op at which old line S1 / new line S2 starts, and the last op
      --  still inside old line E1 / new line E2.
      function Op_From (S1, S2 : Natural) return Natural is
      begin
         for K in 0 .. Num - 1 loop
            if Old_At (K) >= S1 and then New_At (K) >= S2 then
               return K;
            end if;
         end loop;
         return Num;
      end Op_From;

      function Op_To (E1, E2 : Natural) return Natural is
      begin
         for K in reverse 0 .. Num - 1 loop
            if Old_At (K + 1) <= E1 and then New_At (K + 1) <= E2 then
               return K;
            end if;
         end loop;
         return 0;
      end Op_To;
   begin
      Old_At (0) := 0;
      New_At (0) := 0;
      for K in 0 .. Num - 1 loop
         Old_At (K + 1) :=
           Old_At (K) + (if Ops.Element (K).Kind = Op_Insert then 0 else 1);
         New_At (K + 1) :=
           New_At (K) + (if Ops.Element (K).Kind = Op_Delete then 0 else 1);
      end loop;

      --  Group the changed ops into xdiff changes.
      declare
         K : Natural := 0;
      begin
         while K < Num loop
            if Changed (K) then
               declare
                  First : constant Natural := K;
               begin
                  while K + 1 < Num and then Changed (K + 1) loop
                     K := K + 1;
                  end loop;
                  Changes.Append
                    (Change_Rec'
                       (First  => First,
                        Last   => K,
                        I1     => Old_At (First),
                        Chg1   => Old_At (K + 1) - Old_At (First),
                        I2     => New_At (First),
                        Chg2   => New_At (K + 1) - New_At (First),
                        Ignore => Change_Ignored (First, K)));
               end;
            end if;
            K := K + 1;
         end loop;
      end;

      --  xdl_emit_diff's hunk loop.
      declare
         S : Natural := 0;
         E : Integer;
      begin
         while S < Natural (Changes.Length) loop
            Get_Hunk (S, E);
            exit when E < 0;

            declare
               Ch     : constant Change_Rec := Changes.Element (S);
               S1     : Integer := Integer'Max (Ch.I1 - Context, 0);
               S2     : Integer := Integer'Max (Ch.I2 - Context, 0);
               E1, E2 : Integer;
            begin
               if Opts.Function_Context then
                  declare
                     I1       : Integer := Ch.I1;
                     Whole    : Boolean := False;
                     FS1      : Integer;
                  begin
                     if I1 >= Old_Count then
                        --  Appended chunk: no pre-context when it adds a
                        --  whole function of its own.
                        for I2 in Ch.I2 .. New_Count - 1 loop
                           if Is_Func_Line (To_String (New_Lines.Element (I2)))
                           then
                              Whole := True;
                              exit;
                           end if;
                        end loop;
                        I1 := Old_Count - 1;
                     end if;
                     if not Whole then
                        FS1 := Func_Line (I1, -1);
                        while FS1 > 0
                          and then not Old_Blank (FS1 - 1)
                          and then not Is_Func_Line
                                         (To_String (Old_Lines.Element (FS1 - 1)))
                        loop
                           FS1 := FS1 - 1;
                        end loop;
                        if FS1 < 0 then
                           FS1 := 0;
                        end if;
                        if FS1 < S1 then
                           S2 := Integer'Max (S2 - (S1 - FS1), 0);
                           S1 := FS1;
                        end if;
                     end if;
                  end;
               end if;

               loop
                  declare
                     Last : constant Change_Rec := Changes.Element (E);
                     Lctx : Integer := Context;
                     Grow : Boolean := False;
                  begin
                     Lctx := Integer'Min (Lctx, Old_Count - (Last.I1 + Last.Chg1));
                     Lctx := Integer'Min (Lctx, New_Count - (Last.I2 + Last.Chg2));
                     E1 := Last.I1 + Last.Chg1 + Lctx;
                     E2 := Last.I2 + Last.Chg2 + Lctx;

                     if Opts.Function_Context then
                        declare
                           FE1 : Integer :=
                             Func_Line (Last.I1 + Last.Chg1, Old_Count);
                        begin
                           while FE1 > 0 and then Old_Blank (FE1 - 1) loop
                              FE1 := FE1 - 1;
                           end loop;
                           if FE1 < 0 then
                              FE1 := Old_Count;
                           end if;
                           if FE1 > E1 then
                              E2 := Integer'Min (E2 + (FE1 - E1), New_Count);
                              E1 := FE1;
                           end if;
                           --  Overlapping the next change: swallow it and
                           --  look for the end again.
                           if E + 1 < Natural (Changes.Length) then
                              declare
                                 L : constant Integer :=
                                   Integer'Min
                                     (Changes.Element (E + 1).I1, Old_Count - 1);
                              begin
                                 if L - Context <= E1
                                   or else Func_Line (L, E1) < 0
                                 then
                                    E := E + 1;
                                    Grow := True;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                     exit when not Grow;
                  end;
               end loop;

               Ranges.Append
                 (Hunk_Range'(First => Op_From (S1, S2), Last => Op_To (E1, E2)));
            end;
            S := E + 1;
         end loop;
      end;

      return Ranges;
   end Hunk_Ranges;

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
      Rename_Score : Natural := 0;
      Src_Prefix   : String := "a/";
      Dst_Prefix   : String := "b/";
      Word_Diff    : Word_Diff_Kind := WD_None;
      Opts         : Diff_Options := (others => <>)) return String
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
      Check : constant Boolean := Opts.Check_Whitespace;
      --  --check diffs with xdiff's flags cleared (no whitespace folding,
      --  no blank-line ignoring, no indent heuristic, Myers), keeping -I.
      Eff   : constant Diff_Options :=
        (if Check
         then (Opts with delta
                 Whitespace         => Version.Merge.Whitespace_Strict,
                 Ignore_Blank_Lines => False,
                 Indent_Heuristic   => False,
                 Algorithm          => Version.Merge.Diff_Algorithm_Myers)
         else Opts);
      Ops       : constant Op_Vectors.Vector :=
        Diff_Ops
          (Old_Lines, New_Lines, Eff.Algorithm, Eff.Whitespace,
           Old_NL => Old_NL or else Old_Count = 0,
           New_NL => New_NL or else New_Count = 0,
           Indent_Heuristic => Eff.Indent_Heuristic);
      Num       : constant Natural := Natural (Ops.Length);
      No_NL     : constant String := "\ No newline at end of file";

      Color : constant Boolean := Opts.Color;

      --  git's default palette (color.diff.*): meta bold, frag cyan, old
      --  red, new green, whitespace red background; plain/func/context
      --  are the terminal default, which still gets a reset.
      ESC     : constant String := [1 => Character'Val (27)];
      Reset   : constant String := (if Color then ESC & "[m" else "");
      Meta_C  : constant String := (if Color then ESC & "[1m" else "");
      Frag_C  : constant String := (if Color then ESC & "[36m" else "");
      Old_C   : constant String := (if Color then ESC & "[31m" else "");
      New_C   : constant String := (if Color then ESC & "[32m" else "");
      WS_C    : constant String := (if Color then ESC & "[41m" else "");

      procedure Meta_Line (S : String) is
      begin
         Append_Line (Result, Meta_C & S & Reset);
      end Meta_Line;

      --  The index line abbreviates to --abbrev (--full-index: all of it).
      function Abbrev (Id : Version.Objects.Hex_Object_Id) return String is
         Full : constant String := Version.Objects.To_String (Id);
         N    : constant Natural :=
           (if Opts.Index_Abbrev = 0 then 7
            else Natural'Min (Natural'Max (Opts.Index_Abbrev, 4), Full'Length));
      begin
         return Full (Full'First .. Full'First + N - 1);
      end Abbrev;

      type Nat_Array is array (Natural range <>) of Natural;
      Old_At : Nat_Array (0 .. Num);
      New_At : Nat_Array (0 .. Num);

      function Rng (Start, Cnt : Natural) return String is
        (if Cnt = 1 then Count_Image (Start + 1)
         elsif Cnt = 0 then Count_Image (Start) & ",0"
         else Count_Image (Start + 1) & "," & Count_Image (Cnt));


      --  git's ws_check_emit for the default core.whitespace rule
      --  (blank-at-eol, space-before-tab, blank-at-eof): the line painted in
      --  Set with its whitespace errors in WS_C, and which errors it has.
      type WS_Error is (WS_Trailing, WS_Space_Before_Tab);
      type WS_Errors is array (WS_Error) of Boolean;

      procedure WS_Check
        (L : String; Set : String; Emit : Boolean; Errors : out WS_Errors)
      is
         Trailing : Natural := L'Last + 1;
         Written  : Natural := L'First;
         I        : Natural := L'First;
      begin
         Errors := [others => False];
         while Trailing > L'First and then Is_WS (L (Trailing - 1)) loop
            Trailing := Trailing - 1;
            Errors (WS_Trailing) := True;
         end loop;

         while I < Trailing loop
            if L (I) = ' ' then
               I := I + 1;
            elsif L (I) /= ASCII.HT then
               exit;
            else
               if Written < I then
                  Errors (WS_Space_Before_Tab) := True;
                  if Emit then
                     Append (Result, WS_C & L (Written .. I - 1) & Reset);
                     Append (Result, L (I));
                  end if;
               elsif Emit then
                  Append (Result, L (Written .. I));
               end if;
               Written := I + 1;
               I := I + 1;
            end if;
         end loop;

         if Emit then
            if Trailing > Written then
               Append (Result, Set & L (Written .. Trailing - 1) & Reset);
            end if;
            if Trailing <= L'Last then
               Append (Result, WS_C & L (Trailing .. L'Last) & Reset);
            end if;
            Append (Result, Character'Val (10));
         end if;
      end WS_Check;

      --  check_blank_at_eof: the first line of each side from which the new
      --  side only adds blank lines at the end (0 when it adds none).
      function Trailing_Blank (Lines : Line_Vectors.Vector) return Natural is
         N : Natural := 0;
      begin
         for K in reverse 0 .. Natural (Lines.Length) - 1 loop
            exit when not Is_Blank_Line (To_String (Lines.Element (K)));
            N := N + 1;
         end loop;
         return N;
      end Trailing_Blank;

      Blank_EOF_Old : Natural := 0;
      Blank_EOF_New : Natural := 0;

      --  git's emit_line_0: the reset lands before a trailing CR.
      procedure Plain_Line (Set : String; Lead : Character; T : String) is
      begin
         if T'Length > 0 and then T (T'Last) = ASCII.CR then
            Append_Line
              (Result, Set & Lead & T (T'First .. T'Last - 1) & Reset & ASCII.CR);
         else
            Append_Line (Result, Set & Lead & T & Reset);
         end if;
      end Plain_Line;

      procedure Emit_Op (I : Natural) is
         Op   : constant Diff_Op := Ops.Element (I);
         T    : constant String := To_String (Op.Text);
         Lead : constant Character :=
           (case Op.Kind is
               when Op_Context => Opts.Indicator_Context,
               when Op_Delete  => Opts.Indicator_Old,
               when Op_Insert  => Opts.Indicator_New);
         Set  : constant String :=
           (case Op.Kind is
               when Op_Context => "",
               when Op_Delete  => Old_C,
               when Op_Insert  => New_C);
         Paint_WS : constant Boolean :=
           Color
           and then (case Op.Kind is
                        when Op_Context => Opts.WS_Errors.Context_Lines,
                        when Op_Delete  => Opts.WS_Errors.Old_Lines,
                        when Op_Insert  => Opts.WS_Errors.New_Lines);
         Errors : WS_Errors;
      begin
         if Check then
            if Op.Kind = Op_Insert then
               declare
                  Line_No : constant String := Count_Image (New_At (I) + 1);
                  Marker  : constant Boolean :=
                    T'Length >= 7
                    and then T (T'First) in '<' | '=' | '>' | '|'
                    and then (for all C of T (T'First .. T'First + 6)
                              => C = T (T'First))
                    and then (T'Length = 7
                              or else Is_WS (T (T'First + 7)));
                  Names : Unbounded_String;
               begin
                  if Marker then
                     Append_Line
                       (Result, Path & ":" & Line_No & ": leftover conflict marker");
                  end if;
                  WS_Check (T, "", Emit => False, Errors => Errors);
                  if Errors (WS_Trailing) then
                     Append (Names, "trailing whitespace");
                  end if;
                  if Errors (WS_Space_Before_Tab) then
                     if Length (Names) > 0 then
                        Append (Names, ", ");
                     end if;
                     Append (Names, "space before tab in indent");
                  end if;
                  if Length (Names) > 0 then
                     Append_Line
                       (Result, Path & ":" & Line_No & ": " & To_String (Names) & ".");
                     Append (Result, New_C & Lead & Reset);
                     WS_Check (T, New_C, Emit => True, Errors => Errors);
                  end if;
               end;
            end if;
            return;
         end if;

         if not Paint_WS then
            Plain_Line (Set, Lead, T);
         elsif Op.Kind = Op_Insert
           and then Blank_EOF_Old > 0
           and then Blank_EOF_Old <= Old_At (I) + 1
           and then Blank_EOF_New <= New_At (I) + 1
           and then Is_Blank_Line (T)
         then
            --  A blank line added at EOF: git paints the '+' as well.
            Plain_Line (WS_C, Lead, T);
         else
            Append (Result, Set & Lead & Reset);
            WS_Check (T, Set, Emit => True, Errors => Errors);
         end if;

         if Op.Kind = Op_Delete
           and then not Old_NL
           and then Old_At (I + 1) = Old_Count
           and then Old_Count > 0
         then
            Append_Line (Result, No_NL & Reset);
         elsif Op.Kind = Op_Insert
           and then not New_NL
           and then New_At (I + 1) = New_Count
           and then New_Count > 0
         then
            Append_Line (Result, No_NL & Reset);
         elsif Op.Kind = Op_Context and then I = Num - 1 then
            if not New_NL and then New_Count > 0 then
               Append_Line (Result, No_NL & Reset);
            elsif not Old_NL and then Old_Count > 0 then
               Append_Line (Result, No_NL & Reset);
            end if;
         end if;
      end Emit_Op;

      Hunks : Natural := 0;

      procedure Emit_Hunk (H_Start, H_End : Natural) is
         O_Start : constant Natural := Old_At (H_Start);
         N_Start : constant Natural := New_At (H_Start);
         O_Cnt   : constant Natural := Old_At (H_End + 1) - O_Start;
         N_Cnt   : constant Natural := New_At (H_End + 1) - N_Start;
         Head    : constant String := Section_Heading (Old_Lines, O_Start);
      begin
         Hunks := Hunks + 1;
         if Hunks = 1 and then not Check then
            --  The ---/+++ labels come with the first hunk (git prints
            --  neither for a file with nothing to show).
            Meta_Line
              ("--- "
               & (if Old_Present then Src_Prefix & Head_A else "/dev/null"));
            Meta_Line
              ("+++ " & (if New_Present then Dst_Prefix & Path else "/dev/null"));
         end if;
         if not Check then
            Append_Line
              (Result,
               Frag_C & "@@ -" & Rng (O_Start, O_Cnt)
               & " +" & Rng (N_Start, N_Cnt) & " @@" & Reset
               & (if Head'Length > 0 then " " & Reset & Head & Reset else ""));
         end if;

         if Word_Diff /= WD_None and then not Check then
            declare
               WLF     : constant Character := Character'Val (10);
               Old_Buf : Unbounded_String;
               New_Buf : Unbounded_String;
            begin
               for I in H_Start .. H_End loop
                  declare
                     Op : constant Diff_Op := Ops.Element (I);
                     T  : constant String := To_String (Op.Text) & WLF;
                  begin
                     if Op.Kind = Op_Context then
                        Append (Old_Buf, T);
                        Append (New_Buf, T);
                     elsif Op.Kind = Op_Delete then
                        Append (Old_Buf, T);
                     else
                        Append (New_Buf, T);
                     end if;
                  end;
               end loop;
               Append
                 (Result,
                  Word_Diff_Body
                    (To_String (Old_Buf), To_String (New_Buf), Word_Diff));
            end;
         else
            for I in H_Start .. H_End loop
               Emit_Op (I);
            end loop;
         end if;
      end Emit_Hunk;
   begin
      if Old_Text = New_Text and then Old_Present and then New_Present then
         return "";
      end if;

      --  Under --check a file is still dropped when the *requested* flags
      --  (-w, -b, ...) leave nothing to show; only the surviving files get
      --  the flag-free check.
      if Check
        and then Hunk_Ranges
                   (Diff_Ops
                      (Old_Lines, New_Lines, Opts.Algorithm, Opts.Whitespace,
                       Old_NL => Old_NL or else Old_Count = 0,
                       New_NL => New_NL or else New_Count = 0,
                       Indent_Heuristic => Opts.Indent_Heuristic),
                    Old_Lines, New_Lines, Old_NL, New_NL, Context, Opts)
                 .Is_Empty
      then
         return "";
      end if;

      if Git_Header and then not Check then
         Meta_Line
           ("diff --git " & Src_Prefix & Head_A & " " & Dst_Prefix & Path);
         if Old_Path'Length > 0 then
            --  git orders a rename header as mode lines, then the similarity
            --  block, then index.
            if Old_Mode /= New_Mode then
               Meta_Line ("old mode " & Old_Mode);
               Meta_Line ("new mode " & New_Mode);
            end if;
            Meta_Line
              ("similarity index "
               & Count_Image
                   (Version.Rename_Detect.Similarity_Index (Rename_Score))
               & "%");
            Meta_Line ("rename from " & Old_Path);
            Meta_Line ("rename to " & Path);
            Meta_Line
              ("index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id)
               & (if Old_Mode = New_Mode then " " & New_Mode else ""));
         elsif not Old_Present then
            Meta_Line ("new file mode " & New_Mode);
            Meta_Line ("index " & Abbrev (Short_Zero) & ".." & Abbrev (New_Id));
         elsif not New_Present then
            Meta_Line ("deleted file mode " & Old_Mode);
            Meta_Line ("index " & Abbrev (Old_Id) & ".." & Abbrev (Short_Zero));
         else
            --  A mode change alongside content is announced with old/new mode
            --  lines, and then the index line drops its trailing mode (git
            --  shows the mode only once); an unchanged mode stays on index.
            if Old_Mode /= New_Mode then
               Meta_Line ("old mode " & Old_Mode);
               Meta_Line ("new mode " & New_Mode);
               Meta_Line ("index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id));
            else
               Meta_Line
                 ("index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id)
                  & " " & New_Mode);
            end if;
         end if;
      end if;
      Old_At (0) := 0;
      New_At (0) := 0;
      for K in 0 .. Num - 1 loop
         Old_At (K + 1) :=
           Old_At (K) + (if Ops.Element (K).Kind = Op_Insert then 0 else 1);
         New_At (K + 1) :=
           New_At (K) + (if Ops.Element (K).Kind = Op_Delete then 0 else 1);
      end loop;


      declare
         L1 : constant Natural := Trailing_Blank (Old_Lines);
         L2 : constant Natural := Trailing_Blank (New_Lines);
      begin
         if L2 > L1 then
            Blank_EOF_Old := Old_Count - L1 + 1;
            Blank_EOF_New := New_Count - L2 + 1;
         end if;
      end;

      for H of Hunk_Ranges
        (Ops, Old_Lines, New_Lines, Old_NL, New_NL, Context, Eff)
      loop
         Emit_Hunk (H.First, H.Last);
      end loop;

      if Check and then Blank_EOF_New > 0 then
         Append_Line
           (Result,
            Path & ":" & Count_Image (Blank_EOF_New)
            & ": new blank line at EOF.");
      end if;

      --  git emits the header lazily with the first hunk: a file whose only
      --  differences the whitespace/blank/regex ignores fold away is not
      --  shown at all, unless its mode changed, it was renamed, or it
      --  appeared or disappeared.
      if Hunks = 0 and then Git_Header and then not Check
        and then Old_Present and then New_Present
        and then Old_Mode = New_Mode and then Old_Path'Length = 0
      then
         return "";
      end if;

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

   --  The `diff.<driver>.textconv` command for Path, from its `diff=<driver>`
   --  attribute; "" when there is none.
   function Textconv_Command
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      use type Version.Attributes.Attribute_State;
      Attr : constant Version.Attributes.Attribute_Result :=
        Version.Attributes.Lookup (Repo, Path, "diff");
   begin
      if Attr.State /= Version.Attributes.Attribute_Valued then
         return "";
      end if;
      declare
         Key : constant String :=
           "diff." & To_String (Attr.Value) & ".textconv";
      begin
         if Version.Config.Has_Key (Repo, Key) then
            return Version.Config.Get_Value (Repo, Key);
         end if;
         return "";
      end;
   end Textconv_Command;

   --  Run a textconv command on Content the way git does: the content lands
   --  in a temporary file whose path is the command's single argument, run
   --  through the shell; its stdout is the converted text.
   function Run_Textconv (Command : String; Content : String) return String is
      In_FD    : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
      In_Name  : GNAT.OS_Lib.String_Access;
      Out_FD   : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
      Out_Name : GNAT.OS_Lib.String_Access;
      Code     : Integer;
   begin
      GNAT.OS_Lib.Create_Temp_Output_File (In_FD, In_Name);
      GNAT.OS_Lib.Create_Temp_Output_File (Out_FD, Out_Name);
      if GNAT.OS_Lib."=" (In_FD, GNAT.OS_Lib.Invalid_FD)
        or else GNAT.OS_Lib."=" (Out_FD, GNAT.OS_Lib.Invalid_FD)
      then
         return Content;
      end if;
      Version.Files.Write_Binary_File (In_Name.all, Content);
      GNAT.OS_Lib.Close (In_FD);

      declare
         Args : GNAT.OS_Lib.Argument_List :=
           [new String'("-c"),
            new String'(Command & " ""$@"""),
            new String'(Command),
            new String'(In_Name.all)];
      begin
         GNAT.OS_Lib.Spawn
           (Program_Name           => "/bin/sh",
            Args                   => Args,
            Output_File_Descriptor => Out_FD,
            Return_Code            => Code,
            Err_To_Out             => False);
         for A of Args loop
            GNAT.OS_Lib.Free (A);
         end loop;
      end;
      GNAT.OS_Lib.Close (Out_FD);

      declare
         --  A converter that fails leaves the content as it was.
         Text : constant String :=
           (if Code = 0 then Version.Files.Read_Binary_File (Out_Name.all)
            else Content);
      begin
         Version.Files.Delete_File_If_Exists (In_Name.all);
         Version.Files.Delete_File_If_Exists (Out_Name.all);
         GNAT.OS_Lib.Free (In_Name);
         GNAT.OS_Lib.Free (Out_Name);
         return Text;
      end;
   end Run_Textconv;

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
      Binary_Patch : Boolean := False;
      As_Text      : Boolean := False;
      Src_Prefix   : String := "a/";
      Dst_Prefix   : String := "b/";
      Word_Diff    : Word_Diff_Kind := WD_None;
      Old_Working  : Boolean := False;
      Opts         : Diff_Options := (others => <>);
      --  How the paths are shown (--relative strips a prefix); the content
      --  is still read by Path/Old_Path.
      Shown        : String := "";
      Old_Shown    : String := "") return String
   is
      Disp     : constant String := (if Shown'Length > 0 then Shown else Path);
      Old_Disp : constant String :=
        (if Old_Shown'Length > 0 then Old_Shown else Old_Path);
      Head_A : constant String :=
        (if Old_Path'Length > 0 then Old_Disp else Disp);
      Check  : constant Boolean := Opts.Check_Whitespace;
      --  Header lines in git's bold "meta" color under --color.
      function Meta (S : String) return String is
        (if Opts.Color and then not Check
         then Character'Val (27) & "[1m" & S & Character'Val (27) & "[m"
         else S);
   begin
      if Check
        and then Old_Present and then New_Present and then Old_Id = New_Id
      then
         --  --check only looks at added lines; there are none here.
         return "";
      end if;

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
            Append_Line
              (R,
               Meta ("diff --git " & Src_Prefix & Head_A & " " & Dst_Prefix
                     & Disp));
            if Eff_Old /= Eff_New then
               Append_Line (R, Meta ("old mode " & Eff_Old));
               Append_Line (R, Meta ("new mode " & Eff_New));
            end if;
            if Old_Path'Length > 0 then
               Append_Line
                 (R,
                  Meta
                    ("similarity index "
                     & Count_Image
                         (Version.Rename_Detect.Similarity_Index
                            (Rename_Score))
                     & "%"));
               Append_Line (R, Meta ("rename from " & Old_Disp));
               Append_Line (R, Meta ("rename to " & Disp));
            end if;
            return To_String (R);
         end;
      end if;

      declare
         --  git's textconv: a `diff=<driver>` attribute whose
         --  `diff.<driver>.textconv` command turns each side into text.
         Textconv : constant String :=
           (if Opts.Textconv then Textconv_Command (Repo, Path) else "");
         function Converted (Text : String; Present : Boolean) return String is
           (if Present and then Textconv'Length > 0
            then Run_Textconv (Textconv, Text) else Text);
         Old_Text : constant String :=
           Converted
             ((if Old_Present and then Old_Working
                 and then not Is_Gitlink_Mode (Old_Mode)
               then Working_Content (Repo, Head_A)
               else Side_Content (Repo, Cache, Old_Present, Old_Id, Old_Mode)),
              Old_Present);
         New_Text : constant String :=
           Converted
             ((if not New_Present
               then ""
               elsif New_Working and then not Is_Gitlink_Mode (New_Mode)
               then Working_Content (Repo, Path)
               else Side_Content (Repo, Cache, New_Present, New_Id, New_Mode)),
              New_Present);
         Eff_Old_Mode : constant String :=
           (if Old_Mode'Length > 0 then Old_Mode else "100644");
         Eff_New_Mode : constant String :=
           (if New_Mode'Length > 0 then New_Mode else Eff_Old_Mode);
      begin
         if Check
           and then not As_Text and then Textconv'Length = 0
           and then (Contains_Nul (Old_Text) or else Contains_Nul (New_Text))
         then
            return "";
         end if;

         if not As_Text and then Textconv'Length = 0
           and then (Contains_Nul (Old_Text) or else Contains_Nul (New_Text))
         then
            declare
               R : Unbounded_String;
            begin
               --  git prints the unabbreviated index with --binary: the
               --  patch has to name the blobs exactly.
               declare
                  function Ix (Id : Version.Objects.Hex_Object_Id)
                    return String
                  is
                     Full : constant String := Version.Objects.To_String (Id);
                     N    : constant Natural :=
                       (if Binary_Patch then Full'Length
                        elsif Opts.Index_Abbrev = 0 then 7
                        else Natural'Min
                               (Natural'Max (Opts.Index_Abbrev, 4),
                                Full'Length));
                  begin
                     return Full (Full'First .. Full'First + N - 1);
                  end Ix;
               begin
                  Append_Line
                    (R,
                     Meta ("diff --git "
                           & Src_Prefix & Head_A & " " & Dst_Prefix & Disp));
                  if Old_Path'Length > 0 then
                     Append_Line
                       (R,
                        Meta ("similarity index "
                              & Count_Image
                                  (Version.Rename_Detect.Similarity_Index
                                     (Rename_Score))
                              & "%"));
                     Append_Line (R, Meta ("rename from " & Old_Disp));
                     Append_Line (R, Meta ("rename to " & Disp));
                     Append_Line
                       (R,
                        Meta ("index " & Ix (Old_Id) & ".." & Ix (New_Id)
                              & (if Eff_Old_Mode = Eff_New_Mode
                                 then " " & Eff_New_Mode else "")));
                  elsif not Old_Present then
                     Append_Line (R, Meta ("new file mode " & Eff_New_Mode));
                     Append_Line
                       (R,
                        Meta ("index " & Ix (Short_Zero) & ".." & Ix (New_Id)));
                  elsif not New_Present then
                     Append_Line (R, Meta ("deleted file mode " & Eff_Old_Mode));
                     Append_Line
                       (R,
                        Meta ("index " & Ix (Old_Id) & ".." & Ix (Short_Zero)));
                  else
                     Append_Line
                       (R,
                        Meta ("index " & Ix (Old_Id) & ".." & Ix (New_Id)
                              & " " & Eff_New_Mode));
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
                     & (if Old_Present then Src_Prefix & Head_A
                        else "/dev/null")
                     & " and "
                     & (if New_Present then Dst_Prefix & Disp else "/dev/null")
                     & " differ");
               end if;
               return To_String (R);
            end;
         end if;

         return
           Unified_File_Diff
             (Path        => Disp,
              Old_Text    => Old_Text,
              New_Text    => New_Text,
              Old_Present => Old_Present,
              New_Present => New_Present,
              Old_Id      => Old_Id,
              New_Id      => New_Id,
              Old_Mode    => Eff_Old_Mode,
              New_Mode    => Eff_New_Mode,
              Context     => Context,
              Old_Path     => Old_Disp,
              Rename_Score => Rename_Score,
              Src_Prefix   => Src_Prefix,
              Dst_Prefix   => Dst_Prefix,
              Word_Diff    => Word_Diff,
              Opts         => Opts);
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

   --  An intent-to-add entry is not in the index as far as a diff is
   --  concerned (git's default; `--ita-visible-in-index` keeps it, as an
   --  empty blob).
   function From_Index
     (Entries     : Version.Staging.Index_Entry_Vectors.Vector;
      Ita_Visible : Boolean := False)
      return Side_Entry_Vectors.Vector
   is
      Result : Side_Entry_Vectors.Vector;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            if Entries.Element (I).Stage = 0
              and then (Ita_Visible
                        or else not Entries.Element (I).Intent_To_Add)
            then
               Result.Append
                 (Side_Entry'
                    (Path    => Entries.Element (I).Path,
                     Id      => Entries.Element (I).Id,
                     Mode    => Entries.Element (I).Mode,
                     Present => True,
                     Working => False));
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
                  Present => True,
                  Working => True));
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
                  Present => True,
                  Working => False));
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
      Changed     : out Boolean;
      Old_Working : Boolean := False;
      Opts        : Diff_Options := (others => <>)) is
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
         Textconv : constant String :=
           (if Opts.Textconv then Textconv_Command (Repo, Path) else "");
         function Converted (Text : String; Present : Boolean) return String is
           (if Present and then Textconv'Length > 0
            then Run_Textconv (Textconv, Text) else Text);
         Old_Text : constant String :=
           Converted
             ((if Old_Present and then Old_Working
                 and then not Is_Gitlink_Mode (Old_Mode)
               then Working_Content (Repo, Path)
               else Side_Content (Repo, Cache, Old_Present, Old_Id, Old_Mode)),
              Old_Present);
         New_Text : constant String :=
           Converted
             ((if not New_Present
               then ""
               elsif New_Working and then not Is_Gitlink_Mode (New_Mode)
               then Working_Content (Repo, Path)
               else Side_Content (Repo, Cache, New_Present, New_Id, New_Mode)),
              New_Present);
      begin
         if Old_Text = New_Text then
            return;
         end if;
         Changed := True;

         if not Opts.Diff_Text and then Textconv'Length = 0
           and then (Contains_Nul (Old_Text) or else Contains_Nul (New_Text))
         then
            Result.Binary   := True;
            Result.Old_Size := Old_Text'Length;
            Result.New_Size := New_Text'Length;
            return;
         end if;

         declare
            Old_Lines : constant Line_Vectors.Vector := Split_Lines (Old_Text);
            New_Lines : constant Line_Vectors.Vector := Split_Lines (New_Text);
            Old_NL    : constant Boolean :=
              Ends_With_Newline (Old_Text) or else Old_Text = "";
            New_NL    : constant Boolean :=
              Ends_With_Newline (New_Text) or else New_Text = "";
            Ops : constant Op_Vectors.Vector :=
              Diff_Ops
                (Old_Lines, New_Lines, Opts.Algorithm, Opts.Whitespace,
                 Old_NL => Old_NL, New_NL => New_NL,
                 Indent_Heuristic => Opts.Indent_Heuristic);
            Hunks : constant Hunk_Vectors.Vector :=
              Hunk_Ranges
                (Ops, Old_Lines, New_Lines, Old_NL, New_NL,
                 Opts.Context_Lines, Opts);
         begin
            --  git counts the lines its hunks would show, so a change the
            --  whitespace or ignore rules fold away counts for nothing --
            --  and a file left with no hunks is not listed at all.
            for H of Hunks loop
               for K in H.First .. H.Last loop
                  case Ops.Element (K).Kind is
                     when Op_Insert  => Result.Ins := Result.Ins + 1;
                     when Op_Delete  => Result.Del := Result.Del + 1;
                     when Op_Context => null;
                  end case;
               end loop;
            end loop;
            if Hunks.Is_Empty and then Old_Present and then New_Present then
               Changed := Result.Old_Mode /= Result.New_Mode;
            end if;
         end;
      end;
   end One_File_Stat;

   --  Render git's `--stat` block (per-file change bars + a "N files changed"
   --  footer) when Show_Stat, followed by git's `--summary` lines
   --  (create/delete mode, mode change) when Show_Summary.
   function Emit_Stat
     (Files           : Stat_Vectors.Vector;
      Show_Stat       : Boolean;
      Show_Summary    : Boolean;
      Show_Numstat    : Boolean := False;
      Show_Shortstat  : Boolean := False;
      Min_Count_Width : Natural := 0;
      Apply_Style     : Boolean := False;
      Compact         : Boolean := False;
      Stat_Width      : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Color           : Boolean := False) return String
   is
      ESC   : constant String := [1 => Character'Val (27)];
      Reset : constant String := (if Color then ESC & "[m" else "");
      Add_C : constant String := (if Color then ESC & "[32m" else "");
      Del_C : constant String := (if Color then ESC & "[31m" else "");
      --  A run of stat bars (or a byte count) in its color; nothing at all
      --  when empty, as git paints only what it prints.
      function Painted (Set : String; Text : String) return String is
        (if Text'Length = 0 then "" else Set & Text & Reset);

      --  `git --compact-summary` annotates the name column: "(new)"/"(gone)"
      --  for a created/deleted file and "(mode +x)"/"(mode -x)" for an exec
      --  bit change (a rename keeps its "old => new" with no annotation).
      function Annotation (F : Stat_Entry) return String is
        (if not Compact or else Is_Rename (F) then ""
         elsif not F.Old_Present then
           " (new"
           & (if To_String (F.New_Mode) = "100755" then " +x"
              elsif To_String (F.New_Mode) = "120000" then " +l" else "")
           & ")"
         elsif not F.New_Present then " (gone)"
         elsif F.Old_Mode /= F.New_Mode then
           " (mode "
           & (if To_String (F.New_Mode) = "100755" then "+x"
              elsif To_String (F.Old_Mode) = "100755" then "-x"
              else "changed")
           & ")"
         else "");

      --  `git apply --stat` differs from a diffstat: a rename is shown by its
      --  destination path alone (no "old => new"), a binary file is just "Bin"
      --  with no byte counts, and the graph separator space follows the count
      --  even when nothing changed.
      function Disp_Name (F : Stat_Entry) return String is
        (if Apply_Style then To_String (F.Path)
         else Stat_Name (F) & Annotation (F));

      --  apply --stat sizes the name column from the rename's source path even
      --  though it shows only the destination -- git's own quirk.
      function Width_Name (F : Stat_Entry) return String is
        (if Apply_Style and then Is_Rename (F)
           and then Length (F.Old_Path) > Length (F.Path)
         then To_String (F.Old_Path) else Disp_Name (F));
      Result    : Unbounded_String;
      Name_W    : Natural := 0;
      Count_W   : Natural := 0;
      Total_Ins : Natural := 0;
      Total_Del : Natural := 0;
      Shown     : Natural := 0;   --  files printed so far (for --stat-count)
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
      --  --numstat: one "<added>\t<deleted>\t<path>" per file, tabs not
      --  bars, and a binary file shows "-\t-". No footer.
      if Show_Numstat then
         declare
            Out_Text : Unbounded_String;
            Tab : constant String := [1 => Character'Val (9)];
            Nl  : constant String := [1 => Character'Val (10)];
         begin
            for I in Files.First_Index .. Files.Last_Index loop
               declare
                  F : constant Stat_Entry := Files.Element (I);
               begin
                  if F.Binary then
                     Append
                       (Out_Text, "-" & Tab & "-" & Tab & Disp_Name (F) & Nl);
                  else
                     Append
                       (Out_Text,
                        Count_Image (F.Ins) & Tab & Count_Image (F.Del) & Tab
                        & Disp_Name (F) & Nl);
                  end if;
               end;
            end loop;
            return To_String (Out_Text);
         end;
      end if;

      if Files.Is_Empty then
         --  `git apply --stat` still prints its footer for an empty patch
         --  (e.g. everything filtered by --include); a plain diffstat does not.
         if Apply_Style and then Show_Stat then
            return " 0 files changed" & LF;
         end if;
         return "";
      end if;

      --  With --stat-count only the first N files are printed, so git sizes the
      --  name and graph columns from just those; the footer totals below still
      --  sum every file.
      declare
         Shown_Limit : constant Natural :=
           (if Stat_Count > 0 and then Stat_Count < Natural (Files.Length)
            then Stat_Count else Natural (Files.Length));
         Idx : Natural := 0;
      begin
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               F : constant Stat_Entry := Files.Element (I);
            begin
               Idx := Idx + 1;
               if not F.Binary then
                  Total_Ins := Total_Ins + F.Ins;
                  Total_Del := Total_Del + F.Del;
               end if;
               if Idx <= Shown_Limit then
                  Name_W := Natural'Max (Name_W, Width_Name (F)'Length);
                  if F.Binary then
                     --  "Bin XXX -> YYY bytes" is not scaled, but it does set
                     --  the width the graph column has to accommodate.
                     Bin_W :=
                       Natural'Max
                         (Bin_W,
                          14 + Count_Image (F.Old_Size)'Length
                          + Count_Image (F.New_Size)'Length);
                     Count_W := Natural'Max (Count_W, 3);
                  else
                     Max_Change := Natural'Max (Max_Change, F.Ins + F.Del);
                  end if;
               end if;
            end;
         end loop;
      end;

      --  git's --stat-name-width (the second field of --stat=W,N) caps the name
      --  column: a shorter name column is honoured, but it never widens past the
      --  longest name actually shown; the print loop elides names over the cap.
      if Stat_Name_Width > 0 and then Stat_Name_Width < Name_W then
         Name_W := Stat_Name_Width;
      end if;

      Count_W :=
        Natural'Max (Count_W, Count_Image (Max_Change)'Length);
      --  `git apply --stat` pads the count column to a wider minimum than a
      --  plain diffstat does.
      Count_W := Natural'Max (Count_W, Min_Count_Width);

      --  git's width budget: name + number + 6 constant columns + graph.
      --  `--stat=<width>` fixes the total width instead of the terminal's.
      Width := (if Stat_Width > 0 then Stat_Width else Term_Columns);
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

      if Show_Stat or else Show_Shortstat then
         --  --shortstat prints only the "N files changed" footer, so the
         --  per-file bar loop is skipped; the totals it needs were summed
         --  in the pre-pass above.
         for I in Files.First_Index .. Files.Last_Index loop
           if Show_Stat
             and then (Stat_Count = 0 or else Shown < Stat_Count)
           then
            Shown := Shown + 1;
            declare
               F    : constant Stat_Entry := Files.Element (I);
               Full : constant String := Disp_Name (F);

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
                        & Bin
                        --  apply --stat knows no sizes, so it stops at "Bin".
                        & (if Apply_Style then ""
                           else " " & Painted (Del_C, Count_Image (F.Old_Size))
                                & " -> "
                                & Painted (Add_C, Count_Image (F.New_Size))
                                & " bytes")
                        & LF);
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
                        --  there are bars (a pure rename shows a bare "0");
                        --  apply --stat always leaves the trailing space.
                        & (if Apply_Style or else F.Ins + F.Del > 0 then " "
                           else "")
                        & Painted (Add_C, Repeat ('+', Add))
                        & Painted (Del_C, Repeat ('-', Del_N)) & LF);
                  end;
               end if;
            end;
           end if;
         end loop;

         --  git caps the per-file lines at --stat-count and marks the rest with
         --  a lone " ..." line; the footer still counts every file.
         if Show_Stat and then Stat_Count > 0
           and then Stat_Count < Natural (Files.Length)
         then
            Append (Result, " ..." & LF);
         end if;

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

   function Summarize_Patch
     (Patch : String;
      Mode  : Patch_Summary_Mode) return String
   is
      NL : constant Character := Character'Val (10);

      Files   : Stat_Vectors.Vector;

      First : Natural := Patch'First;

      function Line_At (P : Natural; Last : out Natural) return String is
      begin
         Last := P;
         while Last <= Patch'Last and then Patch (Last) /= NL loop
            Last := Last + 1;
         end loop;
         return Patch (P .. Last - 1);
      end Line_At;

      --  The "b/<path>" of a "diff --git a/x b/y" header, which is the name
      --  git reports (the destination side).
      function Dest_Path (Header : String) return String is
         B : constant Natural :=
           Ada.Strings.Fixed.Index (Header, " b/");
      begin
         if B = 0 then
            return "";
         end if;
         return Header (B + 3 .. Header'Last);
      end Dest_Path;

      function Starts (L, Prefix : String) return Boolean is
        (L'Length >= Prefix'Length
         and then L (L'First .. L'First + Prefix'Length - 1) = Prefix);

      Current : Stat_Entry;
      Have    : Boolean := False;

      procedure Flush is
      begin
         if Have then
            Files.Append (Current);
            Have := False;
         end if;
      end Flush;
   begin
      while First <= Patch'Last loop
         declare
            Last : Natural;
            L    : constant String := Line_At (First, Last);
         begin
            if Starts (L, "diff --git ") then
               Flush;
               Current :=
                 (Path        => To_Unbounded_String (Dest_Path (L)),
                  others      => <>);
               Current.Old_Present := True;
               Current.New_Present := True;
               Have := True;

            elsif Have and then Starts (L, "new file mode ") then
               Current.Old_Present := False;
               Current.New_Mode :=
                 To_Unbounded_String (L (L'First + 14 .. L'Last));

            elsif Have and then Starts (L, "deleted file mode ") then
               Current.New_Present := False;
               Current.Old_Mode :=
                 To_Unbounded_String (L (L'First + 18 .. L'Last));

            elsif Have and then Starts (L, "old mode ") then
               Current.Old_Mode :=
                 To_Unbounded_String (L (L'First + 9 .. L'Last));

            elsif Have and then Starts (L, "new mode ") then
               Current.New_Mode :=
                 To_Unbounded_String (L (L'First + 9 .. L'Last));

            elsif Have and then (Starts (L, "rename from ")
                                 or else Starts (L, "copy from "))
            then
               Current.Old_Path :=
                 To_Unbounded_String
                   (L (L'First + (if Starts (L, "rename from ") then 12
                                  else 10) .. L'Last));

            elsif Have and then (Starts (L, "rename to ")
                                 or else Starts (L, "copy to "))
            then
               Current.Path :=
                 To_Unbounded_String
                   (L (L'First + (if Starts (L, "rename to ") then 10
                                  else 8) .. L'Last));

            elsif Have and then Starts (L, "similarity index ")
              and then L (L'Last) = '%'
            then
               Current.Rename_Score :=
                 Natural'Value (L (L'First + 17 .. L'Last - 1))
                 * Version.Rename_Detect.Max_Score / 100;

            elsif Have
              and then (Starts (L, "Binary files ")
                        or else Starts (L, "GIT binary "))
            then
               Current.Binary := True;

            elsif Have and then Starts (L, "--- ") then
               null;   --  the old-file header, not a deletion

            elsif Have and then Starts (L, "+++ ") then
               null;   --  the new-file header, not an insertion

            elsif Have and then L'Length >= 1 and then L (L'First) = '+' then
               Current.Ins := Current.Ins + 1;

            elsif Have and then L'Length >= 1 and then L (L'First) = '-' then
               Current.Del := Current.Del + 1;
            end if;

            First := Last + 1;
         end;
      end loop;
      Flush;

      case Mode is
         when Summary_Names =>
            return Emit_Stat
              (Files, Show_Stat => False, Show_Summary => True);

         when Summary_Numstat =>
            return Emit_Stat
              (Files, Show_Stat => False, Show_Summary => False,
               Show_Numstat => True, Apply_Style => True);

         when Summary_Stat =>
            return Emit_Stat
              (Files, Show_Stat => True, Show_Summary => False,
               Min_Count_Width => 4, Apply_Style => True);

         when Summary_Diffstat =>
            return Emit_Stat
              (Files, Show_Stat => True, Show_Summary => False);

         when Summary_Shortstat =>
            return Emit_Stat
              (Files, Show_Stat => False, Show_Summary => False,
               Show_Shortstat => True);
      end case;
   end Summarize_Patch;

   package Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  git's diffcore-order: the paths in Paths, those matching an earlier
   --  pattern of the order file first (a pattern also matches any leading
   --  directory of a path); the rest keep their order.  Blank lines and
   --  `#` comments in the file are skipped.
   function Ordered_Paths
     (Repo       : Version.Repository.Repository_Handle;
      Paths      : Path_Sets.Map;
      Order_File : String) return Path_Vectors.Vector
   is
      Result   : Path_Vectors.Vector;
      Patterns : Path_Vectors.Vector;
   begin
      for C in Paths.Iterate loop
         Result.Append (Path_Sets.Key (C));
      end loop;
      if Order_File'Length = 0 then
         return Result;
      end if;

      declare
         Text : constant String :=
           Version.Files.Read_Binary_File
             (if GNAT.OS_Lib.Is_Absolute_Path (Order_File) then Order_File
              else Version.Files.Join
                     (Version.Repository.Root_Path (Repo), Order_File));
         Start : Natural := Text'First;
      begin
         while Start <= Text'Last loop
            declare
               Stop : Natural := Start;
            begin
               while Stop <= Text'Last and then Text (Stop) /= ASCII.LF loop
                  Stop := Stop + 1;
               end loop;
               declare
                  Line : constant String := Text (Start .. Stop - 1);
               begin
                  if Line'Length > 0 and then Line (Line'First) /= '#' then
                     Patterns.Append (Line);
                  end if;
               end;
               Start := Stop + 1;
            end;
         end loop;
      end;

      declare
         function Rank (Path : String) return Natural is
            Last : Natural;
         begin
            for I in Patterns.First_Index .. Patterns.Last_Index loop
               Last := Path'Last;
               loop
                  if Version.Ignore.Wildcard_Matches
                       (Patterns.Element (I), Path (Path'First .. Last))
                  then
                     return I;
                  end if;
                  while Last >= Path'First and then Path (Last) /= '/' loop
                     Last := Last - 1;
                  end loop;
                  exit when Last < Path'First;
                  Last := Last - 1;
               end loop;
            end loop;
            return Natural (Patterns.Length) + 1;
         end Rank;

         Sorted : Path_Vectors.Vector;
         Ranks  : array (1 .. Natural (Result.Length)) of Natural;
      begin
         for I in Ranks'Range loop
            Ranks (I) := Rank (Result.Element (I));
         end loop;
         for R in 1 .. Natural (Patterns.Length) + 1 loop
            for I in Ranks'Range loop
               if Ranks (I) = R then
                  Sorted.Append (Result.Element (I));
               end if;
            end loop;
         end loop;
         return Sorted;
      end;
   end Ordered_Paths;

   --  `diff.algorithm`, or Myers.
   function Configured_Algorithm
     (Repo : Version.Repository.Repository_Handle)
      return Version.Merge.Diff_Algorithm
   is
      Text : constant String :=
        (if Version.Config.Has_Key (Repo, "diff.algorithm")
         then Ada.Characters.Handling.To_Lower
                (Version.Config.Get_Value (Repo, "diff.algorithm"))
         else "");
   begin
      if Text = "patience" then
         return Version.Merge.Diff_Algorithm_Patience;
      elsif Text = "histogram" then
         return Version.Merge.Diff_Algorithm_Histogram;
      elsif Text = "minimal" then
         return Version.Merge.Diff_Algorithm_Minimal;
      else
         return Version.Merge.Diff_Algorithm_Myers;
      end if;
   end Configured_Algorithm;

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
      Numstat     : Boolean := False;
      Shortstat   : Boolean := False;
      Raw         : Boolean := False;
      Abbrev      : Natural := 7;
      Compact     : Boolean := False;
      Stat_Width  : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Filter : String := "";
      Detect_Renames : Boolean := False;
      Rename_Score   : Natural := 0;
      Rename_Limit   : Natural := 0;
      Binary_Patch   : Boolean := False;
      Text           : Boolean := False;
      Src_Prefix     : String := "a/";
      Dst_Prefix     : String := "b/";
      Word_Diff      : Word_Diff_Kind := WD_None;
      Opts           : Diff_Options := (others => <>)) return String;

   --  git's --submodule=log / --submodule=diff block for a gitlink pair
   --  (submodule.c show_submodule_header + the summary or inline diff).
   function Submodule_Block
     (Repo        : Version.Repository.Repository_Handle;
      Path        : String;
      Shown       : String;
      Old_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Present : Boolean;
      New_Id      : Version.Objects.Hex_Object_Id;
      Opts        : Diff_Options) return String
   is
      ESC    : constant String := [1 => Character'Val (27)];
      Reset  : constant String := (if Opts.Color then ESC & "[m" else "");
      Old_C  : constant String := (if Opts.Color then ESC & "[31m" else "");
      New_C  : constant String := (if Opts.Color then ESC & "[32m" else "");
      LF     : constant Character := Character'Val (10);

      function Ab (Present : Boolean; Id : Version.Objects.Hex_Object_Id)
        return String
      is (if Present then Abbrev (Id) else Abbrev (Short_Zero));

      function Sub_Git_Dir return String is
      begin
         return Version.Submodules.Resolved_Submodule_Git_Dir (Repo, Path);
      exception
         when others =>
            return "";
      end Sub_Git_Dir;

      Git_Dir : constant String := Sub_Git_Dir;
      Message : Unbounded_String;
      Fast_Forward, Fast_Backward : Boolean := False;
      Result  : Unbounded_String;
      Have_Sub : Boolean := False;
      Sub      : Version.Repository.Repository_Handle;
   begin
      if Git_Dir'Length > 0 then
         begin
            Sub := Version.Repository.Open_Git_Dir (Git_Dir);
            Have_Sub := True;
         exception
            when others =>
               Have_Sub := False;
         end;
      end if;

      if not Old_Present then
         Message := To_Unbounded_String ("(new submodule)");
      elsif not New_Present then
         Message := To_Unbounded_String ("(submodule deleted)");
      elsif not Have_Sub then
         Message := To_Unbounded_String ("(commits not present)");
      else
         begin
            declare
               L : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Sub, Old_Id);
               R : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Sub, New_Id);
               pragma Unreferenced (L, R);
            begin
               Fast_Forward :=
                 Version.History.Is_Ancestor (Sub, Old_Id, New_Id);
               Fast_Backward :=
                 Version.History.Is_Ancestor (Sub, New_Id, Old_Id);
            end;
         exception
            when others =>
               Message := To_Unbounded_String ("(commits not present)");
         end;
      end if;

      --  The header line takes no color (git's "commit" color, the
      --  terminal default); the commit lines are painted whole.
      Append
        (Result,
         "Submodule " & Shown & " " & Ab (Old_Present, Old_Id)
         & (if Fast_Forward or else Fast_Backward then ".." else "...")
         & Ab (New_Present, New_Id));
      if Length (Message) > 0 then
         Append (Result, " " & To_String (Message) & LF);
      else
         Append
           (Result, (if Fast_Backward then " (rewind)" else "") & ":" & LF);
      end if;

      if not Have_Sub
        or else (Length (Message) > 0 and then Old_Present and then New_Present)
      then
         return To_String (Result);
      end if;

      if Opts.Submodule = Sub_Diff then
         --  The submodule's own patch, its paths under this one's; a new
         --  or deleted submodule diffs against the empty tree.
         declare
            Inner : Diff_Options := Opts;
            Objects : Version.Object_Cache.Object_Cache;
            Trees   : Version.Tree_Cache.Tree_Cache;
            function Side (Present : Boolean;
                           Id : Version.Objects.Hex_Object_Id)
              return Side_Entry_Vectors.Vector
            is (if not Present then Side_Entry_Vectors.Empty_Vector
                else From_Tree
                       (Version.Tree_Cache.Flatten_Tree
                          (Repo    => Sub,
                           Cache   => Trees,
                           Tree_Id =>
                             Version.Objects.Commit_Tree_Id
                               (Version.Objects.Read_Object (Sub, Id)))));
         begin
            Inner.Submodule := Sub_Short;
            Inner.Src_Prefix :=
              To_Unbounded_String (To_String (Opts.Src_Prefix) & Shown & "/");
            Inner.Dst_Prefix :=
              To_Unbounded_String (To_String (Opts.Dst_Prefix) & Shown & "/");
            Inner.Relative_Set := False;
            Inner.Relative := Null_Unbounded_String;
            Append
              (Result,
               Diff_Sides
                 (Repo        => Sub,
                  Objects     => Objects,
                  Old_Side    => Side (Old_Present, Old_Id),
                  New_Side    => Side (New_Present, New_Id),
                  New_Working => False,
                  Context     => Inner.Context_Lines,
                  Detect_Renames => Renames_Enabled (Sub, Inner),
                  Rename_Score   => Inner.Rename_Score,
                  Rename_Limit   => Inner.Rename_Limit,
                  Binary_Patch   => Inner.Binary_Patch,
                  Text           => Inner.Diff_Text,
                  Src_Prefix     => To_String (Inner.Src_Prefix),
                  Dst_Prefix     => To_String (Inner.Dst_Prefix),
                  Word_Diff      => Inner.Word_Diff,
                  Opts           => Inner));
         end;
         return To_String (Result);
      end if;

      if Length (Message) > 0 then
         return To_String (Result);
      end if;

      --  `rev-list --left-right old...new`, newest first.
      declare
         Left  : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Rev_List (Sub, [Old_Id], [New_Id]);
         Right : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Rev_List (Sub, [New_Id], [Old_Id]);
         LI : Natural := Left.First_Index;
         RI : Natural := Right.First_Index;

         function Stamp (Id : Version.Objects.Hex_Object_Id) return Long_Long_Integer
         is (Version.Objects.Commit_Committer_Time
               (Version.Objects.Read_Object (Sub, Id)));

         procedure Line (Id : Version.Objects.Hex_Object_Id; From_Left : Boolean)
         is
         begin
            Append
              (Result,
               (if From_Left then Old_C & "  < " else New_C & "  > ")
               & Version.Objects.Commit_Message_First_Line
                   (Version.Objects.Read_Object (Sub, Id))
               & Reset & LF);
         end Line;
      begin
         while LI <= Left.Last_Index or else RI <= Right.Last_Index loop
            if LI > Left.Last_Index then
               Line (Right.Element (RI), False);
               RI := RI + 1;
            elsif RI > Right.Last_Index then
               Line (Left.Element (LI), True);
               LI := LI + 1;
            elsif Stamp (Right.Element (RI)) >= Stamp (Left.Element (LI)) then
               Line (Right.Element (RI), False);
               RI := RI + 1;
            else
               Line (Left.Element (LI), True);
               LI := LI + 1;
            end if;
         end loop;
      end;
      return To_String (Result);
   end Submodule_Block;

   function Diff_Sides_Core
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
      Numstat     : Boolean := False;
      Shortstat   : Boolean := False;
      Raw         : Boolean := False;
      Abbrev      : Natural := 7;
      Compact     : Boolean := False;
      Stat_Width  : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Filter : String := "";
      Detect_Renames : Boolean := False;
      Rename_Score   : Natural := 0;
      Rename_Limit   : Natural := 0;
      Binary_Patch   : Boolean := False;
      Text           : Boolean := False;
      Src_Prefix     : String := "a/";
      Dst_Prefix     : String := "b/";
      Word_Diff      : Word_Diff_Kind := WD_None;
      Opts           : Diff_Options := (others => <>)) return String
   is
      HT       : constant Character := Character'Val (9);
      NL       : constant Character := Character'Val (10);
      Old_Map  : constant Side_Entry_Maps.Map := To_Map (Old_Side);
      New_Map  : constant Side_Entry_Maps.Map := To_Map (New_Side);

      --  --relative: the prefix the sides were narrowed to, dropped from
      --  every path shown.
      Rel : constant String := To_String (Opts.Relative);
      function Shown (P : String) return String is
        (if Rel'Length > 0 and then P'Length >= Rel'Length
           and then P (P'First .. P'First + Rel'Length - 1) = Rel
         then P (P'First + Rel'Length .. P'Last) else P);
      As_Stat  : constant Boolean :=
        Stat or else Summary or else Numstat or else Shortstat;
      As_List  : constant Boolean :=
        Name_Only or else Name_Status or else Raw;

      --  git's `--raw` line: ":<mode1> <mode2> <sha1> <sha2> <status>" then a
      --  tab and the path(s). Modes are six digits, ids abbreviated to seven,
      --  an absent side is all zeros, and a rename names both paths.
      function Pad6 (M : String) return String is
        ((1 .. Integer'Max (0, 6 - M'Length) => '0') & M);
      Ab_Len : constant Positive := Positive'Max (Abbrev, 1);
      function Ab7 (Present : Boolean;
                    Id : Version.Objects.Hex_Object_Id) return String is
        (if not Present then [1 .. Ab_Len => '0']
         else Version.Objects.To_String (Id)
                (Version.Objects.To_String (Id)'First ..
                 Version.Objects.To_String (Id)'First + Ab_Len - 1));
      --  git's `--diff-filter`: an uppercase letter includes that status, a
      --  lowercase one excludes it. With only excludes, everything else
      --  passes; with any include, only the listed statuses do.
      function Filter_Passes (Status : Character) return Boolean is
         Has_Include : Boolean := False;
         Included    : Boolean := False;
      begin
         if Diff_Filter = "" then
            return True;
         end if;
         for C of Diff_Filter loop
            if C in 'A' .. 'Z' then
               Has_Include := True;
               if C = Status then
                  Included := True;
               end if;
            elsif C in 'a' .. 'z' then
               if Ada.Characters.Handling.To_Upper (C) = Status then
                  return False;
               end if;
            end if;
         end loop;
         return (if Has_Include then Included else True);
      end Filter_Passes;

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
         --  A side read from the working tree keeps being read from there,
         --  whichever side of the diff it ended up on (-R).
         On_Disk : constant Boolean :=
           (New_Map.Contains (Path) and then New_Map.Element (Path).Working)
           or else (Old_Map.Contains (Path)
                    and then Old_Map.Element (Path).Working);
      begin
         if On_Disk and then not Is_Gitlink_Mode (Mode) then
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
         Ordered : constant Path_Vectors.Vector :=
           Ordered_Paths (Repo, Paths, To_String (Opts.Order_File));
      begin
         for Path of Ordered loop
            declare
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
                       Present => False,
                       Working => False)
                  else Side_Entry_Maps.Element (Old_Cursor));
               New_E      : constant Side_Entry :=
                 (if not Side_Entry_Maps.Has_Element (New_Cursor)
                  then
                    Side_Entry'
                      (Path    => To_Unbounded_String (Path),
                       Id      => Short_Zero,
                       Mode    => Null_Unbounded_String,
                       Present => False,
                       Working => False)
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

               --  Change letter for `--diff-filter`, from side presence.
               Status_Char : constant Character :=
                 (if Is_Rename_Dest then 'R'
                  elsif not Old_E.Present then 'A'
                  elsif not New_E.Present then 'D'
                  else 'M');
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
               elsif not Filter_Passes (Status_Char) then
                  --  Excluded by --diff-filter.
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
                        New_Working => New_E.Working,
                        Result      => Entry_Stat,
                        Changed     => Changed,
                        Old_Working => Src_E.Working,
                        Opts        => Opts);
                     if Changed or else Is_Rename_Dest then
                        if Raw then
                           declare
                              OP : constant Boolean :=
                                Entry_Stat.Old_Present;
                              NP : constant Boolean :=
                                Entry_Stat.New_Present;
                              Status : constant String :=
                                (if Is_Rename_Dest
                                 then "R" & Score_Image (Rn.Score)
                                 elsif not OP then "A"
                                 elsif not NP then "D"
                                 else "M");
                           begin
                              Append
                                (Result,
                                 ":" & Pad6 (To_String (Src_E.Mode)) & " "
                                 & Pad6 (To_String (New_E.Mode)) & " "
                                 & Ab7 (OP, Src_E.Id) & " "
                                 & Ab7 (NP, New_E.Id) & " " & Status & HT
                                 & (if Is_Rename_Dest then Shown (Rn_Path) & HT
                                    else "")
                                 & Shown (Path) & NL);
                           end;
                        else
                           if Name_Status then
                              if Is_Rename_Dest then
                                 --  git pads the score to three digits and
                                 --  names both sides.
                                 Append
                                   (Result,
                                    "R" & Score_Image (Rn.Score) & HT
                                    & Shown (Rn_Path) & HT);
                              else
                                 Append
                                   (Result,
                                    (if not Entry_Stat.Old_Present then 'A'
                                     elsif not Entry_Stat.New_Present then 'D'
                                     else 'M')
                                    & HT);
                              end if;
                           end if;
                           Append (Result, Shown (Path) & NL);
                        end if;
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
                        New_Working => New_E.Working,
                        Result      => Entry_Stat,
                        Changed     => Changed,
                        Old_Working => Src_E.Working,
                        Opts        => Opts);
                     Entry_Stat.Path := To_Unbounded_String (Shown (Path));
                     if Is_Rename_Dest then
                        Entry_Stat.Old_Path :=
                          To_Unbounded_String (Shown (Rn_Path));
                        Entry_Stat.Rename_Score := Rn.Score;
                     end if;
                     if Changed or else Is_Rename_Dest then
                        Stats.Append (Entry_Stat);
                     end if;
                  end;
               elsif Opts.Submodule /= Sub_Short
                 and then not Opts.Check_Whitespace
                 and then (Is_Gitlink_Mode (To_String (Src_E.Mode))
                           or else Is_Gitlink_Mode (To_String (New_E.Mode)))
                 and then not (Src_E.Present and then New_E.Present
                               and then Src_E.Id = New_E.Id)
               then
                  Append
                    (Result,
                     Submodule_Block
                       (Repo, Path, Shown (Path),
                        Old_Present => Src_E.Present,
                        Old_Id      => Src_E.Id,
                        New_Present => New_E.Present,
                        New_Id      => New_E.Id,
                        Opts        => Opts));
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
                        New_Working => New_E.Working,
                        Context     => Context,
                        Old_Path     =>
                          (if Is_Rename_Dest then Rn_Path else ""),
                        Rename_Score => Rn.Score,
                        Binary_Patch => Binary_Patch,
                        As_Text      => Text,
                        Src_Prefix   => Src_Prefix,
                        Dst_Prefix   => Dst_Prefix,
                        Word_Diff    => Word_Diff,
                        Old_Working  => Src_E.Working,
                        Opts         => Opts,
                        Shown        => Shown (Path),
                        Old_Shown    =>
                          (if Is_Rename_Dest then Shown (Rn_Path) else "")));
               end if;
            end;
         end loop;
      end;

      if As_Stat then
         return Emit_Stat
           (Stats, Show_Stat => Stat, Show_Summary => Summary,
            Show_Numstat => Numstat, Show_Shortstat => Shortstat,
            Compact => Compact, Stat_Width => Stat_Width,
            Stat_Name_Width => Stat_Name_Width, Stat_Count => Stat_Count,
            Color => Opts.Color);
      end if;
      return To_String (Result);
   end Diff_Sides_Core;

   --  Diff_Sides_Core after the option-level rewrites of the two sides:
   --  `-R` swaps them (and the a/ b/ prefixes, as git does), `--relative`
   --  narrows both to the prefix, and a Default algorithm reads
   --  `diff.algorithm`.
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
      Numstat     : Boolean := False;
      Shortstat   : Boolean := False;
      Raw         : Boolean := False;
      Abbrev      : Natural := 7;
      Compact     : Boolean := False;
      Stat_Width  : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Filter : String := "";
      Detect_Renames : Boolean := False;
      Rename_Score   : Natural := 0;
      Rename_Limit   : Natural := 0;
      Binary_Patch   : Boolean := False;
      Text           : Boolean := False;
      Src_Prefix     : String := "a/";
      Dst_Prefix     : String := "b/";
      Word_Diff      : Word_Diff_Kind := WD_None;
      Opts           : Diff_Options := (others => <>)) return String
   is
      use type Version.Merge.Diff_Algorithm;
      Eff : Diff_Options := Opts;

      function Under_Prefix
        (Side : Side_Entry_Vectors.Vector) return Side_Entry_Vectors.Vector
      is
         Rel    : constant String := To_String (Opts.Relative);
         Result : Side_Entry_Vectors.Vector;
      begin
         for E of Side loop
            declare
               P : constant String := To_String (E.Path);
            begin
               if P'Length > Rel'Length
                 and then P (P'First .. P'First + Rel'Length - 1) = Rel
               then
                  Result.Append (E);
               end if;
            end;
         end loop;
         return Result;
      end Under_Prefix;
   begin
      if Eff.Algorithm = Version.Merge.Diff_Algorithm_Default then
         Eff.Algorithm := Configured_Algorithm (Repo);
      end if;

      declare
         Rel  : constant Boolean :=
           Opts.Relative_Set and then Length (Opts.Relative) > 0;
         A    : constant Side_Entry_Vectors.Vector :=
           (if Rel then Under_Prefix (Old_Side) else Old_Side);
         B    : constant Side_Entry_Vectors.Vector :=
           (if Rel then Under_Prefix (New_Side) else New_Side);
         Swap : constant Boolean := Opts.Reverse_Sides;
      begin
         return
           Diff_Sides_Core
             (Repo        => Repo,
              Objects     => Objects,
              Old_Side    => (if Swap then B else A),
              New_Side    => (if Swap then A else B),
              New_Working => New_Working and then not Swap,
              Context     => Context,
              Stat        => Stat,
              Summary     => Summary,
              Name_Only   => Name_Only,
              Name_Status => Name_Status,
              Numstat     => Numstat,
              Shortstat   => Shortstat,
              Raw         => Raw,
              Abbrev      => Abbrev,
              Compact     => Compact,
              Stat_Width  => Stat_Width,
              Stat_Name_Width => Stat_Name_Width,
              Stat_Count      => Stat_Count,
              Diff_Filter => Diff_Filter,
              Detect_Renames => Detect_Renames,
              Rename_Score   => Rename_Score,
              Rename_Limit   => Rename_Limit,
              Binary_Patch   => Binary_Patch,
              Text           => Text,
              Src_Prefix     => (if Swap then Dst_Prefix else Src_Prefix),
              Dst_Prefix     => (if Swap then Src_Prefix else Dst_Prefix),
              Word_Diff      => Word_Diff,
              Opts           => Eff);
      end;
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
                 Old_Side    => From_Index (Index, Options.Ita_Visible),
                 New_Side    => From_Working_For_Index (Working, Index),
                 New_Working => True,
                 Context     => Options.Context_Lines,
                 Stat        => Options.Stat,
                 Numstat     => Options.Numstat,
                 Shortstat   => Options.Shortstat,
                 Summary     => Options.Summary,
                 Name_Only   => Options.Name_Only,
                 Name_Status => Options.Name_Status,
                 Raw            => Options.Raw, Abbrev => Options.Abbrev,
                 Compact        => Options.Compact_Summary,
                 Stat_Width     => Options.Stat_Width,
                 Stat_Name_Width => Options.Stat_Name_Width,
                 Stat_Count      => Options.Stat_Count,
                 Diff_Filter => To_String (Options.Diff_Filter),
                 Detect_Renames => Renames_Enabled (Repo, Options),
                 Rename_Score   => Options.Rename_Score,
                 Rename_Limit   => Options.Rename_Limit,
                 Binary_Patch   => Options.Binary_Patch,
                 Text            => Options.Diff_Text,
                 Src_Prefix      => To_String (Options.Src_Prefix),
                 Dst_Prefix      => To_String (Options.Dst_Prefix),
                 Word_Diff       => Options.Word_Diff,
                 Opts            => Options);
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
                 Old_Side    =>
                   Filter_Side
                     (From_Index (Index, Options.Ita_Visible), Pathspecs),
                 New_Side    =>
                   Filter_Side
                     (From_Working_For_Index (Working, Index), Pathspecs),
                 New_Working => True,
                 Context     => Options.Context_Lines,
                 Stat        => Options.Stat,
                 Numstat     => Options.Numstat,
                 Shortstat   => Options.Shortstat,
                 Summary     => Options.Summary,
                 Name_Only   => Options.Name_Only,
                 Name_Status => Options.Name_Status,
                 Raw            => Options.Raw, Abbrev => Options.Abbrev,
                 Compact        => Options.Compact_Summary,
                 Stat_Width     => Options.Stat_Width,
                 Stat_Name_Width => Options.Stat_Name_Width,
                 Stat_Count      => Options.Stat_Count,
                 Diff_Filter => To_String (Options.Diff_Filter),
                 Detect_Renames => Renames_Enabled (Repo, Options),
                 Rename_Score   => Options.Rename_Score,
                 Rename_Limit   => Options.Rename_Limit,
                 Binary_Patch   => Options.Binary_Patch,
                 Text            => Options.Diff_Text,
                 Src_Prefix      => To_String (Options.Src_Prefix),
                 Dst_Prefix      => To_String (Options.Dst_Prefix),
                 Word_Diff       => Options.Word_Diff,
                 Opts            => Options);
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
              New_Side    => From_Index (Version.Staging.Load (Repo), Options.Ita_Visible),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
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
                  (From_Index (Version.Staging.Load (Repo), Options.Ita_Visible),
                   Pathspecs),
              New_Working => False,
              Context => Options.Context_Lines,
              Stat => Options.Stat, Summary => Options.Summary,
              Name_Only => Options.Name_Only,
              Name_Status => Options.Name_Status,
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
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
   begin
      return
        Diff_Tree_Vs_Working
          (Repo, Tree_Id, Version.Pathspec.Pathspec_Vectors.Empty_Vector,
           Options);
   end Diff_Tree_Vs_Working;

   function Diff_Tree_Vs_Working
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
      Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Ignore  : Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
      Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan
          (Repo => Repo, Ignore_Rules => Ignore, Tracked_Paths => Index,
           Pathspecs => Pathspecs);
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Tree    : constant Side_Entry_Vectors.Vector :=
        From_Tree
          (Version.Tree_Cache.Flatten_Tree
             (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id));
      Disk    : constant Side_Entry_Vectors.Vector :=
        From_Working_For_Index (Working, Index);
   begin
      return
        Diff_Sides
          (Repo        => Repo,
           Objects     => Objects,
           Old_Side    =>
             (if Pathspecs.Is_Empty then Tree
              else Filter_Side (Tree, Pathspecs)),
           New_Side    =>
             (if Pathspecs.Is_Empty then Disk
              else Filter_Side (Disk, Pathspecs)),
           New_Working => True,
           Context     => Options.Context_Lines,
           Stat        => Options.Stat, Summary => Options.Summary,
           Numstat => Options.Numstat, Shortstat => Options.Shortstat,
           Name_Only   => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Raw            => Options.Raw, Abbrev => Options.Abbrev,
           Compact        => Options.Compact_Summary,
           Stat_Width     => Options.Stat_Width,
           Stat_Name_Width => Options.Stat_Name_Width,
           Stat_Count      => Options.Stat_Count,
           Diff_Filter => To_String (Options.Diff_Filter),
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch,
           Text            => Options.Diff_Text,
           Src_Prefix      => To_String (Options.Src_Prefix),
           Dst_Prefix      => To_String (Options.Dst_Prefix),
           Word_Diff       => Options.Word_Diff,
           Opts            => Options);
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
           New_Side    =>
             From_Index (Version.Staging.Load (Repo), Options.Ita_Visible),
           New_Working => False,
           Context     => Options.Context_Lines,
           Stat        => Options.Stat, Summary => Options.Summary,
           Numstat => Options.Numstat, Shortstat => Options.Shortstat,
           Name_Only   => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Raw            => Options.Raw, Abbrev => Options.Abbrev,
           Compact        => Options.Compact_Summary,
           Stat_Width     => Options.Stat_Width,
           Stat_Name_Width => Options.Stat_Name_Width,
           Stat_Count      => Options.Stat_Count,
           Diff_Filter => To_String (Options.Diff_Filter),
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch,
           Text            => Options.Diff_Text,
           Src_Prefix      => To_String (Options.Src_Prefix),
           Dst_Prefix      => To_String (Options.Dst_Prefix),
           Word_Diff       => Options.Word_Diff,
           Opts            => Options);
   end Diff_Tree_Vs_Index;

   function Diff_Tree_Vs_Index
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>)) return String
   is
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
                  (Version.Tree_Cache.Flatten_Tree
                     (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id)),
                Pathspecs),
           New_Side    =>
             Filter_Side
               (From_Index (Version.Staging.Load (Repo), Options.Ita_Visible),
                Pathspecs),
           New_Working => False,
           Context     => Options.Context_Lines,
           Stat        => Options.Stat, Summary => Options.Summary,
           Numstat => Options.Numstat, Shortstat => Options.Shortstat,
           Name_Only   => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Raw            => Options.Raw, Abbrev => Options.Abbrev,
           Compact        => Options.Compact_Summary,
           Stat_Width     => Options.Stat_Width,
           Stat_Name_Width => Options.Stat_Name_Width,
           Stat_Count      => Options.Stat_Count,
           Diff_Filter => To_String (Options.Diff_Filter),
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch,
           Text            => Options.Diff_Text,
           Src_Prefix      => To_String (Options.Src_Prefix),
           Dst_Prefix      => To_String (Options.Dst_Prefix),
           Word_Diff       => Options.Word_Diff,
           Opts            => Options);
   end Diff_Tree_Vs_Index;

   function Diff_Trees
     (Repo     : Version.Repository.Repository_Handle;
      Old_Tree : Version.Objects.Hex_Object_Id;
      New_Tree : Version.Objects.Hex_Object_Id;
      Options  : Diff_Options := (others => <>)) return String
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
                  (Repo => Repo, Cache => Trees, Tree_Id => Old_Tree)),
           New_Side    =>
             From_Tree
               (Version.Tree_Cache.Flatten_Tree
                  (Repo => Repo, Cache => Trees, Tree_Id => New_Tree)),
           New_Working => False,
           Context => Options.Context_Lines,
           Stat => Options.Stat, Summary => Options.Summary,
           Name_Only => Options.Name_Only,
           Name_Status => Options.Name_Status,
           Raw            => Options.Raw, Abbrev => Options.Abbrev,
           Compact        => Options.Compact_Summary,
           Stat_Width     => Options.Stat_Width,
           Stat_Name_Width => Options.Stat_Name_Width,
           Stat_Count      => Options.Stat_Count,
           Diff_Filter => To_String (Options.Diff_Filter),
           Numstat => Options.Numstat, Shortstat => Options.Shortstat,
           Detect_Renames => Renames_Enabled (Repo, Options),
           Rename_Score   => Options.Rename_Score,
           Rename_Limit   => Options.Rename_Limit,
           Binary_Patch   => Options.Binary_Patch,
           Text            => Options.Diff_Text,
           Src_Prefix      => To_String (Options.Src_Prefix),
           Dst_Prefix      => To_String (Options.Dst_Prefix),
           Word_Diff       => Options.Word_Diff,
           Opts            => Options);
   end Diff_Trees;

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
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
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
         return Diff_Commits (Repo, Old_Id, New_Id, Options);
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
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
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
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
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
              Raw            => Options.Raw, Abbrev => Options.Abbrev,
              Compact        => Options.Compact_Summary,
              Stat_Width     => Options.Stat_Width,
              Stat_Name_Width => Options.Stat_Name_Width,
              Stat_Count      => Options.Stat_Count,
              Diff_Filter => To_String (Options.Diff_Filter),
              Numstat => Options.Numstat, Shortstat => Options.Shortstat,
              Detect_Renames => Renames_Enabled (Repo, Options),
              Rename_Score   => Options.Rename_Score,
              Rename_Limit   => Options.Rename_Limit,
              Binary_Patch   => Options.Binary_Patch,
              Text            => Options.Diff_Text,
              Src_Prefix      => To_String (Options.Src_Prefix),
              Dst_Prefix      => To_String (Options.Dst_Prefix),
              Word_Diff       => Options.Word_Diff,
              Opts            => Options);
      end;
   end Diff_Root_Commit;

   function Raw_Diff_Trees
     (Repo       : Version.Repository.Repository_Handle;
      Base       : Version.Objects.Hex_Object_Id;
      Has_Base   : Boolean;
      Target     : Version.Objects.Hex_Object_Id;
      Recursive  : Boolean := True;
      Show_Trees : Boolean := False)
      return String
   is
      type Blob_Info is record
         Mode : Unbounded_String;
         Sha  : Unbounded_String;
      end record;

      package Entry_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Blob_Info);

      --  git's `-t` also reports changed subdirectories: recursively add each
      --  tree entry (mode 040000) so the compare loop below emits it.
      procedure Add_Dirs
        (Tid    : Version.Objects.Hex_Object_Id;
         Prefix : String;
         Into   : in out Entry_Maps.Map)
      is
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Tree_Entries (Repo, Tid);
      begin
         for E of Entries loop
            if E.Kind = Version.Objects.Tree_Directory then
               declare
                  Path : constant String :=
                    (if Prefix = "" then To_String (E.Path)
                     else Prefix & "/" & To_String (E.Path));
               begin
                  Into.Include
                    (Path,
                     (Mode => E.Mode,
                      Sha  => To_Unbounded_String
                                (Version.Objects.To_String (E.Id))));
                  Add_Dirs (E.Id, Path, Into);
               end;
            end if;
         end loop;
      end Add_Dirs;

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
         if Show_Trees then
            Add_Dirs (Tid, "", M);
         end if;
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

   function Dir_Stat
     (Repo       : Version.Repository.Repository_Handle;
      Old_Tree   : Version.Objects.Hex_Object_Id;
      Has_Base   : Boolean;
      New_Tree   : Version.Objects.Hex_Object_Id;
      By_File    : Boolean := False;
      By_Line    : Boolean := False;
      Permille   : Natural := 30;
      Cumulative : Boolean := False)
      return String
   is
      LF : constant Character := Character'Val (10);

      type Blob_Info is record
         Sha  : Unbounded_String;
         Id   : Version.Objects.Object_Id_Storage;
         Mode : Unbounded_String;
      end record;
      package Blob_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Blob_Info);

      function Load (Tid : Version.Objects.Hex_Object_Id; Present : Boolean)
        return Blob_Maps.Map
      is
         M : Blob_Maps.Map;
      begin
         if Present then
            for E of Version.Objects.Flatten_Tree (Repo, Tid) loop
               if E.Kind /= Version.Objects.Tree_Directory then
                  M.Include
                    (To_String (E.Path),
                     (Sha  => To_Unbounded_String
                                (Version.Objects.To_String (E.Id)),
                      Id   => E.Id,
                      Mode => E.Mode));
               end if;
            end loop;
         end if;
         return M;
      end Load;

      Old_M : constant Blob_Maps.Map := Load (Old_Tree, Has_Base);
      New_M : constant Blob_Maps.Map := Load (New_Tree, True);

      function Content (Sha : String) return String is
        (Version.Objects.Content
           (Version.Objects.Read_Object
              (Repo, Version.Objects.To_Object_Id (Sha))));

      --  One file's damage in git's chosen mode. Callers pass "" for an
      --  absent side (an add or a delete).
      function Damage_Of (Old_Sha, New_Sha : String) return Natural is
      begin
         if Old_Sha = New_Sha then
            return 0;   --  content unchanged (e.g. a mode-only change)
         elsif By_File then
            return 1;
         end if;
         declare
            Old_C : constant String :=
              (if Old_Sha = "" then "" else Content (Old_Sha));
            New_C : constant String :=
              (if New_Sha = "" then "" else Content (New_Sha));
         begin
            if By_Line then
               --  git's show_dirstat_by_line: damage is the number of added
               --  plus deleted lines from the actual diff; a binary file
               --  counts in 64-byte chunks instead.
               if Version.Rename_Detect.Is_Binary (Old_C)
                 or else Version.Rename_Detect.Is_Binary (New_C)
               then
                  return (Old_C'Length + New_C'Length + 63) / 64;
               end if;
               declare
                  Patch  : constant String :=
                    Unified_Text_Diff ("x", Old_C, New_C, 0);
                  D      : Natural := 0;
                  At_Bol : Boolean := True;
                  In_Body : Boolean := False;   --  past the ---/+++ headers
               begin
                  --  Count body +/- lines. The "---"/"+++" file headers also
                  --  begin with -/+, so start counting only after the first
                  --  "@@" hunk marker; skip subsequent "@@" markers too.
                  for K in Patch'Range loop
                     if At_Bol then
                        if K + 1 <= Patch'Last
                          and then Patch (K) = '@' and then Patch (K + 1) = '@'
                        then
                           In_Body := True;
                        elsif In_Body
                          and then (Patch (K) = '+' or else Patch (K) = '-')
                        then
                           D := D + 1;
                        end if;
                     end if;
                     At_Bol := Patch (K) = LF;
                  end loop;
                  return D;
               end;
            else
               --  Default "changes" mode: git's content-damage measure.
               declare
                  D : constant Natural :=
                    Version.Rename_Detect.Change_Damage (Old_C, New_C);
               begin
                  return (if D = 0 then 1 else D);
               end;
            end if;
         end;
      end Damage_Of;

      type File_Rec is record
         Name   : Unbounded_String;
         Damage : Natural;
      end record;
      package File_Vecs is new
        Ada.Containers.Vectors (Natural, File_Rec);
      function Rec_Less (L, R : File_Rec) return Boolean is
        (To_String (L.Name) < To_String (R.Name));
      package File_Sort is new File_Vecs.Generic_Sorting ("<" => Rec_Less);
      Files : File_Vecs.Vector;
      Total : Natural := 0;

      procedure Add (Name : String; Damage : Natural) is
      begin
         Files.Append
           (File_Rec'(Name   => To_Unbounded_String (Name),
                      Damage => Damage));
         Total := Total + Damage;
      end Add;

      --  Rename detection over the deletion/creation cross product, exactly
      --  as the porcelain runs diffcore_rename before show_dirstat: a renamed
      --  file's damage is the source-to-destination change, charged to the
      --  destination directory, and its deletion is not counted separately.
      function Side_Text
        (Side : Version.Rename_Detect.Rename_Side) return String is
        (Content (Version.Objects.To_String (Side.Id)));
      function Detect_Pairs is
        new Version.Rename_Detect.Detect (Content_Of => Side_Text);

      package Str_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Renamed_From : Str_Sets.Set;   --  deletion paths consumed as sources
   begin
      --  Modifications (both sides) are charged in place; deletions are
      --  collected for rename detection below.
      for C in Old_M.Iterate loop
         declare
            Path : constant String := Blob_Maps.Key (C);
         begin
            if New_M.Contains (Path) then
               Add (Path, Damage_Of (To_String (Old_M (C).Sha),
                                     To_String (New_M (Path).Sha)));
            end if;
         end;
      end loop;

      declare
         Sources, Dests : Version.Rename_Detect.Side_Vectors.Vector;
      begin
         for C in Old_M.Iterate loop
            if not New_M.Contains (Blob_Maps.Key (C)) then
               Sources.Append
                 (Version.Rename_Detect.Rename_Side'
                    (Path => To_Unbounded_String (Blob_Maps.Key (C)),
                     Id   => Old_M (C).Id,
                     Mode => Old_M (C).Mode));
            end if;
         end loop;
         for C in New_M.Iterate loop
            if not Old_M.Contains (Blob_Maps.Key (C)) then
               Dests.Append
                 (Version.Rename_Detect.Rename_Side'
                    (Path => To_Unbounded_String (Blob_Maps.Key (C)),
                     Id   => New_M (C).Id,
                     Mode => New_M (C).Mode));
            end if;
         end loop;

         declare
            Pairs : constant Version.Rename_Detect.Pair_Vectors.Vector :=
              Detect_Pairs (Sources, Dests);
            Paired_Dest : Str_Sets.Set;
         begin
            for P of Pairs loop
               declare
                  Src : constant Version.Rename_Detect.Rename_Side :=
                    Sources.Element (P.Source);
                  Dst : constant Version.Rename_Detect.Rename_Side :=
                    Dests.Element (P.Dest);
               begin
                  Renamed_From.Include (To_String (Src.Path));
                  Paired_Dest.Include (To_String (Dst.Path));
                  Add (To_String (Dst.Path),
                       Damage_Of (Version.Objects.To_String (Src.Id),
                                  Version.Objects.To_String (Dst.Id)));
               end;
            end loop;

            --  Unpaired deletions and additions keep their own damage.
            for C in Old_M.Iterate loop
               if not New_M.Contains (Blob_Maps.Key (C))
                 and then not Renamed_From.Contains (Blob_Maps.Key (C))
               then
                  Add (Blob_Maps.Key (C),
                       Damage_Of (To_String (Old_M (C).Sha), ""));
               end if;
            end loop;
            for C in New_M.Iterate loop
               if not Old_M.Contains (Blob_Maps.Key (C))
                 and then not Paired_Dest.Contains (Blob_Maps.Key (C))
               then
                  Add (Blob_Maps.Key (C),
                       Damage_Of ("", To_String (New_M (C).Sha)));
               end if;
            end loop;
         end;
      end;

      File_Sort.Sort (Files);

      if Total = 0 then
         return "";
      end if;

      --  gather_dirstat: recurse over the sorted paths, printing every
      --  directory (baselen > 0) that is not a lone pass-through and whose
      --  share reaches the threshold.
      declare
         Result : Unbounded_String;
         Idx    : Natural := Files.First_Index;

         function Gather (Base : String; Baselen : Natural) return Natural is
            Sum     : Natural := 0;
            Sources : Natural := 0;
         begin
            while Idx <= Files.Last_Index loop
               declare
                  Name : constant String := To_String (Files (Idx).Name);
                  Slash : Natural := 0;
               begin
                  exit when Name'Length < Baselen;
                  exit when Name (Name'First .. Name'First + Baselen - 1)
                            /= Base (Base'First .. Base'First + Baselen - 1);
                  for K in Name'First + Baselen .. Name'Last loop
                     if Name (K) = '/' then
                        Slash := K;
                        exit;
                     end if;
                  end loop;
                  if Slash /= 0 then
                     declare
                        New_Baselen : constant Natural :=
                          Slash - Name'First + 1;
                     begin
                        Sum := Sum
                          + Gather
                              (Name (Name'First .. Slash), New_Baselen);
                     end;
                     Sources := Sources + 1;
                  else
                     Sum := Sum + Files (Idx).Damage;
                     Idx := Idx + 1;
                     Sources := Sources + 2;
                  end if;
               end;
            end loop;

            if Baselen /= 0 and then Sources /= 1 and then Sum > 0 then
               declare
                  P : constant Natural := Sum * 1000 / Total;
                  function Img (N : Natural) return String is
                    (Ada.Strings.Fixed.Trim
                       (Natural'Image (N), Ada.Strings.Left));
               begin
                  if P >= Permille then
                     declare
                        Whole : constant Natural := P / 10;
                        Frac  : constant Natural := P mod 10;
                        --  git prints the integer part in a 4-wide field
                        --  ("%4d"): right-justified, no extra leading space.
                        Pad   : constant String :=
                          [1 .. Integer'Max (0, 4 - Img (Whole)'Length) => ' '];
                     begin
                        Append
                          (Result,
                           Pad & Img (Whole) & "." & Img (Frac) & "% "
                           & Base (Base'First .. Base'First + Baselen - 1)
                           & LF);
                     end;
                     if not Cumulative then
                        return 0;
                     end if;
                  end if;
               end;
            end if;
            return Sum;
         end Gather;

         Ignore : Natural;
      begin
         Ignore := Gather ("", 0);
         return To_String (Result);
      end;
   end Dir_Stat;

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

   function No_Index_Diff
     (Old_Path    : String;
      New_Path    : String;
      Old_Text    : String;
      New_Text    : String;
      Old_Present : Boolean := True;
      New_Present : Boolean := True;
      Context     : Natural := 3)
      return String
   is
      Mode   : constant String := "100644";
      Old_Id : constant Version.Objects.Hex_Object_Id :=
        (if Old_Present
         then Version.Objects.Compute_Object_Id
                (Version.Hash.Sha1, "blob", Old_Text)
         else Short_Zero);
      New_Id : constant Version.Objects.Hex_Object_Id :=
        (if New_Present
         then Version.Objects.Compute_Object_Id
                (Version.Hash.Sha1, "blob", New_Text)
         else Short_Zero);
      R : Unbounded_String;
   begin
      if Old_Present and then New_Present and then Old_Text = New_Text then
         return "";
      end if;
      Append_Line (R, "diff --git a/" & Old_Path & " b/" & New_Path);
      if not Old_Present then
         Append_Line (R, "new file mode " & Mode);
         Append_Line
           (R, "index " & Abbrev (Short_Zero) & ".." & Abbrev (New_Id));
      elsif not New_Present then
         Append_Line (R, "deleted file mode " & Mode);
         Append_Line
           (R, "index " & Abbrev (Old_Id) & ".." & Abbrev (Short_Zero));
      else
         Append_Line
           (R, "index " & Abbrev (Old_Id) & ".." & Abbrev (New_Id)
            & " " & Mode);
      end if;
      if Contains_Nul (Old_Text) or else Contains_Nul (New_Text) then
         Append_Line
           (R,
            "Binary files "
            & (if Old_Present then "a/" & Old_Path else "/dev/null")
            & " and "
            & (if New_Present then "b/" & New_Path else "/dev/null")
            & " differ");
         return To_String (R);
      end if;
      --  The `---`/`+++` lines and hunks, with the two distinct names (git's
      --  --no-index shows a/<old> and b/<new>); Git_Header off since the
      --  diff --git/index lines are already emitted above.
      Append
        (R,
         Unified_File_Diff
           (Path        => New_Path,
            Old_Text    => Old_Text,
            New_Text    => New_Text,
            Old_Present => Old_Present,
            New_Present => New_Present,
            Old_Id      => Old_Id,
            New_Id      => New_Id,
            Old_Mode    => Mode,
            New_Mode    => Mode,
            Context     => Context,
            Git_Header  => False,
            Old_Path    => Old_Path));
      return To_String (R);
   end No_Index_Diff;

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
