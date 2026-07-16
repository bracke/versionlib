with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Version.Files;
with Version.History;
with Version.Objects; use Version.Objects;

package body Version.Bisect is

   package Str renames Ada.Strings.Fixed;

   ----------------------------------------------------------------------------
   --  Small string-set / string-keyed helpers.

   package String_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=",
      "="                 => "=");

   package String_Nat_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Natural,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   ----------------------------------------------------------------------------
   --  File-path helpers under the git dir.

   function GD (Repo : Version.Repository.Repository_Handle) return String
   is (Version.Repository.Git_Dir (Repo));

   function Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is (Version.Files.Join (GD (Repo), Name));

   function Exists
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean
   is (Ada.Directories.Exists
         (Version.Files.To_Native_Path (Path (Repo, Name))));

   function Read (Repo : Version.Repository.Repository_Handle; Name : String)
      return String
   is (Version.Files.Read_Binary_File (Path (Repo, Name)));

   function First_Line (S : String) return String is
      NL : constant Natural := Str.Index (S, "" & ASCII.LF);
   begin
      if NL = 0 then
         return S;
      else
         return S (S'First .. NL - 1);
      end if;
   end First_Line;

   ----------------------------------------------------------------------------

   function Default_Terms return Terms is
   begin
      return (Bad  => To_Unbounded_String ("bad"),
              Good => To_Unbounded_String ("good"));
   end Default_Terms;

   function In_Progress
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is (Exists (Repo, "BISECT_START"));

   function Current_Terms
     (Repo : Version.Repository.Repository_Handle) return Terms is
   begin
      if not Exists (Repo, "BISECT_TERMS") then
         return Default_Terms;
      end if;
      declare
         Content : constant String := Read (Repo, "BISECT_TERMS");
         NL      : constant Natural := Str.Index (Content, "" & ASCII.LF);
      begin
         if NL = 0 then
            return Default_Terms;
         end if;
         declare
            Bad_Term  : constant String := Content (Content'First .. NL - 1);
            Rest      : constant String := Content (NL + 1 .. Content'Last);
            Good_Term : constant String := First_Line (Rest);
         begin
            return (Bad  => To_Unbounded_String (Bad_Term),
                    Good => To_Unbounded_String (Good_Term));
         end;
      end;
   end Current_Terms;

   function Start_Ref
     (Repo : Version.Repository.Repository_Handle) return String
   is (First_Line (Read (Repo, "BISECT_START")));

   ----------------------------------------------------------------------------
   --  refs/bisect/* access.

   function Bisect_Refs_Dir
     (Repo : Version.Repository.Repository_Handle) return String
   is (Version.Files.Join (GD (Repo), "refs/bisect"));

   function Ref_Value
     (Repo : Version.Repository.Repository_Handle; Ref_Name : String)
      return Hex_Object_Id
   is (To_Object_Id
         (First_Line
            (Version.Files.Read_Binary_File
               (Version.Files.Join (Bisect_Refs_Dir (Repo), Ref_Name)))));

   procedure Write_Ref
     (Repo : Version.Repository.Repository_Handle;
      Ref_Name : String; Id : Hex_Object_Id) is
   begin
      Version.Files.Create_Directory_If_Missing (Bisect_Refs_Dir (Repo));
      Version.Files.Write_Binary_File_Atomic
        (Path    => Version.Files.Join (Bisect_Refs_Dir (Repo), Ref_Name),
         Content => To_String (Id) & ASCII.LF);
   end Write_Ref;

   function Has_Bad
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is (Ada.Directories.Exists
         (Version.Files.To_Native_Path
            (Version.Files.Join
               (Bisect_Refs_Dir (Repo),
                To_String (Current_Terms (Repo).Bad)))));

   function Bad_Id
     (Repo : Version.Repository.Repository_Handle) return Hex_Object_Id
   is (Ref_Value (Repo, To_String (Current_Terms (Repo).Bad)));

   --  Collect refs/bisect entries whose name starts with Prefix, returning the
   --  oids they point at.
   function Collect
     (Repo : Version.Repository.Repository_Handle; Prefix : String)
      return Id_Vectors.Vector
   is
      Result : Id_Vectors.Vector;
      Dir    : constant String :=
        Version.Files.To_Native_Path (Bisect_Refs_Dir (Repo));
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      use Ada.Directories;
   begin
      if not Ada.Directories.Exists (Dir) then
         return Result;
      end if;
      Start_Search (Search, Dir, "",
                    [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Simple_Name (Item);
         begin
            if Name'Length > Prefix'Length
              and then Name (Name'First .. Name'First + Prefix'Length - 1)
                       = Prefix
            then
               Result.Append (Ref_Value (Repo, Name));
            end if;
         end;
      end loop;
      End_Search (Search);
      return Result;
   end Collect;

   function Good_Ids
     (Repo : Version.Repository.Repository_Handle) return Id_Vectors.Vector
   is (Collect (Repo, To_String (Current_Terms (Repo).Good) & "-"));

   function Skip_Ids
     (Repo : Version.Repository.Repository_Handle) return Id_Vectors.Vector
   is (Collect (Repo, "skip-"));

   function Good_Count
     (Repo : Version.Repository.Repository_Handle) return Natural
   is (Natural (Good_Ids (Repo).Length));

   procedure Mark_Good
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id) is
   begin
      Write_Ref (Repo, To_String (Current_Terms (Repo).Good)
                 & "-" & To_String (Id), Id);
   end Mark_Good;

   procedure Mark_Bad
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id) is
   begin
      Write_Ref (Repo, To_String (Current_Terms (Repo).Bad), Id);
   end Mark_Bad;

   procedure Mark_Skip
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id) is
   begin
      Write_Ref (Repo, "skip-" & To_String (Id), Id);
   end Mark_Skip;

   ----------------------------------------------------------------------------
   --  BISECT_LOG.

   procedure Append_Log
     (Repo : Version.Repository.Repository_Handle; Line : String)
   is
      Existing : constant String :=
        (if Exists (Repo, "BISECT_LOG") then Read (Repo, "BISECT_LOG") else "");
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => Path (Repo, "BISECT_LOG"),
         Content => Existing & Line & ASCII.LF);
   end Append_Log;

   function Read_Log
     (Repo : Version.Repository.Repository_Handle) return String
   is (if Exists (Repo, "BISECT_LOG") then Read (Repo, "BISECT_LOG") else "");

   ----------------------------------------------------------------------------

   procedure Start
     (Repo      : Version.Repository.Repository_Handle;
      Start_Ref : String;
      Term_Bad  : String;
      Term_Good : String) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path (Repo, "BISECT_START"), Start_Ref & ASCII.LF);
      Version.Files.Write_Binary_File_Atomic
        (Path (Repo, "BISECT_NAMES"), "" & ASCII.LF);
      Version.Files.Write_Binary_File_Atomic
        (Path (Repo, "BISECT_TERMS"),
         Term_Bad & ASCII.LF & Term_Good & ASCII.LF);
   end Start;

   procedure Set_Terms
     (Repo      : Version.Repository.Repository_Handle;
      Term_Bad  : String;
      Term_Good : String) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path (Repo, "BISECT_TERMS"),
         Term_Bad & ASCII.LF & Term_Good & ASCII.LF);
   end Set_Terms;

   procedure Clear (Repo : Version.Repository.Repository_Handle) is
      procedure Del (Name : String) is
      begin
         Version.Files.Delete_File_If_Exists (Path (Repo, Name));
      end Del;
   begin
      Del ("BISECT_START");
      Del ("BISECT_NAMES");
      Del ("BISECT_TERMS");
      Del ("BISECT_LOG");
      Del ("BISECT_EXPECTED_REV");
      Del ("BISECT_ANCESTORS_OK");
      Version.Files.Delete_Directory_Tree_If_Exists (Bisect_Refs_Dir (Repo));
   end Clear;

   ----------------------------------------------------------------------------
   --  Steps estimate: git reports k where the step-k boundary follows
   --  b(1)=3, b(k)=2*b(k-1) - (1 if k odd else 0).  Verified byte-identical to
   --  `git rev-list --bisect-vars` for candidate sets of size 1..129.

   function Estimate_Steps (All_N : Natural) return Natural is
      B : Natural := 3;
      K : Natural := 1;
   begin
      if All_N < 3 then
         return 0;
      end if;
      while B <= All_N loop
         K := K + 1;
         B := 2 * B - (if K mod 2 = 1 then 1 else 0);
      end loop;
      return K - 1;
   end Estimate_Steps;

   ----------------------------------------------------------------------------
   --  Committer timestamp of a commit (seconds); 0 if unparsable.  Candidate
   --  ordering is oldest-timestamp-first, which reproduces git's
   --  rev-list-reversed order for histories with distinct increasing dates.

   function Commit_Time
     (Repo : Version.Repository.Repository_Handle; Id : Hex_Object_Id)
      return Long_Long_Integer
   is
      Obj  : constant Git_Object := Version.Objects.Read_Object (Repo, Id);
      Body_Text : constant String := Version.Objects.Content (Obj);
      Key  : constant String := ASCII.LF & "committer ";
      Pos  : constant Natural := Str.Index (Body_Text, Key);
   begin
      if Pos = 0 then
         return 0;
      end if;
      declare
         Line_End : constant Natural := Str.Index
           (Body_Text (Pos + Key'Length .. Body_Text'Last), "" & ASCII.LF);
         Line     : constant String :=
           (if Line_End = 0
            then Body_Text (Pos + Key'Length .. Body_Text'Last)
            else Body_Text (Pos + Key'Length .. Line_End - 1));
         --  "Name <email> <ts> <tz>": timestamp is the second-to-last token.
         Last_Sp  : constant Natural := Str.Index (Line, " ", Ada.Strings.Backward);
      begin
         if Last_Sp = 0 then
            return 0;
         end if;
         declare
            Before_Tz : constant String := Line (Line'First .. Last_Sp - 1);
            Ts_Sp     : constant Natural :=
              Str.Index (Before_Tz, " ", Ada.Strings.Backward);
         begin
            if Ts_Sp = 0 then
               return 0;
            end if;
            return Long_Long_Integer'Value
              (Before_Tz (Ts_Sp + 1 .. Before_Tz'Last));
         exception
            when others =>
               return 0;
         end;
      end;
   end Commit_Time;

   ----------------------------------------------------------------------------

   function Compute
     (Repo : Version.Repository.Repository_Handle) return Bisection
   is
      Result : Bisection;
      Goods  : constant Id_Vectors.Vector := Good_Ids (Repo);
   begin
      if not Has_Bad (Repo) and then Goods.Is_Empty then
         Result.Kind := Need_Both;
         return Result;
      elsif not Has_Bad (Repo) then
         Result.Kind := Need_Bad;
         return Result;
      elsif Goods.Is_Empty then
         Result.Kind := Need_Good;
         return Result;
      end if;

      --  Both endpoints known: build the candidate set S = commits reachable
      --  from bad but not from any good.
      declare
         Bad     : constant Hex_Object_Id := Bad_Id (Repo);
         Skipped : constant Id_Vectors.Vector := Skip_Ids (Repo);

         Good_Closure : String_Sets.Set;   --  ancestors-or-self of any good
         In_S         : String_Sets.Set;   --  candidate membership
         S            : Id_Vectors.Vector; --  candidates, in discovery order

         function Is_Skipped (Hex : String) return Boolean is
         begin
            for Sk of Skipped loop
               if To_String (Sk) = Hex then
                  return True;
               end if;
            end loop;
            return False;
         end Is_Skipped;

         procedure Add_Closure (Root : Hex_Object_Id) is
            Stack : Id_Vectors.Vector;
         begin
            Stack.Append (Root);
            while not Stack.Is_Empty loop
               declare
                  C   : constant Hex_Object_Id := Stack.Last_Element;
                  Hex : constant String := To_String (C);
               begin
                  Stack.Delete_Last;
                  if not Good_Closure.Contains (Hex) then
                     Good_Closure.Insert (Hex);
                     for P of Version.History.Parent_Commits (Repo, C) loop
                        Stack.Append (P);
                     end loop;
                  end if;
               end;
            end loop;
         end Add_Closure;
      begin
         for G of Goods loop
            Add_Closure (G);
         end loop;

         --  Walk from bad, collecting commits not in the good closure.
         declare
            Stack : Id_Vectors.Vector;
         begin
            Stack.Append (Bad);
            while not Stack.Is_Empty loop
               declare
                  C   : constant Hex_Object_Id := Stack.Last_Element;
                  Hex : constant String := To_String (C);
               begin
                  Stack.Delete_Last;
                  if not Good_Closure.Contains (Hex)
                    and then not In_S.Contains (Hex)
                  then
                     In_S.Insert (Hex);
                     S.Append (C);
                     for P of Version.History.Parent_Commits (Repo, C) loop
                        Stack.Append (P);
                     end loop;
                  end if;
               end;
            end loop;
         end;

         Result.All_N := Natural (S.Length);

         --  Found: the only remaining candidate is the bad commit itself.
         if Result.All_N <= 1 then
            Result.Kind := Found;
            Result.Rev  := Bad;
            Result.Left := 0;
            Result.Steps := 0;
            return Result;
         end if;

         --  Weight of each candidate = number of S-commits reachable from it
         --  (ancestors-or-self within S).
         declare
            Weight : String_Nat_Maps.Map;

            function Reach (C : Hex_Object_Id) return Natural is
               Seen  : String_Sets.Set;
               Stack : Id_Vectors.Vector;
            begin
               Stack.Append (C);
               while not Stack.Is_Empty loop
                  declare
                     X   : constant Hex_Object_Id := Stack.Last_Element;
                     Hex : constant String := To_String (X);
                  begin
                     Stack.Delete_Last;
                     if In_S.Contains (Hex) and then not Seen.Contains (Hex)
                     then
                        Seen.Insert (Hex);
                        for P of Version.History.Parent_Commits (Repo, X) loop
                           Stack.Append (P);
                        end loop;
                     end if;
                  end;
               end loop;
               return Natural (Seen.Length);
            end Reach;

            --  Order candidates oldest-first (by committer timestamp, then oid)
            --  to match git's tie-breaking.
            Order : Id_Vectors.Vector := S;

            function Older (L, R : Hex_Object_Id) return Boolean is
               TL : constant Long_Long_Integer := Commit_Time (Repo, L);
               TR : constant Long_Long_Integer := Commit_Time (Repo, R);
            begin
               if TL /= TR then
                  return TL < TR;
               else
                  return To_String (L) < To_String (R);
               end if;
            end Older;

            package Id_Sorting is new Id_Vectors.Generic_Sorting ("<" => Older);

            Best        : Hex_Object_Id := Bad;
            Best_Weight : Natural := 0;
            Best_Dist   : Integer := -1;
            Have_Best   : Boolean := False;
         begin
            for C of S loop
               Weight.Insert (To_String (C), Reach (C));
            end loop;

            Id_Sorting.Sort (Order);

            --  git reverses the rev-list, so candidates are visited
            --  oldest-first; the first commit reaching the maximum distance
            --  wins (strict >).  The lone exception is a 3-candidate range,
            --  where git tests the middle (larger-reach) commit of the tie.
            for C of Order loop
               declare
                  Hex  : constant String := To_String (C);
                  W    : constant Natural := Weight (Hex);
                  Dist : constant Integer :=
                    Integer'Min (W, Result.All_N - W);
               begin
                  if not Is_Skipped (Hex)
                    and then
                      (Dist > Best_Dist
                       or else (Result.All_N = 3
                                and then Dist = Best_Dist
                                and then W > Best_Weight))
                  then
                     Best_Dist   := Dist;
                     Best        := C;
                     Best_Weight := W;
                     Have_Best   := True;
                  end if;
               end;
            end loop;

            if not Have_Best then
               Result.Kind := Only_Skipped;
               return Result;
            end if;

            Result.Kind  := Continue;
            Result.Rev   := Best;
            Result.Left  := Result.All_N - Best_Weight - 1;
            Result.Steps := Estimate_Steps (Result.All_N);
            return Result;
         end;
      end;
   end Compute;

   ----------------------------------------------------------------------------

   function Status_Text
     (Repo : Version.Repository.Repository_Handle;
      Kind : Status_Kind) return String
   is
   begin
      case Kind is
         when Need_Both =>
            return "waiting for both good and bad commits";
         when Need_Good =>
            return "waiting for good commit(s), bad commit known";
         when Need_Bad =>
            declare
               N : constant Natural := Good_Count (Repo);
               function Img (V : Natural) return String is
                  S : constant String := Natural'Image (V);
               begin
                  return S (S'First + 1 .. S'Last);
               end Img;
            begin
               return "waiting for bad commit, " & Img (N)
                 & (if N = 1 then " good commit known"
                    else " good commits known");
            end;
         when others =>
            return "";
      end case;
   end Status_Text;

end Version.Bisect;
