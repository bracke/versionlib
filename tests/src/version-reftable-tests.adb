with AUnit.Assertions;         use AUnit.Assertions;
with AUnit.Test_Cases;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Version.Objects;
with Version.Files;
with Version.Refs;
with Version.Repository;
with Version.Reftable.Writer;
with Version.Ref_Transaction;
with Version.Ref_Cache;
with Version.Tags;
with Version.Init;
with Version.Git_Fixtures;
with Version.Test_Support;

package body Version.Reftable.Tests is

   LF : constant Character := Character'Val (10);

   --  git show-ref lines are "<oid> SP <refname>"; find the oid for Name.
   function Oid_For
     (Show_Ref : String; Name : String) return String
   is
      use Ada.Strings.Fixed;
      Start : Natural := Show_Ref'First;

      function Match (Line : String) return Boolean is
         Sp : constant Natural := Index (Line, " ");
      begin
         return Sp > 0 and then Line (Sp + 1 .. Line'Last) = Name;
      end Match;
   begin
      for I in Show_Ref'Range loop
         if Show_Ref (I) = LF then
            if Match (Show_Ref (Start .. I - 1)) then
               return Show_Ref (Start .. Index (Show_Ref (Start .. I - 1), " ") - 1);
            end if;
            Start := I + 1;
         end if;
      end loop;
      --  Final line (Read_Text_File drops the trailing newline).
      if Start <= Show_Ref'Last
        and then Match (Show_Ref (Start .. Show_Ref'Last))
      then
         return Show_Ref
           (Start .. Index (Show_Ref (Start .. Show_Ref'Last), " ") - 1);
      end if;
      return "";
   end Oid_For;

   procedure Reader_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Version.Objects;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Version.Git_Fixtures.Run (Root, "git tag lite");
      Version.Git_Fixtures.Run (Root, "git tag -a annot -m rel");
      --  Compact the stack into a single table so we parse one file, and
      --  capture git's own ref list as the oracle.
      Version.Git_Fixtures.Run (Root, "git pack-refs --all");
      Version.Git_Fixtures.Run (Root, "git show-ref > sr.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         RT_Dir   : constant String :=
           Version.Test_Support.Join (Root, ".git/reftable");
         List     : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (RT_Dir, "tables.list"));
         --  After pack-refs the stack is a single table; take that one line.
         LF_At    : constant Natural := Ada.Strings.Fixed.Index (List, "" & LF);
         Table    : constant String :=
           (if LF_At > 0 then List (List'First .. LF_At - 1) else List);
         Bytes    : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (RT_Dir, Table));
         Show_Ref : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Root, "sr.txt"));
         Refs     : constant Ref_Record_Vectors.Vector :=
           Parse_Table (Bytes, 20);
         Head_Ok  : Boolean := False;
         Count    : Natural := 0;
      begin
         for R of Refs loop
            declare
               Name : constant String := To_String (R.Name);
            begin
               if Name = "HEAD" then
                  Assert (R.Kind = Ref_Symref
                          and then To_String (R.Target) = "refs/heads/main",
                          "HEAD should be a symref to refs/heads/main");
                  Head_Ok := True;
               else
                  Count := Count + 1;
                  Assert (R.Id = Oid_For (Show_Ref, Name),
                          "oid mismatch for " & Name & ": got "
                          & Version.Objects.To_String (R.Id)
                          & " expected " & Oid_For (Show_Ref, Name));
               end if;
            end;
         end loop;

         Assert (Head_Ok, "HEAD not present in reftable");
         Assert (Count = 4,
                 "expected 4 non-HEAD refs (main, feature, lite, annot), got"
                 & Count'Image);
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Reader_Matches_Git;

   --  Exercise the Version.Refs read seam (Repository.Open now accepts
   --  reftable) against real git on a reftable-backed repo.
   procedure Refs_Seam_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Version.Objects;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Version.Git_Fixtures.Run (Root, "git rev-parse HEAD > head.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
         Want : constant String := Ada.Strings.Fixed.Trim
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "head.txt")),
            Ada.Strings.Right);
         Branches : constant Version.Refs.Branch_Name_Vectors.Vector :=
           Version.Refs.List_Branches (Repo);
         Saw_Main, Saw_Feature : Boolean := False;
      begin
         Assert (Version.Refs.Is_Attached (Head)
                 and then Version.Refs.Branch_Name (Head) = "main",
                 "HEAD should be attached to main");
         Assert (Version.Refs.Current_Commit_Id (Repo) = Want,
                 "current commit id should match git rev-parse HEAD");
         Assert (Version.Refs.Resolve_Ref (Repo, "refs/heads/main") = Want,
                 "Resolve_Ref refs/heads/main should match git");
         Assert (Version.Refs.Resolve_Ref (Repo, "refs/heads/feature") = Want,
                 "Resolve_Ref refs/heads/feature should match git");
         Assert (Version.Refs.Ref_Exists (Repo, "refs/heads/feature"),
                 "feature branch should exist");
         Assert (not Version.Refs.Ref_Exists (Repo, "refs/heads/nope"),
                 "absent branch should not exist");

         for B of Branches loop
            declare
               Name : constant String :=
                 Ada.Strings.Unbounded.To_String (B);
            begin
               Saw_Main    := Saw_Main    or else Name = "main";
               Saw_Feature := Saw_Feature or else Name = "feature";
            end;
         end loop;
         Assert (Saw_Main and then Saw_Feature,
                 "List_Branches should include main and feature");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Refs_Seam_Matches_Git;

   --  version writes a reftable; git must read it back. Rewrite the stack
   --  with the live set plus a new branch, then confirm git lists it.
   procedure Writer_Round_Trips_Through_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Git_Fixtures.Run (Root, "git tag -a annot -m rel");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Refs : Ref_Record_Vectors.Vector := Live_Refs (Repo);
         Main : Ref_Record;
         New_Ref : Ref_Record;
      begin
         for R of Refs loop
            if To_String (R.Name) = "refs/heads/main" then
               Main := R;
            end if;
         end loop;

         New_Ref.Name := To_Unbounded_String ("refs/heads/written");
         New_Ref.Kind := Ref_Direct;
         New_Ref.Id   := Main.Id;
         Refs.Append (New_Ref);

         Version.Reftable.Writer.Write_Stack (Repo, Refs);
      end;

      --  git reads version's table: it must list the injected branch (and the
      --  annotated tag must still peel), and the repo must fsck clean.
      Version.Git_Fixtures.Run (Root, "git show-ref > sr.txt");
      Version.Git_Fixtures.Run (Root, "git rev-parse --verify refs/heads/written");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-parse refs/heads/written)"" = "
               & """$(git rev-parse refs/heads/main)""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-parse annot^{commit})"" = "
               & """$(git rev-parse refs/heads/main)""");
      Version.Git_Fixtures.Run (Root, "git fsck");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Writer_Round_Trips_Through_Git;

   --  Ref mutations through the normal seam (Ref_Transaction + HEAD writers)
   --  land in the reftable stack and are visible to git.
   procedure Transaction_Write_Read_By_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Main : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, "refs/heads/main");
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         --  Create a branch via a transaction.
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update (Tx, "refs/heads/topic", Main);
         Version.Ref_Transaction.Commit (Tx);

         --  Move HEAD to it.
         Version.Refs.Write_Symbolic_HEAD (Repo, "refs/heads/topic");
      end;

      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-parse refs/heads/topic)"" = "
               & """$(git rev-parse refs/heads/main)""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git symbolic-ref HEAD)"" = ""refs/heads/topic""");
      Version.Git_Fixtures.Run (Root, "git fsck");

      --  Delete the branch through a transaction (switch HEAD off it first).
      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Tx   : Version.Ref_Transaction.Transaction;
      begin
         Version.Refs.Write_Symbolic_HEAD (Repo, "refs/heads/main");
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete (Tx, "refs/heads/topic");
         Version.Ref_Transaction.Commit (Tx);
      end;

      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git for-each-ref refs/heads/topic)""");
      Version.Git_Fixtures.Run (Root, "git fsck");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Transaction_Write_Read_By_Git;

   --  The cache/tag read layers (used by log, tag list, for-each-ref) route
   --  through reftable, not loose files.
   procedure Cache_And_Tags_Read_Reftable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Git_Fixtures.Run (Root, "git tag lite");
      Version.Git_Fixtures.Run (Root, "git rev-parse HEAD > head.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cache : Version.Ref_Cache.Ref_Cache;
         Want  : constant String := Ada.Strings.Fixed.Trim
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "head.txt")),
            Ada.Strings.Right);
         Tags  : constant Version.Tags.Tag_Name_Vectors.Vector :=
           Version.Tags.List_Tags;
         Saw_Lite : Boolean := False;
      begin
         Assert (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = Want,
                 "Ref_Cache.Current_Commit_Id should match git rev-parse HEAD");
         for Tg of Tags loop
            Saw_Lite := Saw_Lite
              or else Ada.Strings.Unbounded.To_String (Tg) = "lite";
         end loop;
         Assert (Saw_Lite, "List_Tags should include the reftable tag 'lite'");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cache_And_Tags_Read_Reftable;

   --  version init --ref-format=reftable creates a stack git can operate on.
   procedure Init_Creates_Git_Readable_Reftable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init
        (Path        => Root,
         Ref_Storage => Version.Init.Reftable);

      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      --  Fresh reftable repo: HEAD symref lives in the table, resolvable by git.
      Version.Git_Fixtures.Run
        (Root, "test ""$(git symbolic-ref HEAD)"" = ""refs/heads/main""");
      --  git can commit into version's stack and fsck it clean.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-parse --verify refs/heads/main)"" != """"");
      Version.Git_Fixtures.Run (Root, "git fsck");
      pragma Unreferenced (Old_Dir);
   end Init_Creates_Git_Readable_Reftable;

   --  version reads git's reftable reflog (log blocks) for HEAD.
   procedure Log_Reader_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Version.Objects;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c2");
      Version.Git_Fixtures.Run (Root, "git rev-parse HEAD > head.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Want : constant String := Ada.Strings.Fixed.Trim
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "head.txt")),
            Ada.Strings.Right);
         Logs : constant Log_Record_Vectors.Vector :=
           Log_For (Repo, "HEAD");
         Newest_Ok, Oldest_Ok : Boolean := False;
      begin
         Assert (Natural (Logs.Length) = 2,
                 "HEAD reflog should have 2 entries, got" & Logs.Length'Image);
         --  Newest first: c2 with new id = HEAD, then c1 (initial).
         if not Logs.Is_Empty then
            declare
               Newest : constant Log_Record := Logs.First_Element;
               Oldest : constant Log_Record := Logs.Last_Element;
            begin
               Newest_Ok := Newest.New_Id = Want
                 and then Ada.Strings.Fixed.Index
                            (To_String (Newest.Message), "c2") > 0;
               Oldest_Ok :=
                 Ada.Strings.Fixed.Index
                   (To_String (Oldest.Message), "c1") > 0
                 and then Oldest.Old_Id = To_String (Zero_Object_Id);
            end;
         end if;
         Assert (Newest_Ok,
                 "newest HEAD reflog entry should be c2 pointing at HEAD");
         Assert (Oldest_Ok,
                 "oldest HEAD reflog entry should be the initial c1 commit");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Reader_Matches_Git;

   --  version writes a reflog entry into a log block; git reflog reads it.
   procedure Log_Writer_Read_By_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Refs : constant Ref_Record_Vectors.Vector := Live_Refs (Repo);
         Main : Ref_Record;
         Logs : Log_Record_Vectors.Vector;
         Log  : Log_Record;
      begin
         for R of Refs loop
            if To_String (R.Name) = "refs/heads/main" then
               Main := R;
            end if;
         end loop;

         Log.Ref_Name        := To_Unbounded_String ("HEAD");
         Log.Update_Index    := 9;
         Log.New_Id          := Main.Id;
         Log.Committer_Name  := To_Unbounded_String ("T");
         Log.Committer_Email := To_Unbounded_String ("t@e.c");
         Log.Time_Seconds    := 1_700_000_000;
         Log.TZ_Offset       := 0;
         Log.Message         := To_Unbounded_String ("testmsg: hello");
         Logs.Append (Log);

         Version.Reftable.Writer.Write_Stack (Repo, Refs, Logs);
      end;

      Version.Git_Fixtures.Run (Root, "git reflog show HEAD > rl.txt");
      Version.Git_Fixtures.Run (Root, "grep -q 'testmsg: hello' rl.txt");
      Version.Git_Fixtures.Run (Root, "git fsck");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Writer_Read_By_Git;

   --  Many incremental ref updates stay git-readable and the stack stays
   --  bounded by geometric compaction (not one table per update).
   procedure Compaction_Bounds_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Version.Objects;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init --ref-format=reftable -q .");
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.c");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "hi" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Main : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, "refs/heads/main");
      begin
         --  20 create/delete transaction pairs -> 40 appended tables absent
         --  compaction.
         for I in 1 .. 20 loop
            declare
               Tx : Version.Ref_Transaction.Transaction;
            begin
               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Update
                 (Tx, "refs/heads/topic", Main);
               Version.Ref_Transaction.Commit (Tx);
            end;
            declare
               Tx : Version.Ref_Transaction.Transaction;
            begin
               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Delete (Tx, "refs/heads/topic");
               Version.Ref_Transaction.Commit (Tx);
            end;
         end loop;

         Assert (Natural (Version.Reftable.Stack_Table_Names (Repo).Length) <= 8,
                 "compaction should keep the stack small; tables ="
                 & Version.Reftable.Stack_Table_Names (Repo).Length'Image);
         Assert (Version.Refs.Resolve_Ref (Repo, "refs/heads/main") = Main,
                 "main should still resolve after compaction");
         Assert (not Version.Refs.Ref_Exists (Repo, "refs/heads/topic"),
                 "topic should be deleted (tombstone survives compaction)");
      end;

      Version.Git_Fixtures.Run (Root, "git fsck");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git for-each-ref refs/heads/topic)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Compaction_Bounds_Stack;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Reader_Matches_Git'Access,
         "reftable reader matches git show-ref");
      Register_Routine
        (T, Compaction_Bounds_Stack'Access,
         "reftable geometric compaction keeps the stack bounded");
      Register_Routine
        (T, Log_Writer_Read_By_Git'Access,
         "git reflog reads a version-written log block");
      Register_Routine
        (T, Log_Reader_Matches_Git'Access,
         "reftable log reader matches git reflog");
      Register_Routine
        (T, Init_Creates_Git_Readable_Reftable'Access,
         "version init --ref-format=reftable is git-readable");
      Register_Routine
        (T, Cache_And_Tags_Read_Reftable'Access,
         "reftable read via ref-cache and tag list");
      Register_Routine
        (T, Transaction_Write_Read_By_Git'Access,
         "git reads version reftable ref transactions");
      Register_Routine
        (T, Refs_Seam_Matches_Git'Access,
         "reftable Version.Refs read seam matches git");
      Register_Routine
        (T, Writer_Round_Trips_Through_Git'Access,
         "git reads a version-written reftable");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Reftable");
   end Name;

end Version.Reftable.Tests;
