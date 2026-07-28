with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.History;
with Version.Objects; use Version.Objects;
with Version.Refs;
with Version.Revisions;

package body Version.Show_Branch is

   package Str renames Ada.Strings.Fixed;

   LF : constant Character := ASCII.LF;

   type Commit_Name is record
      Base : Unbounded_String;
      Gen  : Natural := 0;
   end record;

   package Name_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Commit_Name,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   package Deg_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Natural,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   function Img (V : Natural) return String is
      S : constant String := Natural'Image (V);
   begin
      return S (S'First + 1 .. S'Last);
   end Img;

   function Render (N : Commit_Name) return String is
   begin
      if N.Gen = 0 then
         return To_String (N.Base);
      elsif N.Gen = 1 then
         return To_String (N.Base) & "^";
      else
         return To_String (N.Base) & "~" & Img (N.Gen);
      end if;
   end Render;

   function Subject
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return String
   is (Version.Objects.Commit_Message_First_Line
         (Version.Objects.Read_Object (Repo, Id)));

   --  Committer timestamp (seconds); 0 if unparsable. Used only to order the
   --  initial tips of the topological walk newest-first, as git does.
   function Commit_Time
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return Long_Long_Integer
   is
      Obj  : constant Git_Object := Version.Objects.Read_Object (Repo, Id);
      Text : constant String := Version.Objects.Content (Obj);
      Key  : constant String := LF & "committer ";
      Pos  : constant Natural := Str.Index (Text, Key);
   begin
      if Pos = 0 then
         return 0;
      end if;
      declare
         Rest : constant String := Text (Pos + Key'Length .. Text'Last);
         NL   : constant Natural := Str.Index (Rest, "" & LF);
         Line : constant String :=
           (if NL = 0 then Rest else Rest (Rest'First .. NL - 1));
         Tz   : constant Natural :=
           Str.Index (Line, " ", Ada.Strings.Backward);
      begin
         if Tz = 0 then
            return 0;
         end if;
         declare
            Before : constant String := Line (Line'First .. Tz - 1);
            Sp     : constant Natural :=
              Str.Index (Before, " ", Ada.Strings.Backward);
         begin
            if Sp = 0 then
               return 0;
            end if;
            return Long_Long_Integer'Value (Before (Sp + 1 .. Before'Last));
         exception
            when others => return 0;
         end;
      end;
   end Commit_Time;

   function Format
     (Repo      : Version.Repository.Repository_Handle;
      Branches  : Name_Vectors.Vector;
      List_Only : Boolean := False) return String
   is
      N : constant Natural := Natural (Branches.Length);

      Tips     : array (1 .. N) of Hex_Object_Id;
      Cur_Name : constant String :=
        (if Version.Refs.Is_Detached (Repo) then ""
         else Version.Refs.Current_Branch_Name (Repo));
      Cur_Idx  : Natural := 0;   --  1-based arg index of the current branch

      Result : Unbounded_String;
   begin
      for I in 1 .. N loop
         Tips (I) := Version.Revisions.Resolve_Commit (Repo, Branches (I));
         if Branches (I) = Cur_Name then
            Cur_Idx := I;
         end if;
      end loop;

      --  `--list`: head list only, current marked with '*'.
      if List_Only then
         for I in 1 .. N loop
            Append (Result,
                    (if I = Cur_Idx then "*" else " ") & " ["
                    & Branches (I) & "] " & Subject (Repo, Tips (I)) & LF);
         end loop;
         return To_String (Result);
      end if;

      --  A single branch prints just its head line, with no matrix.
      if N = 1 then
         return "[" & Branches (1) & "] " & Subject (Repo, Tips (1)) & LF;
      end if;

      --  Header: line i indented by (i-1) spaces, '*' for the current branch
      --  else '!'.
      for I in 1 .. N loop
         Append (Result,
                 String'(1 .. I - 1 => ' ')
                 & (if I = Cur_Idx then "*" else "!")
                 & " [" & Branches (I) & "] "
                 & Subject (Repo, Tips (I)) & LF);
      end loop;
      Append (Result, String'(1 .. N => '-') & LF);

      --  Commit set: everything reachable from a tip, down to and including the
      --  branches' merge base M (ancestors of M are dropped).
      declare
         package CIV renames Version.History.Commit_Id_Vectors;

         M : Hex_Object_Id := Tips (1);

         Set   : CIV.Vector;
         Names : Name_Maps.Map;

         function In_Set (Hex : String) return Boolean is
         begin
            for C of Set loop
               if To_String (C) = Hex then
                  return True;
               end if;
            end loop;
            return False;
         end In_Set;

         function Reaches (C : Hex_Object_Id; Tip : Hex_Object_Id)
           return Boolean
         is (C = Tip or else Version.History.Is_Ancestor (Repo, C, Tip));
      begin
         for J in 2 .. N loop
            M := Version.History.Merge_Base (Repo, M, Tips (J));
         end loop;

         --  Collect the set by walking parents from each tip, stopping at M.
         declare
            Stack : CIV.Vector;
            M_Hex : constant String := To_String (M);
         begin
            for J in 1 .. N loop
               Stack.Append (Tips (J));
            end loop;
            while not Stack.Is_Empty loop
               declare
                  C   : constant Hex_Object_Id := Stack.Last_Element;
                  Hex : constant String := To_String (C);
               begin
                  Stack.Delete_Last;
                  --  Drop strict ancestors of M; keep M and everything above.
                  if not In_Set (Hex)
                    and then (Hex = M_Hex
                              or else not Version.History.Is_Ancestor
                                            (Repo, C, M))
                  then
                     Set.Append (C);
                     if Hex /= M_Hex then
                        for P of Version.History.Parent_Commits (Repo, C) loop
                           Stack.Append (P);
                        end loop;
                     end if;
                  end if;
               end;
            end loop;
         end;

         --  Order the matrix as git does: it sorts the collected commits in
         --  topological order (children before parents) with a LIFO stack
         --  seeded from the tips in argument order -- git's
         --  sort_in_topological_order in REV_SORT_IN_GRAPH_ORDER, whose
         --  prio_queue has no comparator and so behaves as a stack. A plain
         --  newest-date sort disagrees whenever one branch's tip is older than
         --  a commit reachable only from another branch.
         declare
            Indeg   : Deg_Maps.Map;
            Stack   : CIV.Vector;
            Ordered : CIV.Vector;
         begin
            for C of Set loop
               Indeg.Include (To_String (C), 0);
            end loop;
            --  Indegree = number of children within the set.
            for C of Set loop
               for P of Version.History.Parent_Commits (Repo, C) loop
                  declare
                     PH : constant String := To_String (P);
                  begin
                     if Indeg.Contains (PH) then
                        Indeg.Replace (PH, Indeg (PH) + 1);
                     end if;
                  end;
               end loop;
            end loop;
            --  Seed the stack with the childless tips. The tip processed
            --  first (top of the stack, appended last) is the newest by
            --  committer date, and on a date tie the latest argument -- git
            --  starts its topological walk from a date-priority queue whose
            --  ties break toward the later-listed branch (visible when every
            --  commit shares one date).
            declare
               Ready : array (1 .. N) of Natural := [others => 0];
               Count : Natural := 0;
            begin
               for J in 1 .. N loop
                  declare
                     TH  : constant String := To_String (Tips (J));
                     Dup : Boolean := False;
                  begin
                     if Indeg.Contains (TH) and then Indeg (TH) = 0 then
                        for K in 1 .. Count loop
                           if To_String (Tips (Ready (K))) = TH then
                              Dup := True;
                           end if;
                        end loop;
                        if not Dup then
                           Count := Count + 1;
                           Ready (Count) := J;
                        end if;
                     end if;
                  end;
               end loop;
               --  Selection sort so position 1 (pushed first, bottom) is the
               --  oldest / later-argument tip and the last position (top) is
               --  the newest / earliest-argument one.
               for A in 1 .. Count loop
                  declare
                     Sel : Natural := A;
                  begin
                     for B in A + 1 .. Count loop
                        declare
                           TB : constant Long_Long_Integer :=
                             Commit_Time (Repo, Tips (Ready (B)));
                           TS : constant Long_Long_Integer :=
                             Commit_Time (Repo, Tips (Ready (Sel)));
                        begin
                           if TB < TS
                             or else (TB = TS
                                      and then Ready (B) < Ready (Sel))
                           then
                              Sel := B;
                           end if;
                        end;
                     end loop;
                     if Sel /= A then
                        declare
                           Tmp : constant Natural := Ready (A);
                        begin
                           Ready (A) := Ready (Sel);
                           Ready (Sel) := Tmp;
                        end;
                     end if;
                  end;
               end loop;
               for A in 1 .. Count loop
                  Stack.Append (Tips (Ready (A)));
               end loop;
            end;
            while not Stack.Is_Empty loop
               declare
                  C : constant Hex_Object_Id := Stack.Last_Element;
               begin
                  Stack.Delete_Last;
                  Ordered.Append (C);
                  for P of Version.History.Parent_Commits (Repo, C) loop
                     declare
                        PH : constant String := To_String (P);
                     begin
                        if Indeg.Contains (PH) then
                           Indeg.Replace (PH, Indeg (PH) - 1);
                           if Indeg (PH) = 0 then
                              Stack.Append (P);
                           end if;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
            Set := Ordered;
         end;

         --  Seed names at the tips, then propagate first-parent names in
         --  display order until stable (first namer wins).
         for J in 1 .. N loop
            if not Names.Contains (To_String (Tips (J))) then
               Names.Insert
                 (To_String (Tips (J)),
                  (Base => To_Unbounded_String (Branches (J)), Gen => 0));
            end if;
         end loop;
         declare
            Changed : Boolean := True;
         begin
            while Changed loop
               Changed := False;
               for C of Set loop
                  declare
                     Hex : constant String := To_String (C);
                  begin
                     if Names.Contains (Hex) then
                        declare
                           Parents : constant CIV.Vector :=
                             Version.History.Parent_Commits (Repo, C);
                        begin
                           if not Parents.Is_Empty then
                              declare
                                 P     : constant Hex_Object_Id :=
                                   Parents.First_Element;
                                 P_Hex : constant String := To_String (P);
                                 Cur   : constant Commit_Name := Names (Hex);
                              begin
                                 if In_Set (P_Hex)
                                   and then not Names.Contains (P_Hex)
                                 then
                                    Names.Insert
                                      (P_Hex,
                                       (Base => Cur.Base, Gen => Cur.Gen + 1));
                                    Changed := True;
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end loop;
         end;

         --  Emit one matrix row per commit.
         for C of Set loop
            declare
               Hex     : constant String := To_String (C);
               Is_Merge : constant Boolean :=
                 Natural (Version.History.Parent_Commits (Repo, C).Length) > 1;
               Markers : String (1 .. N);
            begin
               for J in 1 .. N loop
                  if Reaches (C, Tips (J)) then
                     Markers (J) :=
                       (if Is_Merge then '-'
                        elsif J = Cur_Idx then '*' else '+');
                  else
                     Markers (J) := ' ';
                  end if;
               end loop;
               Append (Result,
                       Markers & " ["
                       & (if Names.Contains (Hex) then Render (Names (Hex))
                          else Hex (Hex'First .. Hex'First + 6))
                       & "] " & Subject (Repo, C) & LF);
            end;
         end loop;
      end;

      return To_String (Result);
   end Format;

end Version.Show_Branch;
