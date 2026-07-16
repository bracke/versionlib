with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Strings.Unbounded;

with Interfaces;

with Version.Files;
with Version.Hash;
with Version.History;
with Version.Objects;
with Version.Refs;
with Version.Revisions;
with Version.Tags;

package body Version.Commit_Graph is

   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   package Id_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Natural,
      Element_Type => String);

   package Index_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Natural,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   package Num_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Interfaces.Unsigned_64,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=",
      "="             => Interfaces."=");

   Graph_Dir_Name : constant String := "info";

   --  The file ends with the hash of everything before it.
   function Raw_Digest
     (Algorithm : Version.Hash.Hash_Algorithm;
      Content   : String)
      return String
   is (case Algorithm is
         when Version.Hash.Sha1   => Version.Hash.Sha1_Raw (Content),
         when Version.Hash.Sha256 => Version.Hash.Sha256_Raw (Content));

   function Graph_Path
     (Repo : Version.Repository.Repository_Handle)
      return String
   is (Version.Files.Join
         (Version.Files.Join
            (Version.Files.Join
               (Version.Repository.Common_Git_Dir (Repo), "objects"),
             Graph_Dir_Name),
          "commit-graph"));

   function Exists (Repo : Version.Repository.Repository_Handle)
     return Boolean
   is (Ada.Directories.Exists (Graph_Path (Repo)));

   --  Big-endian, as everything in the file is.
   function BE32 (Value : Interfaces.Unsigned_32) return String is
      Result : String (1 .. 4);
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val
             (Interfaces.Shift_Right (Value, (4 - I) * 8) and 16#FF#);
      end loop;

      return Result;
   end BE32;

   function BE64 (Value : Interfaces.Unsigned_64) return String is
      Result : String (1 .. 8);
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val
             (Interfaces.Shift_Right (Value, (8 - I) * 8) and 16#FF#);
      end loop;

      return Result;
   end BE64;

   --  The "committer <name> <email> <seconds> <zone>" line's seconds.
   function Commit_Time
     (Repo : Version.Repository.Repository_Handle;
      Id   : String)
      return Interfaces.Unsigned_64
   is
      Data : constant String :=
        Version.Objects.Content
          (Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Id)));
      Pos  : Natural := Data'First;
   begin
      while Pos <= Data'Last loop
         declare
            Stop : constant Natural :=
              Ada.Strings.Fixed.Index (Data, "" & ASCII.LF, Pos);
            Line : constant String :=
              Data (Pos .. (if Stop = 0 then Data'Last else Stop - 1));
         begin
            exit when Line'Length = 0;

            if Line'Length > 10
              and then Line (Line'First .. Line'First + 9) = "committer "
            then
               --  "... <mail> <seconds> <+zone>"
               declare
                  Zone : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Line, " ", Ada.Strings.Backward);
                  Secs : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Line (Line'First .. Zone - 1), " ",
                       Ada.Strings.Backward);
               begin
                  if Secs /= 0 and then Zone > Secs then
                     return Interfaces.Unsigned_64'Value
                       (Line (Secs + 1 .. Zone - 1));
                  end if;
               end;
            end if;

            exit when Stop = 0;
            Pos := Stop + 1;
         end;
      end loop;

      return 0;
   exception
      when others =>
         return 0;
   end Commit_Time;

   -----------
   -- Write --
   -----------

   procedure Write (Repo : Version.Repository.Repository_Handle) is
      Ids : Id_Vectors.Vector;

      procedure Collect_Reachable is
         Pending : Id_Vectors.Vector;
         Seen    : Index_Maps.Map;

         procedure Push (Name : String) is
         begin
            declare
               Tip : constant Version.Objects.Hex_Object_Id :=
                 Version.Revisions.Resolve_Commit (Repo, Name);
            begin
               Pending.Append (Version.Objects.To_String (Tip));
            end;
         exception
            when others =>
               null;
         end Push;

      begin
         for B of Version.Refs.List_Branches (Repo) loop
            Push ("refs/heads/" & To_String (B));
         end loop;

         for T of Version.Tags.List_Tags loop
            Push ("refs/tags/" & To_String (T));
         end loop;

         while not Pending.Is_Empty loop
            declare
               C : constant String := Pending.Last_Element;
            begin
               Pending.Delete_Last;

               if not Seen.Contains (C) then
                  Seen.Insert (C, 0);
                  Ids.Append (C);

                  for P of Version.History.Parent_Commits
                             (Repo, Version.Objects.To_Object_Id (C))
                  loop
                     Pending.Append (Version.Objects.To_String (P));
                  end loop;
               end if;
            end;
         end loop;
      end Collect_Reachable;

   begin
      Collect_Reachable;

      if Ids.Is_Empty then
         return;
      end if;

      --  The file lists the commits in object-id order.
      declare
         Sorted : Id_Vectors.Vector := Ids;
      begin
         for I in Sorted.First_Index + 1 .. Sorted.Last_Index loop
            declare
               Item : constant String := Sorted.Element (I);
               J    : Integer := I - 1;
            begin
               while J >= Sorted.First_Index
                 and then Sorted.Element (J) > Item
               loop
                  Sorted.Replace_Element (J + 1, Sorted.Element (J));
                  J := J - 1;
               end loop;

               Sorted.Replace_Element (J + 1, Item);
            end;
         end loop;

         Ids := Sorted;
      end;

      declare
         N : constant Natural := Natural (Ids.Length);

         Position : Index_Maps.Map;

         --  Generation number v1 (the topological level) and the corrected
         --  commit date, both of which need the parents settled first.
         Level     : Num_Maps.Map;
         Corrected : Num_Maps.Map;

         Fanout : String (1 .. 256 * 4);
         Oids   : Unbounded_String;
         Cdat   : Unbounded_String;
         Gda2   : Unbounded_String;

         --  An octopus merge's third and later parents live in EDGE; CDAT's
         --  second-parent slot then points into it with its top bit set.
         Edge      : Unbounded_String;
         Edge_Next : Interfaces.Unsigned_32 := 0;
      begin
         for I in Ids.First_Index .. Ids.Last_Index loop
            Position.Insert (Ids.Element (I), I);
         end loop;

         --  Parents before children: walk until every commit has its numbers.
         declare
            Remaining : Id_Vectors.Vector := Ids;
         begin
            while not Remaining.Is_Empty loop
               declare
                  Kept     : Id_Vectors.Vector;
                  Progress : Boolean := False;
               begin
                  for C of Remaining loop
                     declare
                        Parents : constant
                          Version.History.Commit_Id_Vectors.Vector :=
                            Version.History.Parent_Commits
                              (Repo, Version.Objects.To_Object_Id (C));

                        Ready : Boolean := True;

                        Max_Level     : Interfaces.Unsigned_64 := 0;
                        Max_Corrected : Interfaces.Unsigned_64 := 0;
                     begin
                        for P of Parents loop
                           declare
                              Hex : constant String :=
                                Version.Objects.To_String (P);
                           begin
                              if Position.Contains (Hex) then
                                 if not Level.Contains (Hex) then
                                    Ready := False;
                                 else
                                    if Level.Element (Hex) > Max_Level then
                                       Max_Level := Level.Element (Hex);
                                    end if;

                                    if Corrected.Element (Hex) > Max_Corrected
                                    then
                                       Max_Corrected := Corrected.Element (Hex);
                                    end if;
                                 end if;
                              end if;
                           end;
                        end loop;

                        if Ready then
                           Level.Include (C, Max_Level + 1);

                           declare
                              Time : constant Interfaces.Unsigned_64 :=
                                Commit_Time (Repo, C);
                           begin
                              --  A commit's corrected date is at least one
                              --  more than every parent's.
                              Corrected.Include
                                (C,
                                 Interfaces.Unsigned_64'Max
                                   (Time, Max_Corrected + 1));
                           end;

                           Progress := True;
                        else
                           Kept.Append (C);
                        end if;
                     end;
                  end loop;

                  exit when not Progress;
                  Remaining := Kept;
               end;
            end loop;
         end;

         --  OIDF: how many ids start with a byte <= i.
         declare
            Counts : array (0 .. 255) of Interfaces.Unsigned_32 :=
              [others => 0];
         begin
            for C of Ids loop
               declare
                  First : constant Natural :=
                    Natural'Value
                      ("16#" & C (C'First .. C'First + 1) & "#");
               begin
                  Counts (First) := Counts (First) + 1;
               end;
            end loop;

            declare
               Running : Interfaces.Unsigned_32 := 0;
               At_Pos  : Positive := Fanout'First;
            begin
               for I in 0 .. 255 loop
                  Running := Running + Counts (I);
                  Fanout (At_Pos .. At_Pos + 3) := BE32 (Running);
                  At_Pos := At_Pos + 4;
               end loop;
            end;
         end;

         for C of Ids loop
            Append (Oids, Version.Objects.To_Raw
                            (Version.Objects.To_Object_Id (C)));

            declare
               Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id (C);

               Tree : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.Commit_Tree_Id
                   (Version.Objects.Read_Object (Repo, Id));

               Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Parent_Commits (Repo, Id);

               No_Parent : constant Interfaces.Unsigned_32 := 16#70000000#;

               P1 : Interfaces.Unsigned_32 := No_Parent;
               P2 : Interfaces.Unsigned_32 := No_Parent;

               Time : constant Interfaces.Unsigned_64 := Commit_Time (Repo, C);
               Gen  : constant Interfaces.Unsigned_64 := Level.Element (C);
            begin
               if Natural (Parents.Length) >= 1 then
                  declare
                     Hex : constant String :=
                       Version.Objects.To_String (Parents.First_Element);
                  begin
                     if Position.Contains (Hex) then
                        P1 := Interfaces.Unsigned_32 (Position.Element (Hex));
                     end if;
                  end;
               end if;

               if Natural (Parents.Length) = 2 then
                  declare
                     Hex : constant String :=
                       Version.Objects.To_String (Parents.Element (1));
                  begin
                     if Position.Contains (Hex) then
                        P2 := Interfaces.Unsigned_32 (Position.Element (Hex));
                     end if;
                  end;

               elsif Natural (Parents.Length) > 2 then
                  --  Point at where this commit's extra edges start; the last
                  --  of them is flagged with the top bit.
                  P2 := 16#80000000# or Edge_Next;

                  for K in Parents.First_Index + 1 .. Parents.Last_Index loop
                     declare
                        Hex : constant String :=
                          Version.Objects.To_String (Parents.Element (K));

                        Slot : Interfaces.Unsigned_32 :=
                          (if Position.Contains (Hex)
                           then Interfaces.Unsigned_32 (Position.Element (Hex))
                           else No_Parent);
                     begin
                        if K = Parents.Last_Index then
                           Slot := Slot or 16#80000000#;
                        end if;

                        Append (Edge, BE32 (Slot));
                        Edge_Next := Edge_Next + 1;
                     end;
                  end loop;
               end if;

               Append (Cdat, Version.Objects.To_Raw (Tree));
               Append (Cdat, BE32 (P1));
               Append (Cdat, BE32 (P2));

               --  The generation takes the top 30 bits; the commit time's top
               --  two bits share the low end of the same word.
               Append
                 (Cdat,
                  BE64
                    (Interfaces.Shift_Left (Gen, 34)
                     or (Time and 16#3FFFFFFFF#)));

               --  GDA2: how far the corrected date had to move.
               Append
                 (Gda2,
                  BE32
                    (Interfaces.Unsigned_32
                       (Corrected.Element (C) - Time)));
            end;
         end loop;

         declare
            Algo : constant Version.Hash.Hash_Algorithm :=
              Version.Repository.Algorithm (Repo);

            Has_Edge : constant Boolean := Length (Edge) > 0;

            Chunks : constant Natural := (if Has_Edge then 5 else 4);

            Header : constant String :=
              "CGPH" & Character'Val (1) & Character'Val (1)
              & Character'Val (Chunks) & Character'Val (0);

            Table_Size : constant Natural := (Chunks + 1) * 12;

            Off_Oidf : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Header'Length + Table_Size);
            Off_Oidl : constant Interfaces.Unsigned_64 :=
              Off_Oidf + Interfaces.Unsigned_64 (Fanout'Length);
            Off_Cdat : constant Interfaces.Unsigned_64 :=
              Off_Oidl + Interfaces.Unsigned_64 (Length (Oids));
            Off_Gda2 : constant Interfaces.Unsigned_64 :=
              Off_Cdat + Interfaces.Unsigned_64 (Length (Cdat));
            Off_Edge : constant Interfaces.Unsigned_64 :=
              Off_Gda2 + Interfaces.Unsigned_64 (Length (Gda2));
            Off_End  : constant Interfaces.Unsigned_64 :=
              Off_Edge + Interfaces.Unsigned_64 (Length (Edge));

            Body_Text : constant String :=
              Header
              & "OIDF" & BE64 (Off_Oidf)
              & "OIDL" & BE64 (Off_Oidl)
              & "CDAT" & BE64 (Off_Cdat)
              & "GDA2" & BE64 (Off_Gda2)
              & (if Has_Edge then "EDGE" & BE64 (Off_Edge) else "")
              & [1 .. 4 => Character'Val (0)] & BE64 (Off_End)
              & Fanout
              & To_String (Oids)
              & To_String (Cdat)
              & To_String (Gda2)
              & To_String (Edge);

            Path : constant String := Graph_Path (Repo);
         begin
            Version.Files.Create_Directory_If_Missing
              (Ada.Directories.Containing_Directory (Path));

            --  git leaves the file read-only; replace it rather than write
            --  through it.
            if Ada.Directories.Exists (Path) then
               Ada.Directories.Delete_File (Path);
            end if;

            Version.Files.Write_Binary_File
              (Path,
               Body_Text & Raw_Digest (Algo, Body_Text));
         end;

         pragma Unreferenced (N);
      end;
   end Write;

   ------------
   -- Verify --
   ------------

   function Verify
     (Repo       : Version.Repository.Repository_Handle;
      Diagnostic : out String;
      Last       : out Natural)
      return Boolean
   is
      procedure Say (Text : String) is
      begin
         Last := Natural'Min (Text'Length, Diagnostic'Length);
         Diagnostic (Diagnostic'First .. Diagnostic'First + Last - 1) :=
           Text (Text'First .. Text'First + Last - 1);
      end Say;

      Path : constant String := Graph_Path (Repo);
   begin
      Last := 0;

      if not Ada.Directories.Exists (Path) then
         --  No graph is not a broken graph.
         return True;
      end if;

      declare
         Data : constant String := Version.Files.Read_Binary_File (Path);

         Algo : constant Version.Hash.Hash_Algorithm :=
           Version.Repository.Algorithm (Repo);

         Raw : constant Natural := Version.Hash.Raw_Length (Algo);
      begin
         if Data'Length < 8 + Raw
           or else Data (Data'First .. Data'First + 3) /= "CGPH"
         then
            Say ("commit-graph file is too small or not a commit-graph");
            return False;
         end if;

         if Raw_Digest (Algo, Data (Data'First .. Data'Last - Raw))
            /= Data (Data'Last - Raw + 1 .. Data'Last)
         then
            Say ("the commit-graph file has incorrect checksum and is likely "
                 & "corrupt");
            return False;
         end if;

         return True;
      end;
   end Verify;

end Version.Commit_Graph;
