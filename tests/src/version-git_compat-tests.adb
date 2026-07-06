with Ada.Directories;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Archive;
with Version.Branch;
with Version.Cherry_Pick;
with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Rebase;
with Version.Repository;
with Version.Restore;
with Version.Test_Support;
with Version.Write;
with Version.Revert;

package body Version.Git_Compat.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   procedure Configure_User (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_User;

   procedure Init_Version_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
   end Init_Version_Repo;

   procedure Save_File
     (Root    : String;
      Path    : String;
      Content : String;
      Message : String)
   is
   begin
      Version.Test_Support.Write_Text_File (Join (Root, Path), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Path);
      Version.Write.Save (Message);
   end Save_File;

   procedure Prepare_Rebase_Conflict (Root : String) is
   begin
      Save_File (Root, "conflict.txt", "base" & LF, "base");
      Version.Branch.Create_Branch ("feature");

      Save_File (Root, "conflict.txt", "main" & LF, "main change");

      Version.Branch.Switch_Branch ("feature");
      Save_File (Root, "conflict.txt", "feature" & LF, "feature change");
   end Prepare_Rebase_Conflict;

   procedure Start_Conflicting_Rebase is
      Raised : Boolean := False;
   begin
      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "conflicting rebase must pause before continuation");
   end Start_Conflicting_Rebase;

   procedure Resolve_And_Continue_Rebase (Root : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Join (Root, "conflict.txt"), "resolved" & LF);
      Version.Rebase.Continue_Rebase;
   end Resolve_And_Continue_Rebase;

   function Current_Commit return String is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   begin
      return Version.Refs.Current_Commit_Id (Repo);
   end Current_Commit;

   procedure Save_And_Amend_Are_Git_Fsck_Strict_Readable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & LF, "initial via version");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "two" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save_Amend ("amended via version");

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log --format=%s -1)"" = ""amended via version""");
      Version.Git_Fixtures.Run (Root, "git cat-file -p HEAD >/dev/null");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Save_And_Amend_Are_Git_Fsck_Strict_Readable;

   procedure Git_Status_Clean_After_Version_Restore_Stage_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "dirty" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Version.Restore.Restore_Staged_Path ("a.txt");
      Version.Restore.Restore_Path ("a.txt");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Branch.Switch_Branch ("main");

      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Status_Clean_After_Version_Restore_Stage_Branch;

   procedure Git_Checkout_Reads_Version_Created_History
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "first" & LF, "first");
      Save_File (Root, "a.txt", "second" & LF, "second");

      Version.Git_Fixtures.Run (Root, "git checkout -q HEAD~1");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "first",
         "git checkout must read the first Version-created commit");
      Version.Git_Fixtures.Run (Root, "git checkout -q main");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "second",
         "git checkout must read the latest Version-created commit");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Checkout_Reads_Version_Created_History;

   procedure Git_Log_And_Fsck_Read_Version_Revert_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Changed : String (1 .. 40);
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "base" & LF, "base");
      Save_File (Root, "a.txt", "changed" & LF, "change to revert");
      Changed := Current_Commit;

      Version.Revert.Start (Changed);

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run (Root, "git log --oneline -1 | grep 'Revert'");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
         "Version revert commit must leave Git-readable reverted content");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Log_And_Fsck_Read_Version_Revert_Commit;

   procedure Git_Log_And_Fsck_Read_Version_Cherry_Pick_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Feature_Commit : String (1 .. 40);
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Save_File (Root, "feature.txt", "feature" & LF, "feature commit");
      Feature_Commit := Current_Commit;
      Version.Branch.Switch_Branch ("main");

      Version.Cherry_Pick.Start (Feature_Commit);

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log --format=%s -1)"" = ""feature commit""");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree -r --name-only HEAD | grep '^feature.txt$'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Log_And_Fsck_Read_Version_Cherry_Pick_Commit;

   procedure Git_Fsck_Strict_After_Version_Rebase_Continue
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Prepare_Rebase_Conflict (Root);
      Start_Conflicting_Rebase;
      Resolve_And_Continue_Rebase (Root);

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run (Root, "git cat-file -p HEAD >/dev/null");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log --format=%s -1)"" = ""feature change""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Fsck_Strict_After_Version_Rebase_Continue;

   procedure Git_Log_Reads_Version_Rebase_Continuation_History
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Prepare_Rebase_Conflict (Root);
      Start_Conflicting_Rebase;
      Resolve_And_Continue_Rebase (Root);

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse feature^)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root, "git log --parents -1 feature | grep ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log --format=%s -1 feature)"" = ""feature change""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Log_Reads_Version_Rebase_Continuation_History;

   procedure Git_Status_Clean_After_Version_Rebase_Continue
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Prepare_Rebase_Conflict (Root);
      Start_Conflicting_Rebase;
      Resolve_And_Continue_Rebase (Root);

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git status --porcelain --untracked-files=all)""");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "conflict.txt"))
         = "resolved",
         "Git-readable rebase continuation must preserve resolved content");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Status_Clean_After_Version_Rebase_Continue;

   procedure Git_Checkout_Reads_Version_Rebase_Continuation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Prepare_Rebase_Conflict (Root);
      Start_Conflicting_Rebase;
      Resolve_And_Continue_Rebase (Root);

      Version.Git_Fixtures.Run (Root, "git checkout -q main");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "conflict.txt"))
         = "main",
         "git checkout main must read target branch after Version rebase");
      Version.Git_Fixtures.Run (Root, "git checkout -q feature");
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "conflict.txt"))
         = "resolved",
         "git checkout feature must read Version-created rebase continuation");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Checkout_Reads_Version_Rebase_Continuation;

   procedure Git_Archive_Reads_Version_Created_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Make_Directory (Join (Root, "src"));
      Save_File (Root, "src/main.adb", "procedure Main is null;" & LF, "tree");

      Version.Git_Fixtures.Run (Root, "git archive --format=tar HEAD > git-readable.tar");
      Version.Git_Fixtures.Run
        (Root, "tar -tf git-readable.tar | grep '^src/main.adb$'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Archive_Reads_Version_Created_Tree;

   procedure Git_Submodule_Status_Reads_Version_Gitlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Join (Join (Root, "fixtures"), "submodule-source");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Submodule_Id : String (1 .. 40);
   begin
      Ada.Directories.Create_Path (Source);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git rev-parse HEAD > submodule-id.txt");
      Submodule_Id := Version.Test_Support.Read_Text_File
        (Join (Source, "submodule-id.txt")) (1 .. 40);

      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Join (Root, ".gitmodules"),
         "[submodule ""deps/libfoo""]" & LF
         & Character'Val (9) & "path = deps/libfoo" & LF
         & Character'Val (9) & "url = fixtures/submodule-source" & LF);
      Version.Git_Fixtures.Run (Root, "git add .gitmodules");
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000," & Submodule_Id & ",deps/libfoo");
      Version.Write.Save ("add submodule gitlink");

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "git submodule status | grep '^-' | grep 'deps/libfoo'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Git_Submodule_Status_Reads_Version_Gitlink;

   procedure Version_Archive_Output_Is_Readable_By_Tar
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Init_Version_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "archive" & LF, "archive source");
      Version.Archive.Create
        (Repository => Version.Repository.Open,
         Revision   => "HEAD",
         Output     => Join (Root, "version.tar"),
         Format     => Version.Archive.Tar_Format);

      Version.Git_Fixtures.Run (Root, "tar -tf version.tar | grep '^a.txt$'");
      Version.Git_Fixtures.Run (Root, "tar -xOf version.tar a.txt | grep '^archive$'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Version_Archive_Output_Is_Readable_By_Tar;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Save_And_Amend_Are_Git_Fsck_Strict_Readable'Access,
         "Git compatibility: fsck/log after Version save and amend");
      Register_Routine
        (T,
         Git_Status_Clean_After_Version_Restore_Stage_Branch'Access,
         "Git compatibility: status clean after Version restore/stage/branch switch");
      Register_Routine
        (T,
         Git_Checkout_Reads_Version_Created_History'Access,
         "Git compatibility: git checkout reads Version-created commits");
      Register_Routine
        (T,
         Git_Log_And_Fsck_Read_Version_Revert_Commit'Access,
         "Git compatibility: git log/fsck after Version revert");
      Register_Routine
        (T,
         Git_Log_And_Fsck_Read_Version_Cherry_Pick_Commit'Access,
         "Git compatibility: git log/fsck after Version cherry-pick");
      Register_Routine
        (T,
         Git_Fsck_Strict_After_Version_Rebase_Continue'Access,
         "Git compatibility: fsck after Version rebase continue");
      Register_Routine
        (T,
         Git_Log_Reads_Version_Rebase_Continuation_History'Access,
         "Git compatibility: git log reads Version rebase continuation");
      Register_Routine
        (T,
         Git_Status_Clean_After_Version_Rebase_Continue'Access,
         "Git compatibility: status clean after Version rebase continue");
      Register_Routine
        (T,
         Git_Checkout_Reads_Version_Rebase_Continuation'Access,
         "Git compatibility: git checkout reads Version rebase continuation");
      Register_Routine
        (T,
         Git_Archive_Reads_Version_Created_Tree'Access,
         "Git compatibility: git archive reads Version-created trees");
      Register_Routine
        (T,
         Git_Submodule_Status_Reads_Version_Gitlink'Access,
         "Git compatibility: git submodule status reads Version gitlinks");
      Register_Routine
        (T,
         Version_Archive_Output_Is_Readable_By_Tar'Access,
         "Git compatibility: Version archive output is readable by tar");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Git_Compat");
   end Name;

end Version.Git_Compat.Tests;
