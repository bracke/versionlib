with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;

with Version.Merge;
with Version.Object_Cache;
with Version.Revisions;
with Version.Tree_Cache;

package body Version.Combine_Diff is

   use type Interfaces.Unsigned_64;
   subtype Mask is Interfaces.Unsigned_64;

   LF : constant Character := Character'Val (10);

   --  A path in the merge result together with what each parent had
   --  there (combine_diff_path).
   type Parent_Side is record
      Id     : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Mode   : Natural := 0;   --  0: absent
      Status : Character := 'M';   --  'A' absent in the parent, 'D' in the result
   end record;
   type Parent_Sides is array (Natural range <>) of Parent_Side;

   function Mode_Value (Text : String) return Natural is
      V : Natural := 0;
   begin
      for C of Text loop
         V := V * 8 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return V;
   end Mode_Value;

   function Mode_Image (Mode : Natural) return String is
      Digits_Img : String (1 .. 6) := "000000";
      V : Natural := Mode;
   begin
      for K in reverse Digits_Img'Range loop
         Digits_Img (K) := Character'Val (Character'Pos ('0') + V mod 8);
         V := V / 8;
      end loop;
      return Digits_Img;
   end Mode_Image;

   --  A line the result dropped from some parents (lline).
   type Lost_Line is record
      Text       : Unbounded_String;
      Parent_Map : Mask := 0;
   end record;
   package Lost_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Lost_Line);

   --  A surviving line of the result (sline); the last element stands
   --  for the end of file and only carries lost lines and P_Lno.
   type Line_Numbers is array (Natural range <>) of Natural;
   type Line_Numbers_Access is access Line_Numbers;
   type Survivor is record
      Text  : Unbounded_String;
      Lost  : Lost_Vectors.Vector;   --  coalesced across parents
      Plost : Lost_Vectors.Vector;   --  the current parent's, before coalescing
      Flag  : Mask := 0;
      P_Lno : Line_Numbers_Access;
   end record;
   type Survivors is array (Natural range <>) of Survivor;

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = ASCII.HT or else C = ASCII.LF
      or else C = ASCII.CR or else C = ASCII.VT or else C = ASCII.FF);

   --  match_string_spaces: line equality under the whitespace mode.
   function Lines_Match
     (A, B : String; Mode : Version.Merge.Whitespace_Mode) return Boolean
   is
      use type Version.Merge.Whitespace_Mode;
   begin
      if Mode = Version.Merge.Whitespace_Strict then
         return A = B;
      end if;
      return Version.Merge.Normalize_Line (A & LF, Mode)
        = Version.Merge.Normalize_Line (B & LF, Mode);
   end Lines_Match;

   --  coalesce_lines: fold the current parent's lost lines into the ones
   --  earlier parents lost at the same spot, by LCS, marking a shared
   --  line as lost from this parent too and splicing the rest in place.
   procedure Coalesce
     (Base    : in out Lost_Vectors.Vector;
      Fresh   : Lost_Vectors.Vector;
      Parent  : Natural;
      WS_Mode : Version.Merge.Whitespace_Mode)
   is
      type Direction is (Match, Keep_Base, Take_New);
      NB : constant Natural := Natural (Base.Length);
      NN : constant Natural := Natural (Fresh.Length);
      LCS : array (0 .. NB, 0 .. NN) of Natural := [others => [others => 0]];
      Dir : array (0 .. NB, 0 .. NN) of Direction :=
        [others => [others => Keep_Base]];
      Merged : Lost_Vectors.Vector;
      I, J   : Natural;
   begin
      if NN = 0 then
         return;
      end if;
      if NB = 0 then
         Base := Fresh;
         return;
      end if;
      for K in 1 .. NN loop
         Dir (0, K) := Take_New;
      end loop;
      for A in 1 .. NB loop
         for B in 1 .. NN loop
            if Lines_Match
                 (To_String (Base.Element (A).Text),
                  To_String (Fresh.Element (B).Text), WS_Mode)
            then
               LCS (A, B) := LCS (A - 1, B - 1) + 1;
               Dir (A, B) := Match;
            elsif LCS (A, B - 1) >= LCS (A - 1, B) then
               LCS (A, B) := LCS (A, B - 1);
               Dir (A, B) := Take_New;
            else
               LCS (A, B) := LCS (A - 1, B);
               Dir (A, B) := Keep_Base;
            end if;
         end loop;
      end loop;

      --  Walk back from the corner, building the merged list backwards.
      I := NB;
      J := NN;
      while I /= 0 or else J /= 0 loop
         case Dir (I, J) is
            when Match =>
               declare
                  L : Lost_Line := Base.Element (I);
               begin
                  L.Parent_Map := L.Parent_Map or Mask (2 ** Parent);
                  Merged.Prepend (L);
               end;
               I := I - 1;
               J := J - 1;
            when Take_New =>
               Merged.Prepend (Fresh.Element (J));
               J := J - 1;
            when Keep_Base =>
               Merged.Prepend (Base.Element (I));
               I := I - 1;
         end case;
      end loop;
      Base := Merged;
   end Coalesce;

   --  combine_diff: diff parent N's text against the result, hanging the
   --  lines the result dropped on the survivor that follows them and
   --  flagging the survivors this parent lacks; then number the parent's
   --  lines per survivor (P_Lno) and coalesce the lost lines.
   procedure Diff_Parent
     (Parent_Text : String;
      Result_Text : String;
      S           : in out Survivors;
      Cnt         : Natural;
      N           : Natural;
      Options     : Version.Diff.Diff_Options)
   is
      use type Version.Merge.Diff_Algorithm;
      NMask   : constant Mask := Mask (2 ** N);
      Changes : constant Version.Merge.Text_Change_Vectors.Vector :=
        Version.Merge.Text_Changes
          (Old_Text         => Parent_Text,
           New_Text         => Result_Text,
           Algorithm        =>
             (if Options.Algorithm = Version.Merge.Diff_Algorithm_Default
              then Version.Merge.Diff_Algorithm_Myers else Options.Algorithm),
           Indent_Heuristic => Options.Indent_Heuristic,
           Whitespace       => Options.Whitespace);
      P_Lines : constant Version.Merge.Line_Vectors.Vector :=
        Version.Merge.Split_Lines (Parent_Text);

      function Stripped (L : String) return String is
        (if L'Length > 0 and then L (L'Last) = LF
         then L (L'First .. L'Last - 1) else L);
   begin
      for C of Changes loop
         declare
            OB : constant Natural := C.Old_First + 1;
            NN : constant Natural := C.New_After - C.New_First;
            --  For a pure deletion the hunk is "+<lines before>,0" and the
            --  lost lines hang on the survivor after them; otherwise on
            --  the first changed survivor.
            NB     : Natural := (if NN = 0 then C.New_First else C.New_First + 1);
            Bucket : constant Natural := (if NN = 0 then NB else NB - 1);
         begin
            if NN = 0 and then NB = 0 then
               NB := 1;
            end if;
            if S (NB - 1).P_Lno = null then
               S (NB - 1).P_Lno := new Line_Numbers'(0 .. S'Last => 0);
            end if;
            S (NB - 1).P_Lno (N) := OB;

            for K in C.Old_First .. C.Old_After - 1 loop
               S (Bucket).Plost.Append
                 (Lost_Line'
                    (Text       => To_Unbounded_String
                                     (Stripped (P_Lines.Element (K))),
                     Parent_Map => NMask));
            end loop;
            for K in C.New_First .. C.New_After - 1 loop
               S (K).Flag := S (K).Flag or NMask;
            end loop;
         end;
      end loop;

      --  Number this parent's lines: sline[lno].p_lno[n] is the parent
      --  line a hunk starting at survivor lno (with its lost lines) begins
      --  at.
      declare
         P_Lno : Natural := 1;
      begin
         for Lno in 0 .. Cnt loop
            if S (Lno).P_Lno = null then
               S (Lno).P_Lno := new Line_Numbers'(0 .. S'Last => 0);
            end if;
            S (Lno).P_Lno (N) := P_Lno;
            if not S (Lno).Plost.Is_Empty then
               Coalesce (S (Lno).Lost, S (Lno).Plost, N, Options.Whitespace);
               S (Lno).Plost.Clear;
            end if;
            for L of S (Lno).Lost loop
               if (L.Parent_Map and NMask) /= 0 then
                  P_Lno := P_Lno + 1;   --  '-': the parent had it
               end if;
            end loop;
            if Lno < Cnt and then (S (Lno).Flag and NMask) = 0 then
               P_Lno := P_Lno + 1;   --  no '+': the parent had it
            end if;
         end loop;
         if S (Cnt + 1).P_Lno = null then
            S (Cnt + 1).P_Lno := new Line_Numbers'(0 .. S'Last => 0);
         end if;
         S (Cnt + 1).P_Lno (N) := P_Lno;   --  trailer
      end;
   end Diff_Parent;

   --  reuse_combine_diff: parent I is the same blob as parent J.
   procedure Reuse (S : in out Survivors; Cnt : Natural; I, J : Natural) is
      IMask : constant Mask := Mask (2 ** I);
      JMask : constant Mask := Mask (2 ** J);
   begin
      for Lno in 0 .. Cnt + 1 loop
         if S (Lno).P_Lno = null then
            S (Lno).P_Lno := new Line_Numbers'(0 .. S'Last => 0);
         end if;
         S (Lno).P_Lno (I) := S (Lno).P_Lno (J);
         for L of S (Lno).Lost loop
            if (L.Parent_Map and JMask) /= 0 then
               L.Parent_Map := L.Parent_Map or IMask;
            end if;
         end loop;
         if (S (Lno).Flag and JMask) /= 0 then
            S (Lno).Flag := S (Lno).Flag or IMask;
         end if;
      end loop;
   end Reuse;

   --  interesting(): a parent lacks this line, or lines were lost here.
   function Interesting (L : Survivor; All_Mask : Mask) return Boolean is
     ((L.Flag and All_Mask) /= 0 or else not L.Lost.Is_Empty);

   --  adjust_hunk_tail: a hunk whose last line is only interesting for its
   --  lost lines already shows one extra context line.
   function Adjust_Tail
     (S : Survivors; All_Mask : Mask; Hunk_Begin, I : Natural) return Natural
   is
   begin
      if Hunk_Begin + 1 <= I and then (S (I - 1).Flag and All_Mask) = 0 then
         return I - 1;
      end if;
      return I;
   end Adjust_Tail;

   function Find_Next
     (S : Survivors; Mark : Mask; From, Cnt : Natural; Uninteresting : Boolean)
      return Natural
   is
      I : Natural := From;
   begin
      while I <= Cnt loop
         if (if Uninteresting then (S (I).Flag and Mark) = 0
             else (S (I).Flag and Mark) /= 0)
         then
            return I;
         end if;
         I := I + 1;
      end loop;
      return I;
   end Find_Next;

   --  give_context: paint Context lines around every interesting run
   --  with Mark, joining runs whose gap is short; No_Pre_Delete marks the
   --  leading context lines so their lost lines are not shown.
   function Give_Context
     (S : in out Survivors; Cnt : Natural; Num_Parent : Natural;
      Context : Natural) return Boolean
   is
      All_Mask      : constant Mask := Mask (2 ** Num_Parent) - 1;
      Mark          : constant Mask := Mask (2 ** Num_Parent);
      No_Pre_Delete : constant Mask := Mask (2 ** (Num_Parent + 1));
      I, J, K : Natural;
   begin
      I := Find_Next (S, Mark, 0, Cnt, False);
      if Cnt < I then
         return False;
      end if;

      while I <= Cnt loop
         J := (if Context < I then I - Context else 0);
         while J < I loop
            if (S (J).Flag and Mark) = 0 then
               S (J).Flag := S (J).Flag or No_Pre_Delete;
            end if;
            S (J).Flag := S (J).Flag or Mark;
            J := J + 1;
         end loop;

         loop
            J := Find_Next (S, Mark, I, Cnt, True);
            exit when Cnt < J;   --  the rest are all interesting
            K := Find_Next (S, Mark, J, Cnt, False);
            J := Adjust_Tail (S, All_Mask, I, J);
            if K < J + Context then
               --  A short gap: paint it and go on from the next run.
               while J < K loop
                  S (J).Flag := S (J).Flag or Mark;
                  J := J + 1;
               end loop;
               I := K;
            else
               I := K;
               K := (if J + Context < Cnt + 1 then J + Context else Cnt + 1);
               while J < K loop
                  S (J).Flag := S (J).Flag or Mark;
                  J := J + 1;
               end loop;
               exit;
            end if;
         end loop;
         exit when Cnt < J;
      end loop;
      return True;
   end Give_Context;

   --  make_hunks: mark the interesting lines; under Dense drop the hunks
   --  that changed against one parent only, or the same way against all
   --  but one (the result took a side) -- then give context.
   function Make_Hunks
     (S : in out Survivors; Cnt : Natural; Num_Parent : Natural;
      Context : Natural; Dense : Boolean) return Boolean
   is
      All_Mask : constant Mask := Mask (2 ** Num_Parent) - 1;
      Mark     : constant Mask := Mask (2 ** Num_Parent);
      I        : Natural;
   begin
      for K in 0 .. Cnt loop
         if Interesting (S (K), All_Mask) then
            S (K).Flag := S (K).Flag or Mark;
         else
            S (K).Flag := S (K).Flag and not Mark;
         end if;
      end loop;
      if not Dense then
         return Give_Context (S, Cnt, Num_Parent, Context);
      end if;

      I := 0;
      while I <= Cnt loop
         while I <= Cnt and then (S (I).Flag and Mark) = 0 loop
            I := I + 1;
         end loop;
         exit when Cnt < I;
         declare
            Hunk_Begin : constant Natural := I;
            Hunk_End   : Natural;
            J          : Natural := I + 1;
            Same_Diff  : Mask := 0;
            Has_Interesting : Boolean := False;
         begin
            while J <= Cnt loop
               if (S (J).Flag and Mark) = 0 then
                  --  Look beyond the end for an interesting line within
                  --  the context span.
                  declare
                     LA     : Natural := Adjust_Tail (S, All_Mask, Hunk_Begin, J);
                     Contin : Boolean := False;
                  begin
                     LA := (if LA + Context < Cnt + 1 then LA + Context else Cnt + 1);
                     while LA > 0 loop
                        LA := LA - 1;
                        exit when J > LA;
                        if (S (LA).Flag and Mark) /= 0 then
                           Contin := True;
                           exit;
                        end if;
                     end loop;
                     exit when not Contin;
                     J := LA;
                  end;
               end if;
               J := J + 1;
            end loop;
            Hunk_End := J;

            --  Interesting only when the changed lines do not all come
            --  from the same set of parents, or that set is all of them.
            J := I;
            while J < Hunk_End and then not Has_Interesting loop
               declare
                  This_Diff : Mask := S (J).Flag and All_Mask;
               begin
                  if This_Diff /= 0 then
                     if Same_Diff = 0 then
                        Same_Diff := This_Diff;
                     elsif Same_Diff /= This_Diff then
                        Has_Interesting := True;
                        exit;
                     end if;
                  end if;
                  for L of S (J).Lost loop
                     exit when Has_Interesting;
                     This_Diff := L.Parent_Map;
                     if Same_Diff = 0 then
                        Same_Diff := This_Diff;
                     elsif Same_Diff /= This_Diff then
                        Has_Interesting := True;
                     end if;
                  end loop;
               end;
               J := J + 1;
            end loop;

            if not Has_Interesting and then Same_Diff /= All_Mask then
               for K in Hunk_Begin .. Hunk_End - 1 loop
                  S (K).Flag := S (K).Flag and not Mark;
               end loop;
            end if;
            I := Hunk_End;
         end;
      end loop;

      return Give_Context (S, Cnt, Num_Parent, Context);
   end Make_Hunks;

   --  hunk_comment_line: a line that starts a section.
   function Is_Func_Line (L : String) return Boolean is
     (L'Length > 0
      and then L (L'First) in 'a' .. 'z' | 'A' .. 'Z' | '_' | '$');

   --  dump_sline: the hunks.
   procedure Dump
     (Result     : in out Unbounded_String;
      S          : in out Survivors;
      Cnt        : Natural;
      Num_Parent : Natural;
      Context    : Natural;
      Line_Prefix : String)
   is
      Mark          : constant Mask := Mask (2 ** Num_Parent);
      No_Pre_Delete : constant Mask := Mask (2 ** (Num_Parent + 1));
      Lno           : Natural := 0;

      function Img (V : Natural) return String is
         T : constant String := Natural'Image (V);
      begin
         return T (T'First + 1 .. T'Last);
      end Img;
   begin
      loop
         declare
            Hunk_Comment : Unbounded_String;
            Have_Comment : Boolean := False;
            Hunk_End     : Natural;
            RLines       : Natural;
            Null_Context : Natural := 0;
         begin
            while Lno <= Cnt and then (S (Lno).Flag and Mark) = 0 loop
               if Lno < Cnt and then Is_Func_Line (To_String (S (Lno).Text)) then
                  Hunk_Comment := S (Lno).Text;
                  Have_Comment := True;
               end if;
               Lno := Lno + 1;
            end loop;
            exit when Cnt < Lno;
            Hunk_End := Lno + 1;
            while Hunk_End <= Cnt and then (S (Hunk_End).Flag and Mark) /= 0 loop
               Hunk_End := Hunk_End + 1;
            end loop;
            RLines := Hunk_End - Lno;
            if Cnt < Hunk_End then
               RLines := RLines - 1;   --  pointing at the last delete hunk
            end if;
            if Context = 0 then
               --  -U0: the survivors that only hang lost lines are not
               --  shown, and not counted.
               for J in Lno .. Hunk_End - 1 loop
                  if (S (J).Flag and (Mark - 1)) = 0 then
                     Null_Context := Null_Context + 1;
                  end if;
               end loop;
               RLines := RLines - Null_Context;
            end if;

            Append (Result, Line_Prefix);
            Append (Result, [1 .. Num_Parent + 1 => '@']);
            for N in 0 .. Num_Parent - 1 loop
               declare
                  L0 : constant Natural := S (Lno).P_Lno (N);
                  L1 : constant Natural := S (Hunk_End).P_Lno (N);
                  --  git computes this in an unsigned long and, under -U0,
                  --  can underflow; the wrapped number is what it prints.
                  Cnt_Img : constant String :=
                    Interfaces.Unsigned_64'Image
                      (Interfaces.Unsigned_64 (L1) - Interfaces.Unsigned_64 (L0)
                       - Interfaces.Unsigned_64 (Null_Context));
               begin
                  Append
                    (Result,
                     " -" & Img (L0) & "," & Cnt_Img (Cnt_Img'First + 1 .. Cnt_Img'Last));
               end;
            end loop;
            Append (Result, " +" & Img (Lno + 1) & "," & Img (RLines) & " ");
            Append (Result, [1 .. Num_Parent + 1 => '@']);
            if Have_Comment then
               --  git copies the section line up to the last non-blank of
               --  its first 40 bytes -- exclusive, so the last character
               --  is dropped (its comment_end is an index, used as a
               --  length).
               declare
                  C   : constant String := To_String (Hunk_Comment);
                  Stop : constant Natural := Natural'Min (C'Length, 40);
                  Comment_End : Natural := 0;
               begin
                  for I in 1 .. Stop loop
                     if not Is_Space (C (C'First + I - 1)) then
                        Comment_End := I - 1;
                     end if;
                  end loop;
                  if Comment_End > 0 then
                     Append (Result, " " & C (C'First .. C'First + Comment_End - 1));
                  end if;
               end;
            end if;
            Append (Result, LF);

            while Lno < Hunk_End loop
               declare
                  SL : constant Survivor := S (Lno);
               begin
                  Lno := Lno + 1;
                  if (SL.Flag and No_Pre_Delete) = 0 then
                     for L of SL.Lost loop
                        Append (Result, Line_Prefix);
                        for J in 0 .. Num_Parent - 1 loop
                           Append
                             (Result,
                              (if (L.Parent_Map and Mask (2 ** J)) /= 0
                               then '-' else ' '));
                        end loop;
                        Append (Result, L.Text);
                        Append (Result, LF);
                     end loop;
                  end if;
                  exit when Cnt < Lno;
                  if (SL.Flag and (Mark - 1)) = 0 and then Context = 0 then
                     --  Only here to hang lost lines in front of it.
                     null;
                  else
                     Append (Result, Line_Prefix);
                     for J in 0 .. Num_Parent - 1 loop
                        Append
                          (Result,
                           (if (SL.Flag and Mask (2 ** J)) /= 0 then '+' else ' '));
                     end loop;
                     Append (Result, SL.Text);
                     Append (Result, LF);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Dump;

   --  The paths of Commit_Id that take part in a combined diff, in tree
   --  order, each handed to Visit with what every side holds there (index
   --  0 the result, then the parents; Mode 0 for an absent side).
   type Side is record
      Id   : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Mode : Natural := 0;
   end record;
   type Side_Array is array (Natural range <>) of Side;

   --  Visit gets the path as shown: under --relative the prefix is
   --  dropped, and paths outside it are not visited at all.
   generic
      with procedure Visit (Path : String; V : Side_Array);
   procedure Walk_Paths
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector;
      Pick      : Version.Pickaxe.Spec;
      Relative  : String := "");

   procedure Walk_Paths
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector;
      Pick      : Version.Pickaxe.Spec;
      Relative  : String := "")
   is
      Num_Parent : constant Natural := Natural (Parents.Length);
      Trees      : Version.Tree_Cache.Tree_Cache;
      subtype Sides is Side_Array (0 .. Num_Parent);
      package Path_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Sides);
      Paths_Map : Path_Maps.Map;

      procedure Load (Index : Natural; Id : Version.Objects.Hex_Object_Id) is
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id
             (Version.Object_Cache.Read_Object (Repo, Objects, Id));
      begin
         for E of Version.Tree_Cache.Flatten_Tree (Repo, Trees, Tree_Id) loop
            declare
               P : constant String := To_String (E.Path);
               C : constant Path_Maps.Cursor := Paths_Map.Find (P);
               V : Sides;
            begin
               if Path_Maps.Has_Element (C) then
                  V := Path_Maps.Element (C);
               end if;
               V (Index) := (Id => E.Id, Mode => Mode_Value (To_String (E.Mode)));
               Paths_Map.Include (P, V);
            end;
         end loop;
      end Load;
   begin
      Load (0, Commit_Id);
      for N in 0 .. Num_Parent - 1 loop
         Load (N + 1, Parents.Element (N));
      end loop;

      for C in Paths_Map.Iterate loop
         declare
            Path : constant String := Path_Maps.Key (C);
            V    : constant Sides := Path_Maps.Element (C);
            Differs : Boolean := False;
         begin
            --  git's tree walk (ll_diff_tree_paths) emits a path the result
            --  has unless some parent has the identical entry, and a path
            --  the result lacks only when every parent had it.
            if V (0).Mode /= 0 then
               Differs := True;
               for N in 1 .. Num_Parent loop
                  if V (N).Mode = V (0).Mode
                    and then Version.Objects.To_String (V (N).Id)
                             = Version.Objects.To_String (V (0).Id)
                  then
                     Differs := False;
                  end if;
               end loop;
            else
               Differs := True;
               for N in 1 .. Num_Parent loop
                  if V (N).Mode = 0 then
                     Differs := False;
                  end if;
               end loop;
            end if;
            --  A pickaxe keeps the path only when its change against
            --  every parent matches (git intersects the parents' scans).
            if Differs and then Pick.Active then
               for N in 1 .. Num_Parent loop
                  if not Version.Pickaxe.Pair_Matches
                           (Repo,
                            Old_Present => V (N).Mode /= 0, Old_Id => V (N).Id,
                            New_Present => V (0).Mode /= 0, New_Id => V (0).Id,
                            Pick => Pick)
                  then
                     Differs := False;
                  end if;
               end loop;
            end if;
            if Differs
              and then (Paths.Is_Empty
                        or else Version.Pathspec.Matches_Any (Paths, Path))
            then
               if Relative'Length = 0 then
                  Visit (Path, V);
               elsif Path'Length > Relative'Length
                 and then Path (Path'First .. Path'First + Relative'Length - 1)
                          = Relative
               then
                  Visit (Path (Path'First + Relative'Length .. Path'Last), V);
               end if;
            end if;
         end;
      end loop;
   end Walk_Paths;

   --  The index-line abbreviation: --abbrev (--full-index), else the
   --  shortest unique prefix of at least seven.
   function Abbrev_Id
     (Repo    : Version.Repository.Repository_Handle;
      Id      : Version.Objects.Hex_Object_Id;
      Options : Version.Diff.Diff_Options) return String
   is
      Full : constant String := Version.Objects.To_String (Id);
      N    : constant Natural :=
        (if Options.Full_Index then Full'Length
         else Version.Revisions.Unique_Abbrev_Length (Repo, Id, 7));
   begin
      return Full (Full'First .. Full'First + N - 1);
   end Abbrev_Id;

   function Combined_Listing
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Options   : Version.Diff.Diff_Options := (others => <>);
      Kind      : Listing_Kind := Name_Only_Listing;
      Pick      : Version.Pickaxe.Spec := (others => <>)) return String
   is
      Num_Parent : constant Natural := Natural (Parents.Length);
      Objects    : Version.Object_Cache.Object_Cache;
      Result     : Unbounded_String;

      --  --raw abbreviates to --abbrev (seven by default).
      function Raw_Id (Id : Version.Objects.Hex_Object_Id) return String is
         Full : constant String := Version.Objects.To_String (Id);
         N    : constant Natural :=
           Natural'Min (Natural'Max (Options.Abbrev, 4), Full'Length);
      begin
         return Full (Full'First .. Full'First + N - 1);
      end Raw_Id;

      procedure Visit (Path : String; V : Side_Array) is
      begin
         if Kind = Raw_Listing then
            Append (Result, [1 .. Num_Parent => ':']);
            for N in 1 .. Num_Parent loop
               Append (Result, Mode_Image (V (N).Mode) & " ");
            end loop;
            Append (Result, Mode_Image (V (0).Mode));
            for N in 1 .. Num_Parent loop
               Append (Result, " " & Raw_Id (V (N).Id));
            end loop;
            Append (Result, " " & Raw_Id (V (0).Id) & " ");
         end if;
         if Kind /= Name_Only_Listing then
            for N in 1 .. Num_Parent loop
               Append
                 (Result,
                  (if V (0).Mode = 0 then 'D' elsif V (N).Mode = 0 then 'A'
                   else 'M'));
            end loop;
            Append (Result, ASCII.HT);
         end if;
         Append (Result, Path & LF);
      end Visit;

      procedure Run is new Walk_Paths (Visit);
   begin
      if Num_Parent = 0 then
         return "";
      end if;
      Run (Repo, Objects, Commit_Id, Parents, Paths, Pick,
           (if Options.Relative_Set then To_String (Options.Relative) else ""));
      return To_String (Result);
   end Combined_Listing;

   function Combined_Patch
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Options   : Version.Diff.Diff_Options := (others => <>);
      Dense     : Boolean := True;
      Pick      : Version.Pickaxe.Spec := (others => <>)) return String
   is
      Num_Parent : constant Natural := Natural (Parents.Length);
      Objects    : Version.Object_Cache.Object_Cache;
      Result     : Unbounded_String;

      function Content (Which : Side) return String is
      begin
         if Which.Mode = 0 then
            return "";
         elsif Which.Mode = 8#160000# then
            return "Subproject commit " & Version.Objects.To_String (Which.Id) & LF;
         end if;
         return Version.Objects.Content
           (Version.Object_Cache.Read_Object (Repo, Objects, Which.Id));
      end Content;

      function Is_Binary (Text : String) return Boolean is
        (for some C of Text => C = Character'Val (0));

      function Abbrev (Id : Version.Objects.Hex_Object_Id) return String is
        (Abbrev_Id (Repo, Id, Options));

      Src_Prefix : constant String := To_String (Options.Src_Prefix);
      Dst_Prefix : constant String := To_String (Options.Dst_Prefix);

      procedure One_Path (Path : String; V : Side_Array) is
         Ps : Parent_Sides (0 .. Num_Parent - 1);
         Mode_Differs : Boolean := False;
         Result_Text  : constant String := Content (V (0));
         Deleted      : constant Boolean := V (0).Mode = 0;

         procedure Header (Show_File_Header : Boolean) is
            --  "Added" only when the modes differ and no parent had it.
            Added : Boolean := Mode_Differs and then not Deleted;
         begin
            Append
              (Result,
               (if Dense then "diff --cc " else "diff --combined ") & Path & LF);
            Append (Result, "index ");
            for N in 0 .. Num_Parent - 1 loop
               Append (Result, (if N > 0 then "," else "") & Abbrev (Ps (N).Id));
            end loop;
            Append (Result, ".." & Abbrev (V (0).Id) & LF);
            if Mode_Differs then
               for N in 0 .. Num_Parent - 1 loop
                  if Ps (N).Status /= 'A' then
                     Added := False;
                  end if;
               end loop;
               if Added then
                  Append (Result, "new file mode " & Mode_Image (V (0).Mode));
               else
                  if Deleted then
                     Append (Result, "deleted file ");
                  end if;
                  Append (Result, "mode ");
                  for N in 0 .. Num_Parent - 1 loop
                     Append
                       (Result,
                        (if N > 0 then "," else "") & Mode_Image (Ps (N).Mode));
                  end loop;
                  if V (0).Mode /= 0 then
                     Append (Result, ".." & Mode_Image (V (0).Mode));
                  end if;
               end if;
               Append (Result, LF);
            end if;
            if not Show_File_Header then
               return;
            end if;
            Append
              (Result,
               "--- " & (if Added then "/dev/null" else Src_Prefix & Path) & LF);
            Append
              (Result,
               "+++ " & (if Deleted then "/dev/null" else Dst_Prefix & Path) & LF);
         end Header;
      begin
         for N in 0 .. Num_Parent - 1 loop
            Ps (N) :=
              (Id     => V (N + 1).Id,
               Mode   => V (N + 1).Mode,
               Status =>
                 (if Deleted then 'D' elsif V (N + 1).Mode = 0 then 'A' else 'M'));
            if V (N + 1).Mode /= V (0).Mode then
               Mode_Differs := True;
            end if;
         end loop;

         --  Binary on any side: the header and one line.
         declare
            Binary : Boolean := not Options.Diff_Text and then Is_Binary (Result_Text);
         begin
            for N in 0 .. Num_Parent - 1 loop
               exit when Binary or else Options.Diff_Text;
               Binary := Is_Binary (Content (V (N + 1)));
            end loop;
            if Binary then
               Header (False);
               Append (Result, "Binary files differ" & LF);
               return;
            end if;
         end;

         declare
            Lines : constant Version.Merge.Line_Vectors.Vector :=
              Version.Merge.Split_Lines (Result_Text);
            Cnt   : constant Natural := Natural (Lines.Length);
            S     : Survivors (0 .. Cnt + 1);
         begin
            for K in 0 .. Cnt - 1 loop
               declare
                  L : constant String := Lines.Element (K);
               begin
                  S (K).Text :=
                    To_Unbounded_String
                      (if L'Length > 0 and then L (L'Last) = LF
                       then L (L'First .. L'Last - 1) else L);
               end;
            end loop;
            for K in S'Range loop
               S (K).P_Lno := new Line_Numbers'(0 .. Num_Parent - 1 => 0);
            end loop;

            for I in 0 .. Num_Parent - 1 loop
               declare
                  Reused : Boolean := False;
               begin
                  for J in 0 .. I - 1 loop
                     if Version.Objects.To_String (Ps (I).Id)
                        = Version.Objects.To_String (Ps (J).Id)
                     then
                        Reuse (S, Cnt, I, J);
                        Reused := True;
                        exit;
                     end if;
                  end loop;
                  if not Reused and then not Deleted then
                     Diff_Parent
                       (Content (V (I + 1)), Result_Text, S, Cnt, I, Options);
                  end if;
               end;
            end loop;

            if Make_Hunks (S, Cnt, Num_Parent, Options.Context_Lines, Dense)
              or else Mode_Differs
            then
               Header (True);
               if not Deleted then
                  Dump (Result, S, Cnt, Num_Parent, Options.Context_Lines, "");
               end if;
            end if;
         end;
      end One_Path;
      procedure Run is new Walk_Paths (One_Path);
   begin
      if Num_Parent = 0 then
         return "";
      end if;
      Run (Repo, Objects, Commit_Id, Parents, Paths, Pick,
           (if Options.Relative_Set then To_String (Options.Relative) else ""));
      return To_String (Result);
   end Combined_Patch;

end Version.Combine_Diff;
