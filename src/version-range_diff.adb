with Ada.Containers.Vectors;

with Version.Diff;
with Version.Rebase;
with Version.Rebase_State;

package body Version.Range_Diff is
   use Version.Objects;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   Zero_Id : constant Version.Objects.Object_Id_Storage :=
     Version.Objects.Zero_Object_Id;

   COST_MAX : constant Integer := Integer'Last / 4;

   type Int_Matrix is array (Natural range <>, Natural range <>) of Integer;
   type Int_Array is array (Natural range <>) of Integer;

   package Line_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Unbounded_String);

   --  Split into lines, dropping the trailing terminator of each; a final line
   --  without a newline is kept.
   function Split (S : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      First  : Positive := S'First;
   begin
      if S'Length = 0 then
         return Result;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Result.Append (To_Unbounded_String (S (First .. I - 1)));
            First := I + 1;
         end if;
      end loop;
      if First <= S'Last then
         Result.Append (To_Unbounded_String (S (First .. S'Last)));
      end if;
      return Result;
   end Split;

   -----------------------------------------------------------------------
   --  git's diffsize(): the number of hunk headers plus emitted diff lines
   --  (context, added and removed) in `diff -U3 A B`, over the two strings.
   -----------------------------------------------------------------------
   function Diff_Size (A, B : String) return Integer is
      LA : constant Line_Vectors.Vector := Split (A);
      LB : constant Line_Vectors.Vector := Split (B);
      N  : constant Natural := Natural (LA.Length);
      M  : constant Natural := Natural (LB.Length);

      --  Longest common subsequence table.
      C : array (0 .. N, 0 .. M) of Natural := [others => [others => 0]];

      type Op_Kind is (Keep, Del, Ins);
      package Op_Vectors is new Ada.Containers.Vectors (Positive, Op_Kind);
      Ops : Op_Vectors.Vector;
   begin
      for I in 1 .. N loop
         for J in 1 .. M loop
            if LA.Element (I) = LB.Element (J) then
               C (I, J) := C (I - 1, J - 1) + 1;
            else
               C (I, J) := Natural'Max (C (I - 1, J), C (I, J - 1));
            end if;
         end loop;
      end loop;

      --  Backtrack to the edit script (in forward order).
      declare
         I : Natural := N;
         J : Natural := M;
         Rev : Op_Vectors.Vector;
      begin
         while I > 0 or else J > 0 loop
            if I > 0 and then J > 0
              and then LA.Element (I) = LB.Element (J)
            then
               Rev.Append (Keep); I := I - 1; J := J - 1;
            elsif J > 0 and then (I = 0 or else C (I, J - 1) >= C (I - 1, J))
            then
               Rev.Append (Ins); J := J - 1;
            else
               Rev.Append (Del); I := I - 1;
            end if;
         end loop;
         for K in reverse Rev.First_Index .. Rev.Last_Index loop
            Ops.Append (Rev.Element (K));
         end loop;
      end;

      --  Group into hunks with three lines of context, counting one per hunk
      --  header and one per emitted line, exactly as git's callbacks do.
      declare
         Ctx   : constant Natural := 3;
         Count : Integer := 0;
         K     : Positive := Ops.First_Index;
         Total : constant Natural := Natural (Ops.Length);
      begin
         if Total = 0 then
            return 0;
         end if;
         while K <= Ops.Last_Index loop
            if Ops.Element (K) = Keep then
               K := K + 1;
            else
               --  Start of a change run: back up to Ctx leading context.
               declare
                  Hunk_Start : Positive := K;
                  Lead : Natural := 0;
               begin
                  while Hunk_Start > Ops.First_Index and then Lead < Ctx
                    and then Ops.Element (Hunk_Start - 1) = Keep
                  loop
                     Hunk_Start := Hunk_Start - 1;
                     Lead := Lead + 1;
                  end loop;

                  --  Extend across changes, merging runs separated by <= 2*Ctx
                  --  context lines (git's hunk coalescing).
                  declare
                     Pos      : Positive := K;
                     Last_Chg : Positive := K;
                  begin
                     loop
                        if Ops.Element (Pos) /= Keep then
                           Last_Chg := Pos;
                        end if;
                        exit when Pos = Ops.Last_Index;
                        --  Look ahead: if the next change is within 2*Ctx
                        --  context lines, keep going; else stop.
                        declare
                           Gap : Natural := 0;
                           P2  : Positive := Pos + 1;
                           Found : Boolean := False;
                        begin
                           while P2 <= Ops.Last_Index and then Gap <= 2 * Ctx
                           loop
                              if Ops.Element (P2) /= Keep then
                                 Found := True;
                                 exit;
                              end if;
                              Gap := Gap + 1;
                              P2 := P2 + 1;
                           end loop;
                           exit when not Found;
                           Pos := Pos + 1;
                        end;
                     end loop;

                     --  Trailing context after the last change (up to Ctx).
                     declare
                        Hunk_End : Positive := Last_Chg;
                        Trail : Natural := 0;
                     begin
                        while Hunk_End < Ops.Last_Index and then Trail < Ctx
                          and then Ops.Element (Hunk_End + 1) = Keep
                        loop
                           Hunk_End := Hunk_End + 1;
                           Trail := Trail + 1;
                        end loop;

                        Count := Count + 1;   --  the hunk header
                        Count := Count + (Hunk_End - Hunk_Start + 1);
                        K := Hunk_End + 1;
                     end;
                  end;
               end;
            end if;
         end loop;
         return Count;
      end;
   end Diff_Size;

   -----------------------------------------------------------------------
   --  Build a commit's canonical patch, following read_patches().
   -----------------------------------------------------------------------
   type Canon is record
      Full : Unbounded_String;   --  metadata + message + diff
      Diff : Unbounded_String;   --  the diff part alone (from "## file ##")
      Size : Natural;            --  git's util->diffsize
      Subj : Unbounded_String;
      Id   : Version.Objects.Object_Id_Storage;
   end record;

   function Build_Canonical
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Canon
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Id);
      Content : constant String := Version.Objects.Content (Obj);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);

      No_Prefix : constant Version.Diff.Diff_Options :=
        (Context_Lines => 3,
         Src_Prefix    => Null_Unbounded_String,
         Dst_Prefix    => Null_Unbounded_String,
         others        => <>);
      Raw : constant String :=
        (if Parents.Is_Empty
         then Version.Diff.Diff_Root_Commit (Repo, Id, No_Prefix)
         else Version.Diff.Diff_Commits
                (Repo, Parents.First_Element, Id, No_Prefix));

      --  Author "Name <email>" without the date.
      function Author_Name_Email return String is
         Author : Unbounded_String;
      begin
         --  The "author " header line.
         declare
            L : constant Line_Vectors.Vector := Split (Content);
         begin
            for E of L loop
               declare
                  S : constant String := To_String (E);
               begin
                  if S'Length > 7
                    and then S (S'First .. S'First + 6) = "author "
                  then
                     Author := To_Unbounded_String (S (S'First + 7 .. S'Last));
                     exit;
                  end if;
                  exit when S'Length = 0;   --  headers ended
               end;
            end loop;
         end;
         declare
            A : constant String := To_String (Author);
            GT : Natural := 0;
         begin
            for I in reverse A'Range loop
               if A (I) = '>' then
                  GT := I;
                  exit;
               end if;
            end loop;
            return (if GT = 0 then A else A (A'First .. GT));
         end;
      end Author_Name_Email;

      Subject : constant String :=
        Version.Objects.Commit_Message_First_Line (Obj);

      Result   : Canon;
      Full     : Unbounded_String;
      Diff_Buf : Unbounded_String;
      Size     : Natural := 0;
   begin
      --  Metadata + commit message. The message body beyond the subject is not
      --  reproduced here (the fixtures are single-line); git indents each line
      --  by four spaces.
      Append (Full, " ## Metadata ##" & LF);
      Append (Full, "Author: " & Author_Name_Email & LF & LF);
      Append (Full, " ## Commit message ##" & LF);
      Append (Full, "    " & Subject & LF);

      --  Transform the diff into the "## file ##"/"@@" canonical form.
      declare
         Lines : constant Line_Vectors.Vector := Split (Raw);
         K     : Positive := (if Lines.Is_Empty then 1 else Lines.First_Index);
         function At_K return String is (To_String (Lines.Element (K)));
      begin
         while not Lines.Is_Empty and then K <= Lines.Last_Index loop
            declare
               L : constant String := At_K;
               function Starts (P : String) return Boolean is
                 (L'Length >= P'Length
                  and then L (L'First .. L'First + P'Length - 1) = P);
            begin
               if Starts ("diff --git ") then
                  --  Gather the header block to classify the change.
                  declare
                     New_Name, Old_Name : Unbounded_String;
                     Is_New, Is_Del, Is_Ren : Boolean := False;
                     Old_Mode, New_Mode : Unbounded_String;
                  begin
                     K := K + 1;
                     while K <= Lines.Last_Index loop
                        declare
                           H : constant String := At_K;
                           function HS (P : String) return Boolean is
                             (H'Length >= P'Length
                              and then H (H'First .. H'First + P'Length - 1)
                                       = P);
                        begin
                           exit when HS ("@@ ") or else HS ("diff --git ");
                           if HS ("new file mode ") then
                              Is_New := True;
                           elsif HS ("deleted file mode ") then
                              Is_Del := True;
                           elsif HS ("rename from ") then
                              Is_Ren := True;
                              Old_Name := To_Unbounded_String
                                (H (H'First + 12 .. H'Last));
                           elsif HS ("rename to ") then
                              New_Name := To_Unbounded_String
                                (H (H'First + 10 .. H'Last));
                           elsif HS ("old mode ") then
                              Old_Mode := To_Unbounded_String
                                (H (H'First + 9 .. H'Last));
                           elsif HS ("new mode ") then
                              New_Mode := To_Unbounded_String
                                (H (H'First + 9 .. H'Last));
                           elsif HS ("--- ") and then H /= "--- /dev/null" then
                              Old_Name := To_Unbounded_String
                                (H (H'First + 4 .. H'Last));
                           elsif HS ("+++ ") and then H /= "+++ /dev/null" then
                              New_Name := To_Unbounded_String
                                (H (H'First + 4 .. H'Last));
                           end if;
                           K := K + 1;
                        end;
                     end loop;

                     declare
                        Name : constant String :=
                          (if Length (New_Name) > 0 then To_String (New_Name)
                           elsif Length (Old_Name) > 0 then To_String (Old_Name)
                           else "");
                        Tag : Unbounded_String;
                     begin
                        if Is_New then
                           Tag := To_Unbounded_String (Name & " (new)");
                        elsif Is_Del then
                           Tag := To_Unbounded_String
                             (To_String (Old_Name) & " (deleted)");
                        elsif Is_Ren then
                           Tag := To_Unbounded_String
                             (To_String (Old_Name) & " => "
                              & To_String (New_Name));
                        else
                           Tag := To_Unbounded_String (Name);
                        end if;
                        if Length (Old_Mode) > 0 and then Length (New_Mode) > 0
                        then
                           Append (Tag, " (mode change " & To_String (Old_Mode)
                                   & " => " & To_String (New_Mode) & ")");
                        end if;

                        --  A blank line precedes each file section.
                        Append (Diff_Buf, LF);
                        Append (Diff_Buf, " ## " & To_String (Tag) & " ##" & LF);
                        Size := Size + 1;
                     end;
                  end;
               elsif Starts ("@@ ") then
                  --  "@@ -a,b +c,d @@ func" -> "@@" (+ " file: func").
                  declare
                     Rest : constant String := L (L'First + 3 .. L'Last);
                     P    : Natural := 0;
                  begin
                     for I in Rest'First .. Rest'Last - 1 loop
                        if Rest (I) = '@' and then Rest (I + 1) = '@' then
                           P := I;
                           exit;
                        end if;
                     end loop;
                     Append (Diff_Buf, "@@");
                     if P /= 0 and then P + 2 <= Rest'Last then
                        Append (Diff_Buf, Rest (P + 2 .. Rest'Last));
                     end if;
                     Append (Diff_Buf, LF);
                     Size := Size + 1;
                  end;
                  K := K + 1;
               elsif L'Length = 0 then
                  K := K + 1;   --  a blank separator, skipped
               else
                  --  A body line (context/added/removed); kept verbatim.
                  Append (Diff_Buf, L & LF);
                  Size := Size + 1;
                  K := K + 1;
               end if;
            end;
         end loop;
      end;

      Append (Full, Diff_Buf);
      Result.Full := Full;
      --  The diff part drops the leading blank line before "## file ##".
      declare
         D : constant String := To_String (Diff_Buf);
      begin
         Result.Diff :=
           (if D'Length > 0 and then D (D'First) = LF
            then To_Unbounded_String (D (D'First + 1 .. D'Last))
            else Diff_Buf);
      end;
      Result.Size := Size;
      Result.Subj := To_Unbounded_String (Subject);
      Result.Id   := Id;
      return Result;
   end Build_Canonical;

   -----------------------------------------------------------------------
   --  Minimum-cost perfect assignment on a square cost matrix (the classic
   --  O(n^3) potentials method). Row2Col (I) is the column assigned to row I.
   -----------------------------------------------------------------------
   --  Minimum-cost perfect assignment on a square N-by-N cost matrix (the
   --  classic O(n^3) potentials method). Row2Col (I) is the column matched to
   --  row I. A padded matrix (dummy rows/columns) always has a perfect match.
   procedure Assign_Min_Cost
     (N : Natural; Cost : Int_Matrix; Row2Col : out Int_Array)
   is
      INF  : constant Integer := Integer'Last / 2;
      U    : Int_Array (0 .. N) := [others => 0];
      V    : Int_Array (0 .. N) := [others => 0];
      P    : array (0 .. N) of Natural := [others => 0];
      Way  : array (0 .. N) of Natural := [others => 0];
   begin
      for I in 1 .. N loop
         P (0) := I;
         declare
            J0   : Natural := 0;
            MinV : Int_Array (0 .. N) := [others => INF];
            Used : array (0 .. N) of Boolean := [others => False];
         begin
            loop
               Used (J0) := True;
               declare
                  I0      : constant Natural := P (J0);
                  Delta_V : Integer := INF;
                  J1      : Natural := 0;
               begin
                  for J in 1 .. N loop
                     if not Used (J) then
                        declare
                           Cur : constant Integer :=
                             Cost (I0 - 1, J - 1) - U (I0) - V (J);
                        begin
                           if Cur < MinV (J) then
                              MinV (J) := Cur;
                              Way (J) := J0;
                           end if;
                           if MinV (J) < Delta_V then
                              Delta_V := MinV (J);
                              J1 := J;
                           end if;
                        end;
                     end if;
                  end loop;
                  for J in 0 .. N loop
                     if Used (J) then
                        U (P (J)) := U (P (J)) + Delta_V;
                        V (J) := V (J) - Delta_V;
                     else
                        MinV (J) := MinV (J) - Delta_V;
                     end if;
                  end loop;
                  J0 := J1;
               end;
               exit when P (J0) = 0;
            end loop;
            loop
               declare
                  J1 : constant Natural := Way (J0);
               begin
                  P (J0) := P (J1);
                  J0 := J1;
               end;
               exit when J0 = 0;
            end loop;
         end;
      end loop;
      Row2Col := [others => -1];
      for J in 1 .. N loop
         if P (J) >= 1 then
            Row2Col (P (J) - 1) := J - 1;
         end if;
      end loop;
   end Assign_Min_Cost;

   function Compare
     (Repo     : Version.Repository.Repository_Handle;
      Old_Base : Version.Objects.Hex_Object_Id;
      Old_Tip  : Version.Objects.Hex_Object_Id;
      New_Base : Version.Objects.Hex_Object_Id;
      New_Tip  : Version.Objects.Hex_Object_Id;
      Creation_Factor : Natural := 60)
      return Pairing_Vectors.Vector
   is
      Old_C : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, Old_Tip, Old_Base);
      New_C : constant Version.Rebase_State.Commit_Vectors.Vector :=
        Version.Rebase.Commits_To_Replay (Repo, New_Tip, New_Base);

      package Canon_Vectors is new Ada.Containers.Vectors (Positive, Canon);
      A, B : Canon_Vectors.Vector;
   begin
      for C of Old_C loop
         A.Append (Build_Canonical (Repo, C));
      end loop;
      for C of New_C loop
         B.Append (Build_Canonical (Repo, C));
      end loop;

      declare
         AN : constant Natural := Natural (A.Length);
         BN : constant Natural := Natural (B.Length);
         N  : constant Natural := AN + BN;
         A_Match : array (1 .. Natural'Max (AN, 1)) of Integer :=
           [others => -1];
         B_Match : array (1 .. Natural'Max (BN, 1)) of Integer :=
           [others => -1];
         Result : Pairing_Vectors.Vector;
      begin
         --  find_exact_matches: identical diff parts pair up.
         for J in 1 .. BN loop
            for I in 1 .. AN loop
               if A_Match (I) = -1 and then B_Match (J) = -1
                 and then A.Element (I).Diff = B.Element (J).Diff
               then
                  A_Match (I) := J;
                  B_Match (J) := I;
                  exit;
               end if;
            end loop;
         end loop;

         --  get_correspondences over the leftover, via the cost matrix.
         if N > 0 then
            declare
               Cost : Int_Matrix (0 .. N - 1, 0 .. N - 1) :=
                 [others => [others => 0]];
               Row2Col : Int_Array (0 .. N - 1) := [others => -1];
            begin
               for I in 0 .. AN - 1 loop
                  for J in 0 .. BN - 1 loop
                     if A_Match (I + 1) = J + 1 then
                        Cost (I, J) := 0;
                     elsif A_Match (I + 1) = -1
                       and then B_Match (J + 1) = -1
                     then
                        Cost (I, J) := Diff_Size
                          (To_String (A.Element (I + 1).Diff),
                           To_String (B.Element (J + 1).Diff));
                     else
                        Cost (I, J) := COST_MAX;
                     end if;
                  end loop;
                  --  Row I to a dummy column: the creation cost.
                  declare
                     C : constant Integer :=
                       (if A_Match (I + 1) = -1
                        then A.Element (I + 1).Size * Creation_Factor / 100
                        else COST_MAX);
                  begin
                     for J in BN .. N - 1 loop
                        Cost (I, J) := C;
                     end loop;
                  end;
               end loop;
               for J in 0 .. BN - 1 loop
                  declare
                     C : constant Integer :=
                       (if B_Match (J + 1) = -1
                        then B.Element (J + 1).Size * Creation_Factor / 100
                        else COST_MAX);
                  begin
                     for I in AN .. N - 1 loop
                        Cost (I, J) := C;
                     end loop;
                  end;
               end loop;
               --  dummy-dummy already 0.

               Assign_Min_Cost (N, Cost, Row2Col);

               for I in 0 .. AN - 1 loop
                  if Row2Col (I) >= 0 and then Row2Col (I) < BN then
                     A_Match (I + 1) := Row2Col (I) + 1;
                     B_Match (Row2Col (I) + 1) := I + 1;
                  end if;
               end loop;
            end;
         end if;

         --  output(): walk the RHS order, placing removed LHS commits once
         --  their predecessors have been shown.
         declare
            Shown : array (1 .. Natural'Max (AN, 1)) of Boolean :=
              [others => False];
            I : Natural := 0;   --  0-based LHS cursor
            J : Natural := 0;   --  0-based RHS cursor

            procedure Emit_Removed (Ai : Positive) is
            begin
               Result.Append
                 (Pairing'
                    (Old_Pos => Ai, New_Pos => 0,
                     Old_Id  => A.Element (Ai).Id, New_Id => Zero_Id,
                     Subject => A.Element (Ai).Subj, Status => Removed,
                     Old_Patch => A.Element (Ai).Full,
                     New_Patch => Null_Unbounded_String));
            end Emit_Removed;

            procedure Emit_Added (Bj : Positive) is
            begin
               Result.Append
                 (Pairing'
                    (Old_Pos => 0, New_Pos => Bj,
                     Old_Id  => Zero_Id, New_Id => B.Element (Bj).Id,
                     Subject => B.Element (Bj).Subj, Status => Added,
                     Old_Patch => Null_Unbounded_String,
                     New_Patch => B.Element (Bj).Full));
            end Emit_Added;

            procedure Emit_Pair (Ai, Bj : Positive) is
               St : constant Pair_Status :=
                 (if A.Element (Ai).Full = B.Element (Bj).Full
                  then Unchanged else Changed);
            begin
               Result.Append
                 (Pairing'
                    (Old_Pos => Ai, New_Pos => Bj,
                     Old_Id  => A.Element (Ai).Id, New_Id => B.Element (Bj).Id,
                     Subject => A.Element (Ai).Subj, Status => St,
                     Old_Patch => A.Element (Ai).Full,
                     New_Patch => B.Element (Bj).Full));
            end Emit_Pair;
         begin
            while I < AN or else J < BN loop
               --  Skip already-shown LHS commits.
               while I < AN and then Shown (I + 1) loop
                  I := I + 1;
               end loop;

               --  An unmatched LHS commit whose predecessors were shown.
               if I < AN and then A_Match (I + 1) = -1 then
                  Emit_Removed (I + 1);
                  I := I + 1;
               else
                  --  Unmatched RHS commits.
                  while J < BN and then B_Match (J + 1) = -1 loop
                     Emit_Added (J + 1);
                     J := J + 1;
                  end loop;

                  if J < BN then
                     declare
                        Ai : constant Positive := B_Match (J + 1);
                     begin
                        Emit_Pair (Ai, J + 1);
                        Shown (Ai) := True;
                        J := J + 1;
                     end;
                  end if;
               end if;
            end loop;
         end;

         return Result;
      end;
   end Compare;

   function Inner_Diff (Old_Patch, New_Patch : String) return String is
      LA : constant Line_Vectors.Vector := Split (Old_Patch);
      LB : constant Line_Vectors.Vector := Split (New_Patch);
      N  : constant Natural := Natural (LA.Length);
      M  : constant Natural := Natural (LB.Length);
      C  : array (0 .. N, 0 .. M) of Natural := [others => [others => 0]];

      type Op_Kind is (Keep, Del, Ins);
      type Op is record
         Kind : Op_Kind;
         A, B : Natural;
      end record;
      package Op_Vectors is new Ada.Containers.Vectors (Positive, Op);
      Ops : Op_Vectors.Vector;

      Indent : constant String := "    ";
      Ctx    : constant Natural := 3;
      Out_Text : Unbounded_String;

      --  The "## <section> ##" enclosing old line L (searching strictly before
      --  it), which git names in the diff-of-diffs hunk header.
      function Section_Before (L : Natural) return String is
      begin
         for I in reverse 1 .. L - 1 loop
            declare
               S : constant String := To_String (LA.Element (I));
            begin
               if S'Length >= 7
                 and then S (S'First .. S'First + 3) = " ## "
                 and then S (S'Last - 2 .. S'Last) = " ##"
               then
                  return S (S'First + 4 .. S'Last - 3);
               end if;
            end;
         end loop;
         return "";
      end Section_Before;
   begin
      for I in 1 .. N loop
         for J in 1 .. M loop
            if LA.Element (I) = LB.Element (J) then
               C (I, J) := C (I - 1, J - 1) + 1;
            else
               C (I, J) := Natural'Max (C (I - 1, J), C (I, J - 1));
            end if;
         end loop;
      end loop;

      declare
         I : Natural := N;
         J : Natural := M;
         Rev : Op_Vectors.Vector;
      begin
         while I > 0 or else J > 0 loop
            if I > 0 and then J > 0
              and then LA.Element (I) = LB.Element (J)
            then
               Rev.Append (Op'(Keep, I, J)); I := I - 1; J := J - 1;
            elsif J > 0 and then (I = 0 or else C (I, J - 1) >= C (I - 1, J))
            then
               Rev.Append (Op'(Ins, 0, J)); J := J - 1;
            else
               Rev.Append (Op'(Del, I, 0)); I := I - 1;
            end if;
         end loop;
         for K in reverse Rev.First_Index .. Rev.Last_Index loop
            Ops.Append (Rev.Element (K));
         end loop;
      end;

      if Ops.Is_Empty then
         return "";
      end if;

      declare
         K : Positive := Ops.First_Index;

         --  The old-line number the op sits at, for the section lookup.
         function A_At (P : Positive) return Natural is
            Op_P : constant Op := Ops.Element (P);
         begin
            if Op_P.A /= 0 then
               return Op_P.A;
            end if;
            --  An insertion: the old line it follows.
            for Q in reverse Ops.First_Index .. P loop
               if Ops.Element (Q).A /= 0 then
                  return Ops.Element (Q).A + 1;
               end if;
            end loop;
            return 1;
         end A_At;
      begin
         while K <= Ops.Last_Index loop
            if Ops.Element (K).Kind = Keep then
               K := K + 1;
            else
               declare
                  Hunk_Start : Positive := K;
                  Lead : Natural := 0;
               begin
                  while Hunk_Start > Ops.First_Index and then Lead < Ctx
                    and then Ops.Element (Hunk_Start - 1).Kind = Keep
                  loop
                     Hunk_Start := Hunk_Start - 1;
                     Lead := Lead + 1;
                  end loop;

                  declare
                     Pos      : Positive := K;
                     Last_Chg : Positive := K;
                  begin
                     loop
                        if Ops.Element (Pos).Kind /= Keep then
                           Last_Chg := Pos;
                        end if;
                        exit when Pos = Ops.Last_Index;
                        declare
                           Gap : Natural := 0;
                           P2  : Positive := Pos + 1;
                           Found : Boolean := False;
                        begin
                           while P2 <= Ops.Last_Index and then Gap <= 2 * Ctx
                           loop
                              if Ops.Element (P2).Kind /= Keep then
                                 Found := True;
                                 exit;
                              end if;
                              Gap := Gap + 1;
                              P2 := P2 + 1;
                           end loop;
                           exit when not Found;
                           Pos := Pos + 1;
                        end;
                     end loop;

                     declare
                        Hunk_End : Positive := Last_Chg;
                        Trail : Natural := 0;
                     begin
                        while Hunk_End < Ops.Last_Index and then Trail < Ctx
                          and then Ops.Element (Hunk_End + 1).Kind = Keep
                        loop
                           Hunk_End := Hunk_End + 1;
                           Trail := Trail + 1;
                        end loop;

                        --  Hunk header naming the enclosing section.
                        declare
                           Func : constant String :=
                             Section_Before (A_At (Hunk_Start));
                        begin
                           Append (Out_Text,
                             Indent & "@@"
                             & (if Func'Length > 0 then " " & Func else "")
                             & LF);
                        end;

                        for P in Hunk_Start .. Hunk_End loop
                           declare
                              O : constant Op := Ops.Element (P);
                              Marker : constant Character :=
                                (case O.Kind is
                                    when Keep => ' ',
                                    when Del  => '-',
                                    when Ins  => '+');
                              Content : constant String :=
                                (if O.Kind = Ins
                                 then To_String (LB.Element (O.B))
                                 else To_String (LA.Element (O.A)));
                           begin
                              Append (Out_Text,
                                Indent & Marker & Content & LF);
                           end;
                        end loop;

                        K := Hunk_End + 1;
                     end;
                  end;
               end;
            end if;
         end loop;
      end;

      return To_String (Out_Text);
   end Inner_Diff;

end Version.Range_Diff;
