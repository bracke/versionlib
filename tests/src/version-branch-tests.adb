with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with AUnit.Test_Cases;
with GNAT.OS_Lib;
with GNAT.Sockets;

with Version.Git_Fixtures;
with Version.History;
with Version.Files;
with Version.Filesystem_Guard;
with Version.Objects;
with Version.Platform;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Revisions;
with Version.Status;
with Version.Stash;
with Version.Staging;
with Version.Test_Support;
with Version.Write;
with Version.Worktrees;
with Version.Init;
with Version.Checkout;
with Version.Merge; use Version.Merge;
with Version.Merge_State;

package body Version.Branch.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Ada.Directories.File_Kind;
   use type Version.Status.Change_Kind;
   use type Version.Platform.Platform_Kind;

   procedure Assert_File_Contains
     (Path : String; Needle : String; Message : String)
   is
      Text : constant String := Version.Test_Support.Read_Text_File (Path);
   begin
      Assert (Ada.Strings.Fixed.Index (Text, Needle) /= 0, Message);
   end Assert_File_Contains;

   procedure Assert_POSIX_Symlink
     (Root : String; Path : String; Target : String)
   is
      Output : constant String :=
        Version.Test_Support.Join (Root, "readlink.out");
   begin
      Version.Git_Fixtures.Run (Root, "test -L " & Path);
      Version.Git_Fixtures.Run (Root, "readlink " & Path & " > readlink.out");
      Assert
        (Version.Test_Support.Read_Text_File (Output) = Target,
         "materialized merge symlink has wrong target");
   end Assert_POSIX_Symlink;

   procedure Configure_Test_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Test_Repo;

   procedure Save_Base_Commit (Root : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
   end Save_Base_Commit;

   procedure Commit_File (Root, Name, Content, Message : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Name), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Name);
      Version.Write.Save (Message);
   end Commit_File;

   function Test_Repo (Root : String) return Version.Repository.Repository_Handle is
   begin
      return Version.Repository.Open_Git_Dir
        (Version.Test_Support.Join (Root, ".git"));
   end Test_Repo;

   function Branch_Reflog_Path (Root, Name : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "refs/heads/" & Name);
   end Branch_Reflog_Path;

   function Branch_Ref_Lock_Path (Root, Name : String) return String is
   begin
      return
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Root, ".git"), "refs"),
              "heads"),
           Name & ".lock");
   end Branch_Ref_Lock_Path;

   function Head_Reflog_Path (Root : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "HEAD");
   end Head_Reflog_Path;

   function Head_Lock_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join (Root, ".git/HEAD.lock");
   end Head_Lock_Path;

   function Head_Reflog_Lock_Path (Root : String) return String is
   begin
      return Head_Reflog_Path (Root) & ".lock";
   end Head_Reflog_Lock_Path;

   function Index_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join (Root, ".git/index");
   end Index_Path;

   function Packed_Refs_Lock_Path (Root : String) return String is
   begin
      return
        Version.Test_Support.Join
          (Version.Test_Support.Join (Root, ".git"), "packed-refs.lock");
   end Packed_Refs_Lock_Path;

   procedure Make_Non_File_Branch_Reflog (Root, Name : String) is
      Log_Path : constant String := Branch_Reflog_Path (Root, Name);
   begin
      Version.Files.Delete_File_If_Exists (Log_Path);
      Ada.Directories.Create_Path (Log_Path);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Log_Path, "sentinel"),
         "keep" & Character'Val (10));
   end Make_Non_File_Branch_Reflog;

   procedure Create_Branch_From_Current_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "hello" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("initial");
      Version.Branch.Create_Branch ("feature");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Current : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Current),
            "current branch commit must be valid");

         Version.Git_Fixtures.Run
           (Root, "git show-ref --verify refs/heads/feature");

         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse feature)"" = ""$(git rev-parse HEAD)""");

         declare
            Feature_Tip : constant String :=
              To_String
                (Version.Refs.Resolve_Ref
                   (Repo => Repo,
                    Name => "refs/heads/feature"));
            Raised      : Boolean := False;
         begin
            begin
               Version.Branch.Create_Branch ("feature");
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Assert
                    (Ada.Exceptions.Exception_Message (E)
                     = "branch already exists: feature",
                     "duplicate branch diagnostic changed: "
                     & Ada.Exceptions.Exception_Message (E));
            end;

            Assert (Raised, "duplicate branch create must be rejected");
            Assert
              (To_String
                 (Version.Refs.Resolve_Ref
                    (Repo => Repo,
                     Name => "refs/heads/feature")) = Feature_Tip,
               "duplicate branch create must preserve existing ref");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Branch_From_Current_Commit;

   procedure Create_Branch_Rejects_Existing_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "hello" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("initial");

      declare
         Lock_Path : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Root, ".git"),
                 "refs/heads"),
              "feature.lock");
         Raised    : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File
           (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Branch.Create_Branch ("feature");
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Strings.Fixed.Index
                    (Ada.Exceptions.Exception_Message (E),
                     "lock file already exists:") /= 0,
                  "branch lock diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;

         Version.Files.Delete_File_If_Exists (Lock_Path);

         Assert (Raised, "branch create must reject an existing lock file");
         Assert
           (not Version.Refs.Ref_Exists
                  (Version.Repository.Open, "refs/heads/feature"),
            "failed branch create must not leave a branch ref");
         Assert
           (not Ada.Directories.Exists
                  (Branch_Reflog_Path (Root, "feature")),
            "failed branch create must not leave a branch reflog");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Branch_Rejects_Existing_Lock;

   procedure Switch_Branch_Restores_Working_Tree_And_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("main");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "main",
         "switching back to main must restore main file content");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");

      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");

      --  Version.Git_Fixtures.Run
      --    (Root,
      --     "git status --porcelain >&2 && test -z ""$(git status --porcelain)""");
      --  Version.Git_Fixtures.Run
      --  (Root,
      --     "test -z ""$(git status --porcelain)""");

      Version.Branch.Switch_Branch ("feature");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "feature",
         "switching to feature must restore feature file content");

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Restores_Working_Tree_And_Index;

   procedure Update_Current_Branch_Advances_Linear_History
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("two");

      Version.Branch.Switch_Branch ("main");

      Version.Branch.Update_Current_Branch ("feature");

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse main)"" = ""$(git rev-parse feature)""");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "two",
         "update must restore advanced branch content");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Update_Current_Branch_Advances_Linear_History;

   procedure Update_Current_Branch_Rejects_Diverged_History
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      --  main diverges
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      --  feature diverges from base
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Update_Current_Branch ("feature");

      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch update must reject diverged histories");

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse main)"" != ""$(git rev-parse feature)""");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "main",
         "rejected update must leave working tree on current branch");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Update_Current_Branch_Rejects_Diverged_History;

   procedure Switch_Branch_Rejects_Modified_Working_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "clean" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "dirty" & Character'Val (10));

      begin
         Version.Branch.Switch_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch switch must reject modified working tree");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "dirty",
         "failed switch must leave modified file untouched");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Rejects_Modified_Working_Tree;

   procedure Switch_Branch_Rejects_Staged_Changes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "clean" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "staged" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      begin
         Version.Branch.Switch_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch switch must reject staged changes");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "staged",
         "failed switch must leave staged file content untouched");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Rejects_Staged_Changes;

   procedure Switch_Branch_Rejects_Untracked_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Tracked_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Untracked_Path : constant String :=
        Version.Test_Support.Join (Root, "b.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Tracked_Path, "clean" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial");

      --  Put b.txt on the feature branch so switching to it would have to
      --  write b.txt into the working tree (this is what git protects).
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Untracked_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add b.txt");
      Version.Write.Save ("add b on feature");
      Version.Branch.Switch_Branch ("main");

      --  Now an untracked b.txt collides with the file feature would deliver.
      Version.Test_Support.Write_Text_File
        (Untracked_Path, "untracked" & Character'Val (10));

      begin
         Version.Branch.Switch_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised, "branch switch must reject overwriting an untracked file");

      Assert
        (Ada.Directories.Exists (Untracked_Path),
         "failed switch must leave untracked file untouched");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Rejects_Untracked_File;

   procedure Integrate_Branch_Creates_Merge_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Main_Path : constant String :=
        Version.Test_Support.Join (Root, "main.txt");

      Feature_Path : constant String :=
        Version.Test_Support.Join (Root, "feature.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Main_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      --  Current branch changes main.txt.
      Version.Test_Support.Write_Text_File
        (Main_Path, "main change" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");

      --  Feature branch adds feature.txt.
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Feature_Path, "feature change" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");

      Version.Branch.Switch_Branch ("main");

      Version.Branch.Integrate_Branch ("feature");

      Assert
        (Version.Test_Support.Read_Text_File (Main_Path) = "main change",
         "integrate must preserve current branch file");

      Assert
        (Version.Test_Support.Read_Text_File (Feature_Path) = "feature change",
         "integrate must restore integrated branch file");

      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""3""");

      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Integrate_Branch_Creates_Merge_Commit;

   procedure Integrate_Branch_Writes_Conflict_Markers
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      --  main changes same path
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");

      --  feature changes same path differently
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Before_Head : constant String :=
           Version.Refs.Current_Commit_Id (Repo);
      begin
         begin
            Version.Branch.Integrate_Branch ("feature");

         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "integrate must reject conflicting merge");

         declare
            After_Head : constant String :=
              Version.Refs.Current_Commit_Id (Repo);
         begin
            Assert
              (After_Head = Before_Head,
               "conflicting integrate must not move current branch ref");
         end;
      end;

      declare
         Text : constant String :=
           Version.Test_Support.Read_Text_File (File_Path);
      begin
         Assert (Text'Length > 0, "conflict file must exist");

         Assert
           (Ada.Strings.Fixed.Index (Text, "<<<<<<< main") /= 0,
            "conflict file must contain current marker");

         Assert
           (Ada.Strings.Fixed.Index (Text, "=======") /= 0,
            "conflict file must contain separator");

         Assert
           (Ada.Strings.Fixed.Index (Text, ">>>>>>> feature") /= 0,
            "conflict file must contain target marker");
      end;

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Current_Id    : Version.Objects.Object_Id_Storage;
         Target_Id     : Version.Objects.Object_Id_Storage;
         Base_Id       : Version.Objects.Object_Id_Storage;
         Target_Branch : Ada.Strings.Unbounded.Unbounded_String;
         Conflicts     : Version.Merge.Conflict_Vectors.Vector;
      begin
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);

         Assert
           (Ada.Strings.Unbounded.To_String (Target_Branch) = "feature",
            "conflicting integrate must persist target branch");

         Assert
           (Natural (Conflicts.Length) = 1,
            "conflicting integrate must persist one conflicted path");

         Assert
           (Conflicts.Element (Conflicts.First_Index).Kind
            = Version.Merge.Content_Conflict,
            "conflicting integrate must record a content conflict");
      end;

      declare
         Status : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
         Found  : Boolean := False;
      begin
         if not Status.Conflicted.Is_Empty then
            for I in Status.Conflicted.First_Index .. Status.Conflicted.Last_Index loop
               declare
                  Item : constant Version.Status.File_Change :=
                    Status.Conflicted.Element (I);
               begin
                  if Ada.Strings.Unbounded.To_String (Item.Path) = "a.txt"
                    and then Item.Kind = Version.Status.Unmerged_File
                  then
                     Found := True;
                  end if;
               end;
            end loop;
         end if;

         Assert (Found, "conflicted merge must appear in structured status");
         Assert
           (Ada.Strings.Fixed.Index
              (Version.Status.Porcelain_Status_Text (Status), "U UU a.txt") /= 0,
            "conflicted merge must appear in porcelain status");
      end;

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
      begin
         Assert
           (Version.Staging.Find_Stage_Entry (Entries, "a.txt", 1)
            /= Natural'Last,
            "conflicted merge must write base index stage");
         Assert
           (Version.Staging.Find_Stage_Entry (Entries, "a.txt", 2)
            /= Natural'Last,
            "conflicted merge must write current index stage");
         Assert
           (Version.Staging.Find_Stage_Entry (Entries, "a.txt", 3)
            /= Natural'Last,
            "conflicted merge must write target index stage");
      end;

      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --count HEAD)"" = ""2""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Integrate_Branch_Writes_Conflict_Markers;

   procedure Conflicted_Integrate_Applies_Clean_Target_Delete
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Conflict_Path : constant String :=
        Version.Test_Support.Join (Root, "conflict.txt");

      Gone_Path : constant String :=
        Version.Test_Support.Join (Root, "gone.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Conflict_Path, "base" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Gone_Path, "delete me" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add conflict.txt gone.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Conflict_Path, "main" & Character'Val (10));      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");

      Ada.Directories.Delete_File (Gone_Path);
      Version.Test_Support.Write_Text_File
        (Conflict_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Git_Fixtures.Run (Root, "git add -u gone.txt");
      Version.Write.Save ("feature deletes clean file and conflicts");

      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Integrate_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "integrate must stop for the content conflict");

      Assert
        (not Ada.Directories.Exists (Gone_Path),
         "conflicted merge must still apply clean target-side deletion");

      Assert_File_Contains
        (Conflict_Path,
         "<<<<<<< main",
         "conflicted file must keep conflict markers");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Conflicted_Integrate_Applies_Clean_Target_Delete;

   procedure Abort_Integration_Restores_Current_Parent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
      Expected_Current_Content : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Expected_Current_Content :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (File_Path));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Integrate_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised, "conflicting integrate must leave merge state for abort");

      Version.Branch.Abort_Integration;

      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "abort must clear merge state");

      Assert
        (Version.Files.Read_Binary_File (File_Path)
         = Ada.Strings.Unbounded.To_String (Expected_Current_Content),
         "abort must restore current parent content");

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Abort_Integration_Restores_Current_Parent;

   procedure Git_Created_Conflict_Can_Be_Aborted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Main_Content : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m base");

      Version.Git_Fixtures.Run (Root, "git checkout -b feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m feature");

      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Main_Content :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (File_Path));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m main");

      Version.Git_Fixtures.Run (Root, "git merge feature || true");
      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "git-created conflict must leave MERGE_HEAD");
      Version.Git_Fixtures.Run (Root, "test -n ""$(git ls-files -u)""");

      Version.Branch.Abort_Integration;

      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "abort must clear Git MERGE_HEAD");
      Assert
        (Version.Files.Read_Binary_File (File_Path)
         = Ada.Strings.Unbounded.To_String (Main_Content),
         "abort must restore the Git ORIG_HEAD worktree content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Git_Created_Conflict_Can_Be_Aborted;

   procedure Git_Created_Conflict_Can_Be_Finalized
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Resolved_Content : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m base");

      Version.Git_Fixtures.Run (Root, "git checkout -b feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m feature");

      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m main");

      Version.Git_Fixtures.Run (Root, "git merge feature || true");
      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "git-created conflict must leave MERGE_HEAD");

      Version.Test_Support.Write_Text_File
        (File_Path, "resolved" & Character'Val (10));
      Resolved_Content :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (File_Path));
      Version.Branch.Finalize_Integration;

      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "finalize must clear Git MERGE_HEAD");
      Assert
        (Version.Files.Read_Binary_File (File_Path)
         = Ada.Strings.Unbounded.To_String (Resolved_Content),
         "finalize must commit the resolved worktree content");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git show -s --format=%P HEAD | wc -w)"" = ""2""");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Git_Created_Conflict_Can_Be_Finalized;

   procedure Abort_Integration_Removes_Target_Only_Additions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Conflict_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Added_Path : constant String :=
        Version.Test_Support.Join (Root, "feature-only.txt");

      Raised : Boolean := False;
      Expected_Current_Content : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Conflict_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Conflict_Path, "main" & Character'Val (10));
      Expected_Current_Content :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (Conflict_Path));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Conflict_Path, "feature" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Added_Path, "target only" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt feature-only.txt");
      Version.Write.Save ("feature conflict plus add");

      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Integrate_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised, "conflicting integrate must leave merge state for abort");

      Assert
        (Ada.Directories.Exists (Added_Path),
         "conflicted integrate must apply clean target-only addition");

      Version.Branch.Abort_Integration;

      Assert
        (not Ada.Directories.Exists (Added_Path),
         "abort must remove target-only files written by conflicted merge");

      Assert
        (Version.Files.Read_Binary_File (Conflict_Path)
         = Ada.Strings.Unbounded.To_String (Expected_Current_Content),
         "abort must restore current parent content");

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Abort_Integration_Removes_Target_Only_Additions;

   procedure Merge_Whitespace_Option_Resolves_Equivalent_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "a b" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "a  b" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main whitespace");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "ab" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature whitespace");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Whitespace := Version.Branch.Whitespace_Ignore_All_Space;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "a  b",
         "ignore-all-space merge must keep the current equivalent text");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "whitespace-equivalent merge must not leave merge state");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Whitespace_Option_Resolves_Equivalent_Text;

   procedure Merge_Config_Renormalize_Resolves_Line_Ending_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.renormalize TRUE");

      Version.Files.Write_Binary_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Files.Write_Binary_File
        (File_Path, "same" & Character'Val (13) & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main crlf");

      Version.Branch.Switch_Branch ("feature");
      Version.Files.Write_Binary_File
        (File_Path, "same" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature lf");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Files.Read_Binary_File (File_Path)
         = "same" & Character'Val (13) & Character'Val (10),
         "merge.renormalize config must keep current normalized content");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "renormalized equivalent merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Config_Renormalize_Resolves_Line_Ending_Text;

   procedure Merge_No_Renormalize_Overrides_Config
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.renormalize true");

      Version.Files.Write_Binary_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Files.Write_Binary_File
        (File_Path, "same" & Character'Val (13) & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main crlf");

      Version.Branch.Switch_Branch ("feature");
      Version.Files.Write_Binary_File
        (File_Path, "same" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature lf");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Renormalize := False;
      Options.Renormalize_Explicit := True;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "explicit no-renormalize must override merge.renormalize config");
      Assert_File_Contains
        (File_Path, "<<<<<<< main",
         "no-renormalize override must leave conflict markers");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "no-renormalize conflict must leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_No_Renormalize_Overrides_Config;

   procedure Merge_Attributes_Union_Resolves_Content_Conflict
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.txt merge=union" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add .gitattributes a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert_File_Contains
        (File_Path, "main", "union merge must include current content");
      Assert_File_Contains
        (File_Path, "feature", "union merge must include target content");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "union merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Attributes_Union_Resolves_Content_Conflict;

   procedure Merge_Attributes_Nested_Text_Resets_Parent_Rule
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sub_Dir : constant String := Version.Test_Support.Join (Root, "sub");
      File_Path : constant String := Version.Test_Support.Join (Sub_Dir, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Sub_Dir);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.txt merge=union" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Dir, ".gitattributes"),
         "a.txt merge=text" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git add .gitattributes sub/.gitattributes sub/a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "nested merge=text attribute must reset inherited union behavior");
      Assert_File_Contains
        (File_Path, "<<<<<<< main", "text reset must leave conflict markers");
      Assert_File_Contains
        (File_Path, ">>>>>>> feature", "text reset must name target marker");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "text reset conflict must leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Attributes_Nested_Text_Resets_Parent_Rule;

   procedure Merge_Attributes_Unset_Resets_Parent_Rule
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sub_Dir : constant String := Version.Test_Support.Join (Root, "sub");
      File_Path : constant String := Version.Test_Support.Join (Sub_Dir, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Sub_Dir);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.txt merge=union" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Dir, ".gitattributes"),
         "a.txt !merge" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git add .gitattributes sub/.gitattributes sub/a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "nested !merge attribute must reset inherited union behavior");
      Assert_File_Contains
        (File_Path, "<<<<<<< main", "unset merge attr must leave conflict markers");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "unset merge attr conflict must leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Attributes_Unset_Resets_Parent_Rule;

   procedure Merge_Info_Attributes_Override_Worktree_Rules
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sub_Dir : constant String := Version.Test_Support.Join (Root, "sub");
      File_Path : constant String := Version.Test_Support.Join (Sub_Dir, "a.txt");
      Info_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Root, ".git"), "info");
      Info_Attributes : constant String :=
        Version.Test_Support.Join (Info_Dir, "attributes");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Sub_Dir);
      Ada.Directories.Create_Path (Info_Dir);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.txt merge=union" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Info_Attributes, "sub/a.txt merge=ours" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add .gitattributes sub/a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add sub/a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "main",
         "info attributes must override worktree merge attributes");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "info attribute ours merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Info_Attributes_Override_Worktree_Rules;

   procedure Merge_Conflict_Style_Diff3_Writes_Base_Markers
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      Options.Conflict_Style := Version.Branch.Conflict_Style_Diff3;
      Options.Marker_Size := 9;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "diff3 conflict merge must stop for user resolution");
      Assert_File_Contains
        (File_Path, "<<<<<<<<< main", "diff3 must use configured left marker");
      Assert_File_Contains
        (File_Path, "||||||||| base", "diff3 must include the base section");
      Assert_File_Contains
        (File_Path, ">>>>>>>>> feature", "diff3 must use configured right marker");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Conflict_Style_Diff3_Writes_Base_Markers;

   procedure Merge_Config_Conflict_Style_Normalizes_Value
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.conflictstyle Diff3");

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "configured diff3 conflict merge must stop");
      Assert_File_Contains
        (File_Path, "<<<<<<< main",
         "mixed-case merge.conflictstyle must keep left marker");
      Assert_File_Contains
        (File_Path, "||||||| base",
         "mixed-case merge.conflictstyle must include base section");
      Assert_File_Contains
        (File_Path, ">>>>>>> feature",
         "mixed-case merge.conflictstyle must keep right marker");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Config_Conflict_Style_Normalizes_Value;

   procedure Merge_Config_FF_False_Creates_Merge_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature tip");

      Version.Branch.Switch_Branch ("main");
      Version.Git_Fixtures.Run (Root, "git config merge.ff false");
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run (Root, "test -f feature.txt");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Config_FF_False_Creates_Merge_Commit;

   procedure Merge_FF_Option_Overrides_Config_False
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature tip");

      Version.Branch.Switch_Branch ("main");
      Version.Git_Fixtures.Run (Root, "git config merge.ff false");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Allowed;
      Options.Fast_Forward_Explicit := True;
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run (Root, "test -f feature.txt");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""2""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_FF_Option_Overrides_Config_False;

   procedure Merge_Branch_Merge_Options_Config_Applies_Defaults
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature tip");

      Version.Branch.Switch_Branch ("main");
      Version.Git_Fixtures.Run
        (Root, "git config branch.main.mergeOptions '--no-ff --no-commit'");
      Version.Branch.Merge ("feature", Options);

      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
         "branch mergeOptions must apply target tree");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "branch mergeOptions --no-commit must pause clean merge");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-parse HEAD)"" = ""$(git rev-parse main)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Branch_Merge_Options_Config_Applies_Defaults;

   procedure Merge_Default_Message_Uses_Branch_Label
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature tip");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Fast_Forward_Explicit := True;
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s)"" = ""Merge branch 'feature'""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Default_Message_Uses_Branch_Label;

   procedure Merge_Message_Log_Signoff_And_Cleanup
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "main.txt"),
         "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main tip");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature subject");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Fast_Forward_Explicit := True;
      Options.Message :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("  merge subject  " & Character'Val (10));
      Options.Cleanup_Mode := Ada.Strings.Unbounded.To_Unbounded_String ("strip");
      Options.Log_Limit := 20;
      Options.Log_Explicit := True;
      Options.Signoff := True;
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s)"" = ""merge subject""");
      Version.Git_Fixtures.Run
        (Root, "git log -1 --format=%B | grep -q 'feature subject'");
      Version.Git_Fixtures.Run
        (Root, "git log -1 --format=%B | grep -q 'Signed-off-by: Test <test@example.com>'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Message_Log_Signoff_And_Cleanup;

   procedure Merge_Edit_Message_Uses_Configured_Editor
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Editor_Path : constant String := Version.Test_Support.Join (Root, "editor.sh");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Commit_File
        (Root, "feature.txt", "feature" & Character'Val (10),
         "feature subject");
      Version.Branch.Switch_Branch ("main");
      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main");

      Version.Test_Support.Write_Text_File
        (Editor_Path,
         "#!/bin/sh" & Character'Val (10)
         & "printf 'edited merge message" & Character'Val (10)
         & "' > ""$1""" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "chmod +x editor.sh");
      Ada.Environment_Variables.Set ("GIT_EDITOR", Editor_Path);

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Fast_Forward_Explicit := True;
      Options.Edit_Message := True;
      Options.Edit_Explicit := True;
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s)"" = ""edited merge message""");

      Ada.Environment_Variables.Clear ("GIT_EDITOR");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Edit_Message_Uses_Configured_Editor;

   procedure Merge_Autostash_Restores_Dirty_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Commit_File
        (Root, "feature.txt", "feature" & Character'Val (10), "feature");
      Version.Branch.Switch_Branch ("main");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "local" & Character'Val (10));

      Options.Autostash := True;
      Options.Autostash_Explicit := True;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Root, "base.txt"))
         = "local",
         "autostash must restore dirty tracked content");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
         "autostash merge must still fast-forward target content");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/MERGE_AUTOSTASH")),
         "successful autostash merge must clear MERGE_AUTOSTASH");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "successful autostash merge must not leave a stash entry");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Autostash_Restores_Dirty_Worktree;

   procedure Merge_Autostash_Applies_To_No_Commit_Result
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "left.txt", "left" & Character'Val (10), "left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Commit_File (Root, "right.txt", "right" & Character'Val (10), "right");

      Version.Branch.Switch_Branch ("main");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "local" & Character'Val (10));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Options.No_Commit := True;
      Options.Autostash := True;
      Options.Autostash_Explicit := True;
      Version.Branch.Merge_Multiple (Targets, Options);

      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Root, "base.txt"))
         = "local",
         "autostash must apply to no-commit merge result");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "left.txt")),
         "no-commit autostash merge must keep first target content");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "right.txt")),
         "no-commit autostash merge must keep second target content");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "no-commit autostash apply must not leave stash entry on success");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Autostash_Applies_To_No_Commit_Result;

   procedure Restore_Path (Old_Path : String; Had_Path : Boolean) is
   begin
      if Had_Path then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;
   end Restore_Path;

   procedure Merge_GPG_Sign_Writes_GPGSig_Header
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Had_Path : constant Boolean := Ada.Environment_Variables.Exists ("PATH");
      Old_Path : constant String :=
        (if Had_Path then Ada.Environment_Variables.Value ("PATH") else "");
      Bin_Dir : constant String := Version.Test_Support.Join (Root, "fake-bin");
      GPG_Path : constant String := Version.Test_Support.Join (Bin_Dir, "gpg");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      if not Ada.Directories.Exists (Bin_Dir) then
         Ada.Directories.Create_Directory (Bin_Dir);
      end if;
      Version.Test_Support.Write_Text_File
        (GPG_Path,
         "#!/bin/sh" & Character'Val (10)
         & "out=" & Character'Val (10)
         & "while [ $# -gt 0 ]; do" & Character'Val (10)
         & "  if [ ""$1"" = ""--output"" ]; then shift; out=$1; fi" & Character'Val (10)
         & "  shift" & Character'Val (10)
         & "done" & Character'Val (10)
         & "cat > ""$out"" <<'EOF'" & Character'Val (10)
         & "-----BEGIN PGP SIGNATURE-----" & Character'Val (10)
         & Character'Val (10)
         & "fake-signature" & Character'Val (10)
         & "-----END PGP SIGNATURE-----" & Character'Val (10)
         & "EOF" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "chmod +x fake-bin/gpg");
      Ada.Environment_Variables.Set ("PATH", Bin_Dir & ":" & Old_Path);

      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "feature.txt", "feature" & Character'Val (10), "feature");
      Version.Branch.Switch_Branch ("main");
      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.GPG_Sign := Ada.Strings.Unbounded.To_Unbounded_String ("default");
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run
        (Root, "git cat-file -p HEAD | grep -q '^gpgsig -----BEGIN PGP SIGNATURE-----'");

      Restore_Path (Old_Path, Had_Path);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Restore_Path (Old_Path, Had_Path);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_GPG_Sign_Writes_GPGSig_Header;

   procedure Merge_External_Driver_Resolves_Content_Conflict
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "conflict.txt merge=take-target" & Character'Val (10)
         & "quoted'name.txt merge=echo-path" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root,
         "git config merge.take-target.driver ""printf '%s\n%s\n%s\n%s\n%s\n' "
         & "%S %X %Y \$GIT_INDEX_FILE \$GIT_COMMON_DIR > %A""");
      Version.Git_Fixtures.Run
        (Root,
         "git config merge.echo-path.driver ""printf '%s\n' %P > %A""");
      Version.Git_Fixtures.Run (Root, "git add .gitattributes");
      Version.Write.Save ("attrs");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "conflict.txt"),
         "base" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "quoted'name.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git add conflict.txt ""quoted'name.txt""");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "conflict.txt"),
         "target" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "quoted'name.txt"),
         "target" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git add conflict.txt ""quoted'name.txt""");
      Version.Write.Save ("target");
      Version.Branch.Switch_Branch ("main");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "conflict.txt"),
         "current" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "quoted'name.txt"),
         "current" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git add conflict.txt ""quoted'name.txt""");
      Version.Write.Save ("current");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert_File_Contains
        (Version.Test_Support.Join (Root, "conflict.txt"),
         "base" & Character'Val (10)
         & "main" & Character'Val (10)
         & "feature" & Character'Val (10),
         "external merge driver must expand conflict labels");
      Assert_File_Contains
        (Version.Test_Support.Join (Root, "conflict.txt"),
         Version.Test_Support.Join (Version.Test_Support.Join (Root, ".git"), "index"),
         "external merge driver must receive GIT_INDEX_FILE");
      Assert_File_Contains
        (Version.Test_Support.Join (Root, "conflict.txt"),
         Version.Test_Support.Join (Root, ".git"),
         "external merge driver must receive GIT_COMMON_DIR");
      Assert_File_Contains
        (Version.Test_Support.Join (Root, "quoted'name.txt"),
         "quoted'name.txt",
         "external merge driver must shell-quote apostrophes in %P");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, ".git/MERGE_HEAD")),
         "external merge driver success must not leave merge state");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/version-merge-driver")),
         "external merge driver success must clean temporary files");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_External_Driver_Resolves_Content_Conflict;

   procedure Merge_External_Driver_Fatal_Status_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Before : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "conflict.txt merge=fatal-driver" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git config merge.fatal-driver.driver ""exit 129""");
      Version.Git_Fixtures.Run (Root, "git add .gitattributes");
      Version.Write.Save ("attrs");
      Commit_File (Root, "conflict.txt", "base" & Character'Val (10), "base");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "conflict.txt", "target" & Character'Val (10), "target");
      Version.Branch.Switch_Branch ("main");
      Commit_File (Root, "conflict.txt", "current" & Character'Val (10), "current");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E),
                  "external merge driver failed") /= 0,
               "fatal external driver status must surface as driver failure");
      end;

      Assert (Raised, "fatal external driver status must reject merge");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "fatal external driver status must not move HEAD");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "fatal external driver status must not leave Version merge state");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/version-merge-driver")),
         "fatal external driver status must clean temporary files");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_External_Driver_Fatal_Status_Raises;

   procedure Merge_External_Driver_Missing_Result_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Before : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "conflict.txt merge=missing-result" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git config merge.missing-result.driver ""rm -f %A""");
      Version.Git_Fixtures.Run (Root, "git add .gitattributes");
      Version.Write.Save ("attrs");
      Commit_File (Root, "conflict.txt", "base" & Character'Val (10), "base");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "conflict.txt", "target" & Character'Val (10), "target");
      Version.Branch.Switch_Branch ("main");
      Commit_File (Root, "conflict.txt", "current" & Character'Val (10), "current");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E),
                  "external merge driver failed") /= 0,
               "missing external driver result must surface as driver failure");
      end;

      Assert (Raised, "missing external driver result must reject merge");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "missing external driver result must not move HEAD");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "missing external driver result must not leave Version merge state");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, ".git/version-merge-driver")),
         "missing external driver result must clean temporary files");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_External_Driver_Missing_Result_Raises;

   procedure Merge_Pre_Merge_Commit_Hook_Blocks_Auto_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Before : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Commit_File
        (Root, "feature.txt", "feature" & Character'Val (10), "feature");
      Version.Branch.Switch_Branch ("main");
      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/hooks/pre-merge-commit"),
         "#!/bin/sh" & Character'Val (10)
         & "printf '%s\n' ""$GIT_DIR"" > pre-merge-env.txt" & Character'Val (10)
         & "exit 1" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "chmod +x .git/hooks/pre-merge-commit");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E), "pre-merge-commit") /= 0,
               "pre-merge-commit failure must name the blocking hook");
      end;

      Assert (Raised, "pre-merge-commit failure must block auto merge commit");
      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "pre-merge-env.txt")),
         "pre-merge-commit hook must run in repository root");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "pre-merge-commit failure must not move HEAD");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Pre_Merge_Commit_Hook_Blocks_Auto_Commit;

   procedure Merge_Multiple_No_Commit_Writes_Multi_Head_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
      Before : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "left.txt", "left" & Character'Val (10), "left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Commit_File (Root, "right.txt", "right" & Character'Val (10), "right");

      Version.Branch.Switch_Branch ("main");
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Options.No_Commit := True;
      Version.Branch.Merge_Multiple (Targets, Options);

      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "multi-target no-commit must not advance HEAD");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "left.txt")),
         "multi-target no-commit must include first target content");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "right.txt")),
         "multi-target no-commit must include second target content");
      Version.Git_Fixtures.Run
        (Root, "test ""$(wc -l < .git/MERGE_HEAD)"" = ""2""");

      Version.Branch.Finalize_Integration;
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""4""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_No_Commit_Writes_Multi_Head_State;

   procedure Merge_Verify_Signatures_Preflight_No_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
      Before : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "feature.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature tip");

      Version.Branch.Switch_Branch ("main");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Options.Verify_Signatures := True;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "verify-signatures merge must reject before mutation");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "verify-signatures rejection must keep HEAD");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "verify-signatures rejection must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Verify_Signatures_Preflight_No_Mutation;

   procedure Merge_Rerere_Reuses_Recorded_Resolution
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
      Main_Id : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Git_Fixtures.Run (Root, "git config rerere.enabled TRUE");

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");
      Main_Id := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "first rerere merge must produce a conflict");
      Version.Git_Fixtures.Run
        (Root, "find .git/rr-cache -name preimage | grep -q preimage");

      Version.Test_Support.Write_Text_File
        (File_Path, "resolved" & Character'Val (10));
      Version.Branch.Finalize_Integration;
      Version.Git_Fixtures.Run
        (Root,
         "git reset --hard " & Ada.Strings.Unbounded.To_String (Main_Id));

      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "resolved",
         "rerere must reuse the recorded postimage");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rerere_Reuses_Recorded_Resolution;

   procedure Merge_Rename_Modify_Moves_Modified_Content
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Old_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edits old path");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Write.Save ("feature renames old path");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (not Ada.Directories.Exists (Old_Path),
         "rename/modify merge must remove the old path");
      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "main",
         "rename/modify merge must move modified content to the new path");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rename_Modify_Moves_Modified_Content;

   procedure Merge_Directory_Rename_Moves_Added_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "mkdir -p dir");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/a.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt");
      Version.Write.Save ("base dir");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/new.txt"),
         "current addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/new.txt");
      Version.Write.Save ("main add under old dir");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "mkdir -p renamed");
      Version.Git_Fixtures.Run (Root, "git mv dir/a.txt renamed/a.txt");
      Version.Git_Fixtures.Run (Root, "rmdir dir");
      Version.Write.Save ("feature rename dir");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "renamed/a.txt")),
         "directory rename merge must keep renamed base file");
      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Root, "renamed/new.txt"))
         = "current addition",
         "directory rename merge must move additions under renamed directory");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "dir/new.txt")),
         "directory rename merge must remove old addition path");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_Rename_Moves_Added_File;

   procedure Merge_Case_Only_Rename_Preflight_Allows_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "case.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "Case.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Old_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add case.txt");
      Version.Write.Save ("base case path");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv case.txt Case.txt");
      Version.Test_Support.Write_Text_File
        (New_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add Case.txt");
      Version.Write.Save ("feature case-only rename");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (True);
      Version.Branch.Merge ("feature", Options);
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);

      Assert
        (not Ada.Directories.Exists (Old_Path),
         "case-only rename merge must remove old-case path");
      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "feature",
         "case-only rename merge must materialize new-case path");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD Case.txt | grep -q 'Case.txt'");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git ls-tree HEAD case.txt)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Case_Only_Rename_Preflight_Allows_Update;

   procedure Merge_Directory_Rename_Case_Collision_Preflights
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "mkdir -p dir");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/anchor.txt"),
         "anchor" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/anchor.txt");
      Version.Write.Save ("base dir");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/name.txt"),
         "main addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/name.txt");
      Version.Write.Save ("main add case path");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "mkdir -p renamed");
      Version.Git_Fixtures.Run (Root, "git mv dir/anchor.txt renamed/anchor.txt");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "renamed/Name.txt"),
         "feature addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add renamed/Name.txt");
      Version.Git_Fixtures.Run (Root, "rmdir dir");
      Version.Write.Save ("feature rename dir and add case path");
      Version.Branch.Switch_Branch ("main");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (True);
         begin
            Version.Branch.Merge ("feature", Options);
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Strings.Fixed.Index
                    (Ada.Exceptions.Exception_Message (E),
                     "path case collision") /= 0,
                  "directory-rename generated case collision used wrong diagnostic: "
                  & Ada.Exceptions.Exception_Message (E));
         end;
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);

         Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                 "case-collision merge must preserve current branch ref");
      end;

      Assert (Raised, "directory-rename generated case collision must fail");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "case-collision preflight must not leave merge state");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "dir/name.txt")),
         "case-collision preflight must preserve old-path addition");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "renamed/Name.txt")),
         "case-collision preflight must not partially write target case path");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_Rename_Case_Collision_Preflights;

   procedure Merge_Directory_Rename_Config_Disables_Addition_Move
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "mkdir -p dir");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/a.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt");
      Version.Write.Save ("base dir");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/new.txt"),
         "current addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/new.txt");
      Version.Write.Save ("main add under old dir");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "mkdir -p renamed");
      Version.Git_Fixtures.Run (Root, "git mv dir/a.txt renamed/a.txt");
      Version.Git_Fixtures.Run (Root, "rmdir dir");
      Version.Write.Save ("feature rename dir");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Directory_Renames := Version.Branch.Directory_Renames_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "dir/new.txt")),
         "directoryRenames=false must keep additions at the old path");
      Assert
        (not Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "renamed/new.txt")),
         "directoryRenames=false must not move additions into the renamed dir");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_Rename_Config_Disables_Addition_Move;

   procedure Merge_Directory_Rename_Config_Conflict_Pauses
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "mkdir -p dir");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/a.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt");
      Version.Write.Save ("base dir");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/new.txt"),
         "current addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/new.txt");
      Version.Write.Save ("main add under old dir");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "mkdir -p renamed");
      Version.Git_Fixtures.Run (Root, "git mv dir/a.txt renamed/a.txt");
      Version.Git_Fixtures.Run (Root, "rmdir dir");
      Version.Write.Save ("feature rename dir");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Directory_Renames := Version.Branch.Directory_Renames_Conflict;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "directoryRenames=conflict must pause the merge");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "directoryRenames=conflict must write merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_Rename_Config_Conflict_Pauses;

   procedure Merge_Directory_Rename_Ambiguous_Split_Pauses
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "mkdir -p dir");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/a.txt"),
         "a" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/b.txt"),
         "b" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt dir/b.txt");
      Version.Write.Save ("base dir");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/new.txt"),
         "current addition" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/new.txt");
      Version.Write.Save ("main add under old dir");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "mkdir -p left right");
      Version.Git_Fixtures.Run (Root, "git mv dir/a.txt left/a.txt");
      Version.Git_Fixtures.Run (Root, "git mv dir/b.txt right/b.txt");
      Version.Git_Fixtures.Run (Root, "rmdir dir");
      Version.Write.Save ("feature splits dir");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "split directory rename must pause additions under old dir");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "split directory rename must write merge state");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "dir/new.txt")),
         "ambiguous directory rename must keep addition at old path");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_Rename_Ambiguous_Split_Pauses;

   procedure Merge_Copy_Detection_Uses_Source_As_Add_Add_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Copy_Path : constant String := Version.Test_Support.Join (Root, "copy.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "source.txt"),
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add source.txt");
      Version.Write.Save ("base source");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Copy_Path,
         "one" & Character'Val (10)
         & "main" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add copy.txt");
      Version.Write.Save ("main copy edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Copy_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "feature" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add copy.txt");
      Version.Write.Save ("feature copy edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Detect_Copies := True;
      Options.Detect_Copies_Explicit := True;
      Version.Branch.Merge ("feature", Options);

      Assert_File_Contains (Copy_Path, "main", "copy detection must keep main edit");
      Assert_File_Contains (Copy_Path, "feature", "copy detection must keep feature edit");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "copy-base add/add merge must complete cleanly");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Copy_Detection_Uses_Source_As_Add_Add_Base;

   procedure Merge_Ignore_CR_At_EOL_Treats_CRLF_As_Equivalent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Files.Write_Binary_File
        (File_Path, "value" & Character'Val (13) & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main crlf");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "value" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature lf");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Whitespace := Version.Branch.Whitespace_Ignore_CR_At_EOL;
      Version.Branch.Merge ("feature", Options);

      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "ignore-cr-at-eol must avoid an equivalent-line conflict");
      Assert_File_Contains (File_Path, "value", "merge result must keep line content");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Ignore_CR_At_EOL_Treats_CRLF_As_Equivalent;

   procedure Merge_Verify_Signatures_Config_Default_No_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
      Before : Version.Objects.Object_Id_Storage;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main change");
      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "feature.txt", "feature" & Character'Val (10), "feature change");
      Version.Branch.Switch_Branch ("main");
      Version.Git_Fixtures.Run (Root, "git config merge.verifySignatures true");

      Before := Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "merge.verifySignatures=true must verify target commits");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Before),
         "failed configured signature verification must not move HEAD");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Verify_Signatures_Config_Default_No_Mutation;

   procedure Merge_Non_Overlapping_Text_Edits_Auto_Merge
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one-main" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three-feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "one-main" & Character'Val (10)
           & "two" & Character'Val (10)
           & "three-feature",
         "non-overlapping text edits must auto-merge");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "auto-merged text edits must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Non_Overlapping_Text_Edits_Auto_Merge;

   procedure Merge_Multiple_Line_Text_Edits_Auto_Merge
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four" & Character'Val (10)
         & "five" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one-main" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four-main" & Character'Val (10)
         & "five" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main edits");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two-feature" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four" & Character'Val (10)
         & "five-feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature edits");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "one-main" & Character'Val (10)
           & "two-feature" & Character'Val (10)
           & "three" & Character'Val (10)
           & "four-main" & Character'Val (10)
           & "five-feature",
         "multiple independent line edits must auto-merge");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "multi-line auto-merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_Line_Text_Edits_Auto_Merge;

   procedure Merge_Conflict_Style_ZDiff3_Trims_Common_Context
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "keep-top" & Character'Val (10)
         & "base" & Character'Val (10)
         & "keep-bottom" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "keep-top" & Character'Val (10)
         & "main" & Character'Val (10)
         & "keep-bottom" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "keep-top" & Character'Val (10)
         & "feature" & Character'Val (10)
         & "keep-bottom" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      Options.Conflict_Style := Version.Branch.Conflict_Style_ZDiff3;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "zdiff3 conflict merge must stop for user resolution");
      declare
         Text : constant String := Version.Test_Support.Read_Text_File (File_Path);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Text, "keep-top" & Character'Val (10) & "<<<<<<< main") /= 0,
            "zdiff3 must leave common prefix outside the conflict hunk");
         Assert
           (Ada.Strings.Fixed.Index (Text, "||||||| base") /= 0,
            "zdiff3 must include the base section");
         Assert
           (Ada.Strings.Fixed.Index
              (Text, ">>>>>>> feature" & Character'Val (10) & "keep-bottom") /= 0,
            "zdiff3 must leave common suffix outside the conflict hunk");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Conflict_Style_ZDiff3_Trims_Common_Context;

   procedure Merge_Similarity_Rename_Modify_Auto_Merges_Content
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta-main" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma-feature" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("feature rename and edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Rename_Threshold := 50;
      Version.Branch.Merge ("feature", Options);

      Assert
        (not Ada.Directories.Exists (Old_Path),
         "similarity rename merge must remove the old path");
      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "alpha" & Character'Val (10)
           & "beta-main" & Character'Val (10)
           & "gamma-feature" & Character'Val (10)
           & "delta",
         "similarity rename merge must combine non-overlapping edits");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Similarity_Rename_Modify_Auto_Merges_Content;

   procedure Merge_Find_Renames_Overrides_Config_False
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.renames false");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta-main" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma-feature" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("feature rename and edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Detect_Renames := True;
      Options.Detect_Renames_Explicit := True;
      Options.Rename_Threshold := 50;
      Version.Branch.Merge ("feature", Options);

      Assert
        (not Ada.Directories.Exists (Old_Path),
         "explicit find-renames must override merge.renames=false");
      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "alpha" & Character'Val (10)
           & "beta-main" & Character'Val (10)
           & "gamma-feature" & Character'Val (10)
           & "delta",
         "explicit find-renames must combine rename/modify edits");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Find_Renames_Overrides_Config_False;

   procedure Merge_No_Renames_Overrides_Config_True
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.renames true");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta-main" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma-feature" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("feature rename and edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Detect_Renames := False;
      Options.Detect_Renames_Explicit := True;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "explicit no-renames must override merge.renames=true");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "no-renames override must leave conflicted merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_No_Renames_Overrides_Config_True;

   procedure Merge_Gitlink_Fast_Forwards_Local_Submodule_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sub_Path : constant String := Version.Test_Support.Join (Root, "sub");
      Options : Version.Branch.Merge_Options;
      Base_Sub : Version.Objects.Object_Id_Storage;
      Main_Sub : Version.Objects.Object_Id_Storage;
      Target_Sub : Version.Objects.Object_Id_Storage;

      function Sub_Commit return Version.Objects.Hex_Object_Id is
      begin
         return Version.Objects.To_Object_Id
           (Version.Refs.Current_Commit_Id
              (Version.Repository.Open_Git_Dir
                 (Version.Test_Support.Join (Sub_Path, ".git"))));
      end Sub_Commit;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Ada.Directories.Create_Path (Sub_Path);
      Version.Git_Fixtures.Run (Sub_Path, "git init");
      Version.Git_Fixtures.Run
        (Sub_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Sub_Path, "git config user.name Test");
      Version.Git_Fixtures.Run (Sub_Path, "git config gc.auto 0");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-base");
      Base_Sub := Sub_Commit;

      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000,"
         & To_String (Base_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m base-submodule");
      Version.Git_Fixtures.Run (Root, "git branch feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-main");
      Main_Sub := Sub_Commit;
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --cacheinfo 160000,"
         & To_String (Main_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m main-submodule");

      Version.Git_Fixtures.Run (Root, "git checkout feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "target" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-target");
      Target_Sub := Sub_Commit;
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --cacheinfo 160000,"
         & To_String (Target_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m target-submodule");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Git_Fixtures.Run
        (Sub_Path, "git checkout " & To_String (Main_Sub));

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Version.Git_Fixtures.Run
        (Root,
         "git ls-tree HEAD sub | grep -q '160000 commit "
         & To_String (Target_Sub) & "'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Gitlink_Fast_Forwards_Local_Submodule_Update;

   procedure Merge_Gitlink_Dirty_Submodule_Blocks_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sub_Path : constant String := Version.Test_Support.Join (Root, "sub");
      Options : Version.Branch.Merge_Options;
      Base_Sub : Version.Objects.Object_Id_Storage;
      Main_Sub : Version.Objects.Object_Id_Storage;
      Target_Sub : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;

      function Sub_Commit return Version.Objects.Hex_Object_Id is
      begin
         return Version.Objects.To_Object_Id
           (Version.Refs.Current_Commit_Id
              (Version.Repository.Open_Git_Dir
                 (Version.Test_Support.Join (Sub_Path, ".git"))));
      end Sub_Commit;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Ada.Directories.Create_Path (Sub_Path);
      Version.Git_Fixtures.Run (Sub_Path, "git init");
      Version.Git_Fixtures.Run
        (Sub_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Sub_Path, "git config user.name Test");
      Version.Git_Fixtures.Run (Sub_Path, "git config gc.auto 0");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-base");
      Base_Sub := Sub_Commit;

      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000,"
         & To_String (Base_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m base-submodule");
      Version.Git_Fixtures.Run (Root, "git branch feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-main");
      Main_Sub := Sub_Commit;
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --cacheinfo 160000,"
         & To_String (Main_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m main-submodule");

      Version.Git_Fixtures.Run (Root, "git checkout feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "target" & Character'Val (10));
      Version.Git_Fixtures.Run (Sub_Path, "git add sub.txt");
      Version.Git_Fixtures.Run (Sub_Path, "git commit -m sub-target");
      Target_Sub := Sub_Commit;
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --cacheinfo 160000,"
         & To_String (Target_Sub) & ",sub");
      Version.Git_Fixtures.Run (Root, "git commit -m target-submodule");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Git_Fixtures.Run
        (Sub_Path, "git checkout " & To_String (Main_Sub));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "sub.txt"),
         "dirty" & Character'Val (10));

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E), "dirty submodule") /= 0,
               "dirty submodule rejection must explain the submodule state");
      end;

      Assert (Raised, "dirty submodule merge update must be rejected");
      Assert
        (Sub_Commit = Main_Sub,
         "dirty submodule rejection must leave the submodule HEAD unchanged");
      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Sub_Path, "sub.txt"))
         = "dirty",
         "dirty submodule rejection must preserve worktree content");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "dirty submodule rejection must not leave Version merge state");

      Version.Git_Fixtures.Run (Sub_Path, "git checkout -- sub.txt");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Sub_Path, "untracked.txt"),
         "untracked" & Character'Val (10));

      Raised := False;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E), "dirty submodule") /= 0,
               "untracked submodule rejection must explain the submodule state");
      end;

      Assert
        (Raised,
         "untracked submodule merge update must be rejected");
      Assert
        (Sub_Commit = Main_Sub,
         "untracked submodule rejection must leave the submodule HEAD unchanged");
      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Sub_Path, "untracked.txt"))
         = "untracked",
         "untracked submodule rejection must preserve untracked files");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "untracked submodule rejection must not leave Version merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Gitlink_Dirty_Submodule_Blocks_Update;

   procedure Merge_Diff_Algorithm_Minimal_Merges_Multi_Hunk_Insertions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "b" & Character'Val (10)
         & "c" & Character'Val (10)
         & "d" & Character'Val (10)
         & "e" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "current-one" & Character'Val (10)
         & "b" & Character'Val (10)
         & "c" & Character'Val (10)
         & "d" & Character'Val (10)
         & "current-two" & Character'Val (10)
         & "e" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main insertions");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "b" & Character'Val (10)
         & "c" & Character'Val (10)
         & "feature" & Character'Val (10)
         & "d" & Character'Val (10)
         & "e" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature insertion");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Algorithm := Version.Branch.Diff_Algorithm_Minimal;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "a" & Character'Val (10)
           & "current-one" & Character'Val (10)
           & "b" & Character'Val (10)
           & "c" & Character'Val (10)
           & "feature" & Character'Val (10)
           & "d" & Character'Val (10)
           & "current-two" & Character'Val (10)
           & "e",
         "minimal diff algorithm merge must combine independent insertion hunks");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Diff_Algorithm_Minimal_Merges_Multi_Hunk_Insertions;

   procedure Merge_Subtree_Option_Rewrites_Target_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "app.txt", "app" & Character'Val (10), "app");

      Version.Git_Fixtures.Run (Root, "git checkout --orphan libbranch");
      Version.Git_Fixtures.Run (Root, "git rm -rf .");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "lib.txt"),
         "library" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add lib.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m lib");
      Version.Git_Fixtures.Run (Root, "git checkout main");

      Options.Allow_Unrelated_Histories := True;
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Subtree := True;
      Options.Subtree_Prefix :=
        Ada.Strings.Unbounded.To_Unbounded_String ("vendor");
      Version.Branch.Merge ("libbranch", Options);

      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "app.txt")),
         "subtree merge must preserve current tree paths");
      Assert
        (Version.Test_Support.Read_Text_File
           (Version.Test_Support.Join (Root, "vendor/lib.txt"))
         = "library",
         "subtree merge must write target paths below the requested prefix");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "lib.txt")),
         "subtree merge must not write unprefixed target paths");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Subtree_Option_Rewrites_Target_Paths;

   procedure Merge_Rename_Rename_Same_Path_Auto_Merges_Content
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File
        (Root, "old.txt",
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10),
         "base");
      Version.Branch.Create_Branch ("feature");

      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "one" & Character'Val (10)
         & "two-main" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("main rename edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three-feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("feature rename edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "one" & Character'Val (10)
           & "two-main" & Character'Val (10)
           & "three-feature",
         "same-destination rename merge must combine non-overlapping edits");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "old.txt")),
         "same-destination rename merge must remove the old path");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rename_Rename_Same_Path_Auto_Merges_Content;

   procedure Merge_Rename_Rename_Same_Path_Preserves_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      New_Path : constant String := Version.Test_Support.Join (Root, "new.sh");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File
        (Root, "old.sh", "echo shared" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Version.Git_Fixtures.Run (Root, "git mv old.sh new.sh");
      Version.Write.Save ("main rename");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.sh new.sh");
      Version.Git_Fixtures.Run (Root, "git update-index --chmod=+x new.sh");
      Version.Write.Save ("feature rename executable bit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (New_Path)
         = "echo shared",
         "same-destination rename/mode merge must keep shared content");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD new.sh | grep -q '^100755'");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "old.sh")),
         "same-destination rename/mode merge must remove the old path");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "same-destination rename/mode merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rename_Rename_Same_Path_Preserves_Mode;

   procedure Merge_Rename_Add_Collision_Writes_Unmerged_Stages
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "old.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Version.Git_Fixtures.Run (Root, "git rm old.txt");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "new.txt"),
         "current add" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("main delete add");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Write.Save ("feature rename");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "rename/add collision must stop for conflict resolution");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git ls-files -u new.txt | wc -l)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rename_Add_Collision_Writes_Unmerged_Stages;

   procedure Merge_Rerere_Reuses_Resolution_With_Sides_Swapped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
      Main_Id : Ada.Strings.Unbounded.Unbounded_String;
      Feature_Id : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config rerere.enabled true");

      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Commit_File (Root, "a.txt", "main" & Character'Val (10), "main");
      Main_Id := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "a.txt", "feature" & Character'Val (10), "feature");
      Feature_Id := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "first rerere merge must conflict");

      Version.Test_Support.Write_Text_File
        (File_Path, "resolved" & Character'Val (10));
      Version.Branch.Finalize_Integration;

      Version.Git_Fixtures.Run
        (Root,
         "git checkout -B swapped "
         & Ada.Strings.Unbounded.To_String (Feature_Id));
      Version.Branch.Merge
        (Ada.Strings.Unbounded.To_String (Main_Id), Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "resolved",
         "rerere must reuse the same recorded resolution with sides swapped");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rerere_Reuses_Resolution_With_Sides_Swapped;

   procedure Merge_Multiple_Conflict_Writes_All_Merge_Heads
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");

      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a.txt", "left" & Character'Val (10), "left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Commit_File (Root, "a.txt", "right" & Character'Val (10), "right");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("third");
      Version.Branch.Switch_Branch ("third");
      Commit_File (Root, "third.txt", "third" & Character'Val (10), "third");

      Version.Branch.Switch_Branch ("main");
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("third"));
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge_Multiple (Targets, Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "octopus conflict must stop for resolution");
      Version.Git_Fixtures.Run
        (Root, "test ""$(wc -l < .git/MERGE_HEAD)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_Conflict_Writes_All_Merge_Heads;

   procedure Merge_Default_Strategy_Merges_Multi_Hunk_Insertions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "b" & Character'Val (10)
         & "c" & Character'Val (10)
         & "d" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "main-one" & Character'Val (10)
         & "b" & Character'Val (10)
         & "c" & Character'Val (10)
         & "main-two" & Character'Val (10)
         & "d" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main insertions");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "a" & Character'Val (10)
         & "b" & Character'Val (10)
         & "feature" & Character'Val (10)
         & "c" & Character'Val (10)
         & "d" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature insertion");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "a" & Character'Val (10)
           & "main-one" & Character'Val (10)
           & "b" & Character'Val (10)
           & "feature" & Character'Val (10)
           & "c" & Character'Val (10)
           & "main-two" & Character'Val (10)
           & "d",
         "default merge must combine independent insertion hunks");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Default_Strategy_Merges_Multi_Hunk_Insertions;

   procedure Merge_Resolve_Strategy_Disables_Rename_Detection
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta-main" & Character'Val (10)
         & "gamma" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma-feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Write.Save ("feature rename edit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Strategy := Version.Branch.Strategy_Resolve;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "resolve strategy must not use rename detection");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "resolve strategy rename/modify case must leave conflict state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Resolve_Strategy_Disables_Rename_Detection;

   procedure Merge_External_Driver_Recursive_Union_For_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "a.txt merge=custom" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git config merge.custom.recursive union");
      Version.Git_Fixtures.Run (Root, "git add .gitattributes");
      Version.Write.Save ("attrs");

      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Commit_File (Root, "a.txt", "right" & Character'Val (10), "right");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a.txt", "left" & Character'Val (10), "left");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (Conflicts.Is_Empty,
            "recursive external driver union must resolve virtual-base conflict");
         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a.txt", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert (Pos /= Natural'Last, "recursive driver must stage result");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj)
               = "left" & Character'Val (10)
                 & "right" & Character'Val (10),
               "recursive driver union must combine both sides");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_External_Driver_Recursive_Union_For_Virtual_Base;


   procedure Merge_Materializes_Text_Conflict_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Commit_File (Root, "a.txt", "right" & Character'Val (10), "right");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a.txt", "left" & Character'Val (10), "left");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base text merge must still report the conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a.txt", 0);
            Obj : Version.Objects.Git_Object;
            Content : Ada.Strings.Unbounded.Unbounded_String;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base text conflict must stage conflict-marker blob");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Content := Ada.Strings.Unbounded.To_Unbounded_String
              (Version.Objects.Content (Obj));
            Assert
              (Ada.Strings.Unbounded.Index (Content, "<<<<<<< left") /= 0,
               "virtual-base conflict blob must include current marker");
            Assert
              (Ada.Strings.Unbounded.Index (Content, ">>>>>>> right") /= 0,
               "virtual-base conflict blob must include target marker");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Text_Conflict_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Binary_Conflict_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.bin");
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Left_Content : constant String := "left" & Character'Val (0) & "bin";

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Files.Write_Binary_File
        (File_Path, "base" & Character'Val (0) & "bin");
      Version.Git_Fixtures.Run (Root, "git add a.bin");
      Version.Write.Save ("base binary");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Files.Write_Binary_File
        (File_Path, "right" & Character'Val (0) & "bin");
      Version.Git_Fixtures.Run (Root, "git add a.bin");
      Version.Write.Save ("right binary");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Version.Files.Write_Binary_File (File_Path, Left_Content);
      Version.Git_Fixtures.Run (Root, "git add a.bin");
      Version.Write.Save ("left binary");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base binary merge must still report the conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a.bin", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base binary conflict must stage current-side blob");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = Left_Content,
               "virtual-base binary conflict must materialize current side");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Binary_Conflict_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Delete_Modify_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Left_Content : constant String := "left modified" & Character'Val (10);

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "a.txt"));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("right deletes");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a.txt", Left_Content, "left modifies");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base delete/modify merge must still report the conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a.txt", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base delete/modify conflict must stage modified side");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = Left_Content,
               "virtual-base delete/modify conflict must materialize modified content");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Delete_Modify_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Directory_File_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Left_Content : constant String := "left file" & Character'Val (10);

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Files.Create_Directory_If_Missing
        (Version.Test_Support.Join (Root, "a"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a/b.txt"),
         "right nested" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a/b.txt");
      Version.Write.Save ("right directory");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a", Left_Content, "left file");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base directory/file merge must still report the conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base directory/file conflict must stage file side");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = Left_Content,
               "virtual-base directory/file conflict must materialize file content");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Directory_File_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Rename_Delete_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Left_Content : constant String :=
        "line one" & Character'Val (10)
        & "left rename edit" & Character'Val (10)
        & "line three" & Character'Val (10);

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Commit_File
        (Root,
         "old.txt",
         "line one" & Character'Val (10)
         & "line two" & Character'Val (10)
         & "line three" & Character'Val (10),
         "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "old.txt"));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("right deletes");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "old.txt"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "new.txt"), Left_Content);
      Version.Git_Fixtures.Run (Root, "git add old.txt new.txt");
      Version.Write.Save ("left renames and edits");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base rename/delete merge must still report the conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "new.txt", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base rename/delete conflict must stage renamed side");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = Left_Content,
               "virtual-base rename/delete conflict must materialize renamed content");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Rename_Delete_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Rename_Rename_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Base_Content : constant String :=
        "line one" & Character'Val (10)
        & "line two" & Character'Val (10)
        & "line three" & Character'Val (10);

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Commit_File (Root, "old.txt", Base_Content, "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "old.txt"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "right.txt"), Base_Content);
      Version.Git_Fixtures.Run (Root, "git add old.txt right.txt");
      Version.Write.Save ("right renames");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "old.txt"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "left.txt"), Base_Content);
      Version.Git_Fixtures.Run (Root, "git add old.txt left.txt");
      Version.Write.Save ("left renames");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base rename/rename merge must still report conflicts");

         declare
            Left_Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "left.txt", 0);
            Right_Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "right.txt", 0);
         begin
            Assert
              (Left_Pos /= Natural'Last,
               "virtual-base rename/rename conflict must stage current rename");
            Assert
              (Right_Pos /= Natural'Last,
               "virtual-base rename/rename conflict must stage target rename");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Rename_Rename_For_Recursive_Virtual_Base;


   procedure Merge_Materializes_Directory_Rename_For_Recursive_Virtual_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;
      Added_Content : constant String := "added" & Character'Val (10);

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Files.Create_Directory_If_Missing
        (Version.Test_Support.Join (Root, "old"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "old/base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old/base.txt");
      Version.Write.Save ("base directory");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Version.Git_Fixtures.Run (Root, "mkdir new");
      Version.Git_Fixtures.Run (Root, "mv old/base.txt new/base.txt");
      Version.Git_Fixtures.Run (Root, "rmdir old");
      Version.Git_Fixtures.Run (Root, "git add old new/base.txt");
      Version.Write.Save ("right renames directory");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "old/added.txt"), Added_Content);
      Version.Git_Fixtures.Run (Root, "git add old/added.txt");
      Version.Write.Save ("left adds under old directory");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Behavior.Materialize_Virtual_Conflicts := True;
         Behavior.Directory_Renames := Version.Merge.Directory_Renames_Conflict;

         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (not Conflicts.Is_Empty,
            "virtual-base directory-rename merge must still report conflict");

         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry
                (Merged_Index, "new/added.txt", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert
              (Pos /= Natural'Last,
               "virtual-base directory-rename conflict must stage moved addition");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = Added_Content,
               "virtual-base directory-rename conflict must materialize moved addition");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Directory_Rename_For_Recursive_Virtual_Base;

   procedure Merge_Octopus_Strategy_Rejects_Single_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Commit_File (Root, "feature.txt", "feature" & Character'Val (10), "feature");
      Version.Branch.Switch_Branch ("main");

      Options.Strategy := Version.Branch.Strategy_Octopus;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E), "octopus strategy") /= 0,
               "single-target octopus rejection must explain strategy mismatch");
      end;

      Assert (Raised, "single-target octopus strategy must be rejected");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Octopus_Strategy_Rejects_Single_Target;

   procedure Merge_Rename_Limit_Config_Disables_Similarity_Rename
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path : constant String := Version.Test_Support.Join (Root, "old.txt");
      New_Path : constant String := Version.Test_Support.Join (Root, "new.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config merge.renameLimit 1");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Old_Path,
         "alpha" & Character'Val (10)
         & "beta-main" & Character'Val (10)
         & "gamma" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add old.txt");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "git mv old.txt new.txt");
      Version.Test_Support.Write_Text_File
        (New_Path,
         "alpha" & Character'Val (10)
         & "beta" & Character'Val (10)
         & "gamma-feature" & Character'Val (10)
         & "delta" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "extra.txt"),
         "extra" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add extra.txt");
      Version.Write.Save ("feature rename and add");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "renameLimit must disable excess similarity rename scans");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "renameLimit similarity miss must leave conflict state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rename_Limit_Config_Disables_Similarity_Rename;

   procedure Merge_Rerere_Autoupdate_Records_Preimage
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config rerere.autoupdate true");

      Version.Test_Support.Write_Text_File (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "autoupdate-only rerere merge must still conflict first");
      Version.Git_Fixtures.Run
        (Root, "find .git/rr-cache -name preimage | grep -q preimage");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Rerere_Autoupdate_Records_Preimage;

   procedure Merge_External_Driver_Recursive_Delegates_To_Command
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Repo : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Object_Id_Storage;
      Left_Id : Version.Objects.Object_Id_Storage;
      Right_Id : Version.Objects.Object_Id_Storage;

      function Items_For
        (Commit_Id : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         return Version.Objects.Flatten_Tree
           (Repo => Repo,
            Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      end Items_For;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "a.txt merge=custom" & Character'Val (10));
      Version.Git_Fixtures.Run
        (Root, "git config merge.custom.recursive delegate");
      Version.Git_Fixtures.Run
        (Root, "git config merge.delegate.driver ""printf 'delegated\\n' > %A""");
      Version.Git_Fixtures.Run (Root, "git add .gitattributes");
      Version.Write.Save ("attrs");

      Commit_File (Root, "a.txt", "base" & Character'Val (10), "base");
      Repo := Version.Repository.Open;
      Base_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));
      Version.Branch.Create_Branch ("left");

      Commit_File (Root, "a.txt", "right" & Character'Val (10), "right");
      Right_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "a.txt", "left" & Character'Val (10), "left");
      Left_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Repo));

      declare
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Base_Id);
         Left_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Left_Id);
         Right_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Items_For (Right_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
         Behavior : Version.Merge.Merge_Behavior :=
           Version.Merge.Merge_Behavior'(others => <>);
      begin
         Behavior.Update_Worktree := False;
         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "left",
            Target_Name   => "right",
            Base_Items    => Base_Items,
            Current_Items => Left_Items,
            Target_Items  => Right_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Behavior);

         Assert
           (Conflicts.Is_Empty,
            "recursive external driver command must resolve virtual-base conflict");
         declare
            Pos : constant Natural :=
              Version.Staging.Find_Stage_Entry (Merged_Index, "a.txt", 0);
            Obj : Version.Objects.Git_Object;
         begin
            Assert (Pos /= Natural'Last, "delegated recursive driver must stage result");
            Obj := Version.Objects.Read_Object
              (Repo, Merged_Index.Element (Pos).Id);
            Assert
              (Version.Objects.Content (Obj) = "delegated" & Character'Val (10),
               "delegated recursive driver command must provide merged content");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_External_Driver_Recursive_Delegates_To_Command;

   procedure Merge_Multiple_Resolve_Strategy_Rejects_Octopus
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");

      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "left.txt", "left" & Character'Val (10), "left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Commit_File (Root, "right.txt", "right" & Character'Val (10), "right");
      Version.Branch.Switch_Branch ("main");

      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Options.Strategy := Version.Branch.Strategy_Resolve;
      begin
         Version.Branch.Merge_Multiple (Targets, Options);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E), "only one target") /= 0,
               "multi-target resolve rejection must explain strategy limit");
      end;

      Assert (Raised, "resolve strategy must reject multi-target merge");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_Resolve_Strategy_Rejects_Octopus;

   procedure History_Merge_Bases_Returns_Minimal_Common_Ancestors
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");

      Version.Git_Fixtures.Run (Root, "git checkout -b left");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "left.txt"),
         "left" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add left.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m left");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Git_Fixtures.Run (Root, "git checkout -b right");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "right.txt"),
         "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add right.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m right");
      Version.Git_Fixtures.Run (Root, "git checkout left");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff right -m left-merge");
      Version.Git_Fixtures.Run (Root, "git checkout right");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff left~1 -m right-merge");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Left_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "left");
         Right_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "right");
         Bases : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Merge_Bases
             (Repo => Repo, Left => Left_Id, Right => Right_Id);
      begin
         Assert
           (Natural (Bases.Length) = 2,
            "criss-cross history must expose both minimal merge bases");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end History_Merge_Bases_Returns_Minimal_Common_Ancestors;

   procedure Merge_Uses_Recursive_Virtual_Base_For_Criss_Cross
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Git_Fixtures.Run (Root, "git checkout -b left");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m left-one");

      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Git_Fixtures.Run (Root, "git checkout -b right");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m right-three");

      Version.Git_Fixtures.Run (Root, "git checkout left");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff right -m left-merges-right");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left2" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m left-two");

      Version.Git_Fixtures.Run (Root, "git checkout right");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff left~1 -m right-merges-left");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right2" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m right-two");

      Version.Git_Fixtures.Run (Root, "git checkout left");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("right", Options);

      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
         = "left2" & Character'Val (10)
           & "two" & Character'Val (10)
           & "right2",
         "criss-cross merge must use recursive virtual base");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "recursive-base merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Uses_Recursive_Virtual_Base_For_Criss_Cross;

   procedure Merge_Resolve_Strategy_Merges_Criss_Cross_Bases
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Git_Fixtures.Run (Root, "git checkout -b left");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m left-one");

      Version.Git_Fixtures.Run (Root, "git checkout main");
      Version.Git_Fixtures.Run (Root, "git checkout -b right");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m right-three");

      Version.Git_Fixtures.Run (Root, "git checkout left");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff right -m left-merges-right");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left2" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m left-two");

      Version.Git_Fixtures.Run (Root, "git checkout right");
      Version.Git_Fixtures.Run
        (Root, "git merge --no-ff left~1 -m right-merges-left");
      Version.Test_Support.Write_Text_File
        (File_Path,
         "left" & Character'Val (10)
         & "two" & Character'Val (10)
         & "right2" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m right-two");

      Version.Git_Fixtures.Run (Root, "git checkout left");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Strategy := Version.Branch.Strategy_Resolve;
      --  Real `git merge -s resolve` reduces to a single merge base here and
      --  completes the 3-way merge; it does not reject "criss-cross".
      Version.Branch.Merge ("right", Options);

      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "resolve criss-cross merge must complete without lingering state");
      Assert
        (Version.Test_Support.Read_Text_File (File_Path)
           = "left2" & Character'Val (10) & "two" & Character'Val (10) & "right2",
         "resolve criss-cross merge must produce the 3-way result");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Resolve_Strategy_Merges_Criss_Cross_Bases;

   procedure Merge_Gitlink_Addition_Does_Not_Read_Submodule_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");

      Version.Git_Fixtures.Run (Root, "git checkout -b feature");
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo "
         & "160000,1111111111111111111111111111111111111111,sub");
      Version.Git_Fixtures.Run (Root, "git commit -m gitlink");
      Version.Git_Fixtures.Run (Root, "git checkout main");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "main.txt"),
         "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);
      Version.Git_Fixtures.Run
        (Root,
         "git ls-tree HEAD sub | grep -q "
         & "'160000 commit 1111111111111111111111111111111111111111'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Gitlink_Addition_Does_Not_Read_Submodule_Object;

   procedure Merge_Materializes_Target_Symlink_Addition
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "README.md", "readme" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "ln -s README.md link-to-readme");
      Version.Git_Fixtures.Run (Root, "git add link-to-readme");
      Version.Write.Save ("feature symlink");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert_POSIX_Symlink (Root, "link-to-readme", "README.md");
      Version.Git_Fixtures.Run
        (Root, "git ls-files -s link-to-readme | grep -q '^120000'");
      Version.Git_Fixtures.Run (Root, "git diff --quiet -- link-to-readme");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "clean symlink addition merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Target_Symlink_Addition;

   procedure Merge_Materializes_Disabled_Symlink_As_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Link_Path : constant String := Version.Test_Support.Join (Root, "link-to-readme");
      Options : Version.Branch.Merge_Options;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config core.symlinks false");
      Commit_File (Root, "README.md", "readme" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");

      Commit_File (Root, "main.txt", "main" & Character'Val (10), "main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run (Root, "ln -s README.md link-to-readme");
      Version.Git_Fixtures.Run (Root, "git add link-to-readme");
      Version.Write.Save ("feature symlink");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (Link_Path) = "README.md",
         "core.symlinks=false merge must write link target as plain file");
      Version.Git_Fixtures.Run (Root, "test ! -L link-to-readme");
      Version.Git_Fixtures.Run
        (Root, "git ls-files -s link-to-readme | grep -q '^120000'");
      Version.Git_Fixtures.Run (Root, "git diff --quiet -- link-to-readme");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "disabled-symlink clean merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Materializes_Disabled_Symlink_As_File;

   procedure Merge_Multiple_Creates_Octopus_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "left.txt"),
         "left" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add left.txt");
      Version.Write.Save ("left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "right.txt"),
         "right" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add right.txt");
      Version.Write.Save ("right");

      Version.Branch.Switch_Branch ("main");
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge_Multiple (Targets, Options);

      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "left.txt")),
         "octopus merge must include the first target file");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "right.txt")),
         "octopus merge must include the second target file");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -n 1 HEAD | wc -w)"" = ""4""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_Creates_Octopus_Commit;

   procedure Merge_Multiple_Squash_Writes_Squash_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Targets : Version.Branch.Merge_Target_Vectors.Vector;
      Options : Version.Branch.Merge_Options;
      Before : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Before := Ada.Strings.Unbounded.To_Unbounded_String
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Create_Branch ("left");
      Version.Branch.Switch_Branch ("left");
      Commit_File (Root, "left.txt", "left" & Character'Val (10), "left");

      Version.Branch.Switch_Branch ("main");
      Version.Branch.Create_Branch ("right");
      Version.Branch.Switch_Branch ("right");
      Commit_File (Root, "right.txt", "right" & Character'Val (10), "right");

      Version.Branch.Switch_Branch ("main");
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("left"));
      Targets.Append (Ada.Strings.Unbounded.To_Unbounded_String ("right"));
      Options.Squash := True;
      Version.Branch.Merge_Multiple (Targets, Options);

      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Ada.Strings.Unbounded.To_String (Before),
         "multi-target squash must not advance HEAD");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "left.txt")),
         "multi-target squash must include first target content");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, "right.txt")),
         "multi-target squash must include second target content");
      Assert
        (Ada.Directories.Exists (Version.Test_Support.Join (Root, ".git/SQUASH_MSG")),
         "multi-target squash must write SQUASH_MSG");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Multiple_Squash_Writes_Squash_State;

   procedure Merge_Directory_File_Conflict_Writes_Unmerged_Stages
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Options : Version.Branch.Merge_Options;
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "base.txt"),
         "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir"),
         "main file" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir");
      Version.Write.Save ("main file at dir");

      Version.Branch.Switch_Branch ("feature");
      Ada.Directories.Create_Path (Version.Test_Support.Join (Root, "dir"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "dir/file.txt"),
         "feature nested" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add dir/file.txt");
      Version.Write.Save ("feature directory at dir");
      Version.Git_Fixtures.Run (Root, "git checkout main");

      begin
         Version.Branch.Merge ("feature", Options);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "directory/file merge must stop with a conflict");
      Version.Git_Fixtures.Run (Root, "test -n ""$(git ls-files -u)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Directory_File_Conflict_Writes_Unmerged_Stages;

   procedure Merge_Combines_Mode_And_Content_Changes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Script_Path : constant String :=
        Version.Test_Support.Join (Root, "script.sh");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Script_Path, "echo base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Git_Fixtures.Run (Root, "git update-index --chmod=+x script.sh");
      Version.Write.Save ("main executable bit");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Script_Path, "echo feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("feature content");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (Script_Path)
         = "echo feature",
         "mode/content merge must use the content-changing side");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD script.sh | grep -q '^100755'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Combines_Mode_And_Content_Changes;

   procedure Merge_Auto_Text_Merge_Preserves_Target_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Script_Path : constant String :=
        Version.Test_Support.Join (Root, "script.sh");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Script_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four" & Character'Val (10)
         & "five" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Script_Path,
         "one" & Character'Val (10)
         & "two-main" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four" & Character'Val (10)
         & "five" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("main edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Script_Path,
         "one" & Character'Val (10)
         & "two" & Character'Val (10)
         & "three" & Character'Val (10)
         & "four" & Character'Val (10)
         & "five-feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Git_Fixtures.Run (Root, "git update-index --chmod=+x script.sh");
      Version.Write.Save ("feature edit executable bit");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (Script_Path)
         = "one" & Character'Val (10)
           & "two-main" & Character'Val (10)
           & "three" & Character'Val (10)
           & "four" & Character'Val (10)
           & "five-feature",
         "auto text merge must combine independent edits");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD script.sh | grep -q '^100755'");
      if Version.Platform.Supports_Executable_Bit then
         Assert
           (GNAT.OS_Lib.Is_Executable_File (Script_Path),
            "auto text merge must materialize target executable bit");
      end if;
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "auto text merge plus target mode change must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Auto_Text_Merge_Preserves_Target_Mode;

   procedure Merge_Identical_Content_Preserves_Changed_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Script_Path : constant String :=
        Version.Test_Support.Join (Root, "script.sh");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Script_Path, "echo base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Script_Path, "echo shared" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Git_Fixtures.Run (Root, "git update-index --chmod=+x script.sh");
      Version.Write.Save ("main shared content executable bit");

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Script_Path, "echo shared" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add script.sh");
      Version.Write.Save ("feature shared content");
      Version.Branch.Switch_Branch ("main");

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Test_Support.Read_Text_File (Script_Path)
         = "echo shared",
         "identical content merge must keep shared content");
      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD script.sh | grep -q '^100755'");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "identical content plus mode merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Identical_Content_Preserves_Changed_Mode;

   procedure Merge_LFS_Pointer_Is_Ordinary_Blob
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Asset_Path : constant String := Version.Test_Support.Join (Root, "asset.bin");
      Main_Path : constant String := Version.Test_Support.Join (Root, "main.txt");
      Base_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:1111111111111111111111111111111111111111111111111111111111111111"
        & Character'Val (10)
        & "size 11" & Character'Val (10);
      Target_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:2222222222222222222222222222222222222222222222222222222222222222"
        & Character'Val (10)
        & "size 12" & Character'Val (10);
      LFS_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Root, ".git"), "lfs"),
                 "objects"),
              "22"),
           "22");
      LFS_Media : constant String := "large target";
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Version.Files.Create_Directory_If_Missing
        (Version.Test_Support.Join (Version.Test_Support.Join (Root, ".git"), "lfs"));
      Version.Files.Create_Directory_If_Missing
        (Version.Test_Support.Join
           (Version.Test_Support.Join (Version.Test_Support.Join (Root, ".git"), "lfs"),
            "objects"));
      Version.Files.Create_Directory_If_Missing
        (Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join (Version.Test_Support.Join (Root, ".git"), "lfs"),
               "objects"),
            "22"));
      Version.Files.Create_Directory_If_Missing (LFS_Object_Dir);
      Version.Files.Write_Binary_File
        (Version.Test_Support.Join
           (LFS_Object_Dir,
            "2222222222222222222222222222222222222222222222222222222222222222"),
         LFS_Media);
      Ada.Directories.Set_Directory (Root);

      Version.Files.Write_Binary_File (Asset_Path, Base_Pointer);
      Version.Test_Support.Write_Text_File
        (Main_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add asset.bin main.txt");
      Version.Write.Save ("base LFS pointer");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Main_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main side edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Files.Write_Binary_File (Asset_Path, Target_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");
      Version.Write.Save ("feature LFS pointer edit");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Files.Read_Binary_File (Asset_Path) = LFS_Media,
         "merge must smudge available LFS pointer media into the worktree");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Path) = "main",
         "merge must preserve current-side ordinary edits");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "LFS pointer merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_LFS_Pointer_Is_Ordinary_Blob;


   procedure Merge_LFS_Pointer_Fetches_Local_LFS_Url_Media
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Asset_Path : constant String := Version.Test_Support.Join (Root, "asset.bin");
      Main_Path : constant String := Version.Test_Support.Join (Root, "main.txt");
      Oid : constant String :=
        "3333333333333333333333333333333333333333333333333333333333333333";
      Base_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:1111111111111111111111111111111111111111111111111111111111111111"
        & Character'Val (10)
        & "size 11" & Character'Val (10);
      Target_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:" & Oid & Character'Val (10)
        & "size 13" & Character'Val (10);
      Remote_LFS : constant String := Version.Test_Support.Join (Root, "remote-lfs");
      Remote_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Remote_LFS, "objects"), "33"),
           "33");
      Local_Object_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Root, ".git"), "lfs"),
                 "objects"),
              "33"),
           Version.Test_Support.Join ("33", Oid));
      LFS_Media : constant String := "large fetched";
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Test_Repo (Root);
      Version.Files.Create_Directory_If_Missing (Remote_Object_Dir);
      Version.Files.Write_Binary_File
        (Version.Test_Support.Join (Remote_Object_Dir, Oid), LFS_Media);
      Version.Git_Fixtures.Run (Root, "git config lfs.url " & Remote_LFS);
      Ada.Directories.Set_Directory (Root);

      Version.Files.Write_Binary_File (Asset_Path, Base_Pointer);
      Version.Test_Support.Write_Text_File
        (Main_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add asset.bin main.txt");
      Version.Write.Save ("base LFS pointer");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Main_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main side edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Files.Write_Binary_File (Asset_Path, Target_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");
      Version.Write.Save ("feature LFS pointer edit");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Files.Read_Binary_File (Asset_Path) = LFS_Media,
         "merge must fetch missing LFS media from configured local lfs url");
      Assert
        (Version.Files.Read_Binary_File (Local_Object_Path) = LFS_Media,
         "fetched LFS media must be cached in local lfs storage");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "fetched LFS pointer merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_LFS_Pointer_Fetches_Local_LFS_Url_Media;


   procedure Merge_LFS_Pointer_Fetches_HTTP_Batch_Media
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Ada.Streams;

      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Asset_Path : constant String := Version.Test_Support.Join (Root, "asset.bin");
      Main_Path : constant String := Version.Test_Support.Join (Root, "main.txt");
      Oid : constant String :=
        "4444444444444444444444444444444444444444444444444444444444444444";
      Base_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:1111111111111111111111111111111111111111111111111111111111111111"
        & Character'Val (10)
        & "size 11" & Character'Val (10);
      Target_Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:" & Oid & Character'Val (10)
        & "size 10" & Character'Val (10);
      LFS_Media : constant String := "http media";
      Local_Object_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Root, ".git"), "lfs"),
                 "objects"),
              "44"),
           Version.Test_Support.Join ("44", Oid));
      Options : Version.Branch.Merge_Options;

      function To_Stream (Text : String) return Stream_Element_Array is
         Result : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
         J      : Stream_Element_Offset := Result'First;
      begin
         for C of Text loop
            Result (J) := Stream_Element (Character'Pos (C));
            J := J + 1;
         end loop;

         return Result;
      end To_Stream;

      function Contains
        (Data    : Stream_Element_Array;
         Last    : Stream_Element_Offset;
         Pattern : String) return Boolean
      is
         Text : String (1 .. Natural (Last));
      begin
         if Last < Data'First then
            return False;
         end if;

         for I in 1 .. Natural (Last) loop
            Text (I) := Character'Val (Data (Stream_Element_Offset (I)));
         end loop;

         return Ada.Strings.Fixed.Index (Text, Pattern) /= 0;
      end Contains;

      task type LFS_Server is
         entry Ready (Port : out GNAT.Sockets.Port_Type);
      end LFS_Server;

      task body LFS_Server is
         CR : constant Character := Character'Val (13);
         LF : constant Character := Character'Val (10);
         Server  : GNAT.Sockets.Socket_Type;
         Client  : GNAT.Sockets.Socket_Type;
         Address : constant GNAT.Sockets.Sock_Addr_Type :=
           (Family => GNAT.Sockets.Family_Inet,
            Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
            Port   => 0);
         Peer    : GNAT.Sockets.Sock_Addr_Type;
         Bound   : GNAT.Sockets.Sock_Addr_Type;
         Request : Stream_Element_Array (1 .. 8192);
         Last    : Stream_Element_Offset;
         Sent    : Stream_Element_Offset;

         procedure Send_Text_Response (Payload : String; Content_Type : String) is
            Header : constant String :=
              "HTTP/1.1 200 OK" & CR & LF
              & "Content-Type: " & Content_Type & CR & LF
              & "Content-Length:" & Integer'Image (Payload'Length) & CR & LF
              & "Connection: close" & CR & LF
              & CR & LF;
            Header_Data : constant Stream_Element_Array := To_Stream (Header);
            Body_Data   : constant Stream_Element_Array := To_Stream (Payload);
         begin
            GNAT.Sockets.Send_Socket (Client, Header_Data, Sent);
            GNAT.Sockets.Send_Socket (Client, Body_Data, Sent);
         end Send_Text_Response;
      begin
         GNAT.Sockets.Create_Socket (Server);
         GNAT.Sockets.Set_Socket_Option
           (Socket => Server,
            Level  => GNAT.Sockets.Socket_Level,
            Option => (Name => GNAT.Sockets.Reuse_Address,
                       Enabled => True));
         GNAT.Sockets.Bind_Socket (Server, Address);
         Bound := GNAT.Sockets.Get_Socket_Name (Server);
         GNAT.Sockets.Listen_Socket (Server);

         accept Ready (Port : out GNAT.Sockets.Port_Type) do
            Port := Bound.Port;
         end Ready;

         --  A merge materializes the worktree via two paths (merge write and
         --  final restore), so it issues the batch+media exchange twice; a
         --  real LFS server serves repeated requests, so serve both rounds.
         for Round in 1 .. 2 loop
            GNAT.Sockets.Accept_Socket (Server, Client, Peer);
            GNAT.Sockets.Receive_Socket (Client, Request, Last);
            if Contains (Request, Last, "POST /repo.git/info/lfs/objects/batch HTTP/")
              and then Contains (Request, Last, "Content-Type: application/vnd.git-lfs+json")
              and then Contains (Request, Last, Oid)
            then
               Send_Text_Response
                 ("{""objects"":[{""oid"":""" & Oid
                  & """,""size"":10,""actions"":{""download"":{""href"":""http://127.0.0.1:"
                  & Ada.Strings.Fixed.Trim
                      (GNAT.Sockets.Port_Type'Image (Bound.Port), Ada.Strings.Left)
                  & "/media/" & Oid & """}}}]}",
                  "application/vnd.git-lfs+json");
            else
               Send_Text_Response ("bad batch", "text/plain");
            end if;
            GNAT.Sockets.Close_Socket (Client);

            GNAT.Sockets.Accept_Socket (Server, Client, Peer);
            GNAT.Sockets.Receive_Socket (Client, Request, Last);
            if Contains (Request, Last, "GET /media/" & Oid & " HTTP/") then
               Send_Text_Response (LFS_Media, "application/octet-stream");
            else
               Send_Text_Response ("bad media", "text/plain");
            end if;
            GNAT.Sockets.Close_Socket (Client);
         end loop;
         GNAT.Sockets.Close_Socket (Server);
      end LFS_Server;

      Server : LFS_Server;
      Port   : GNAT.Sockets.Port_Type;
   begin
      Configure_Test_Repo (Root);
      Server.Ready (Port);
      Version.Git_Fixtures.Run
        (Root,
         "git config lfs.url http://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (GNAT.Sockets.Port_Type'Image (Port), Ada.Strings.Left)
         & "/repo.git/info/lfs");
      Ada.Directories.Set_Directory (Root);

      Version.Files.Write_Binary_File (Asset_Path, Base_Pointer);
      Version.Test_Support.Write_Text_File
        (Main_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add asset.bin main.txt");
      Version.Write.Save ("base LFS pointer");
      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Main_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main side edit");

      Version.Branch.Switch_Branch ("feature");
      Version.Files.Write_Binary_File (Asset_Path, Target_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");
      Version.Write.Save ("feature LFS pointer edit");

      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Version.Branch.Merge ("feature", Options);

      Assert
        (Version.Files.Read_Binary_File (Asset_Path) = LFS_Media,
         "merge must fetch missing LFS media through HTTP batch API");
      Assert
        (Version.Files.Read_Binary_File (Local_Object_Path) = LFS_Media,
         "HTTP fetched LFS media must be cached in local lfs storage");
      Assert
        (not Version.Merge_State.State_Exists (Version.Repository.Open),
         "HTTP LFS pointer merge must not leave merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_LFS_Pointer_Fetches_HTTP_Batch_Media;

   procedure Switch_Branch_Head_Lock_Preserves_Current_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String := Head_Lock_Path (Root);
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (A_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      declare
         Head_Before : constant String :=
           Version.Files.Read_Binary_File (Version.Test_Support.Join (Root, ".git/HEAD"));
         Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
      begin
         Version.Test_Support.Write_Text_File (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Branch.Switch_Branch ("feature");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "stale HEAD lock must fail branch switch");
         Assert
           (Version.Files.Read_Binary_File (Version.Test_Support.Join (Root, ".git/HEAD"))
            = Head_Before,
            "failed HEAD-lock branch switch must preserve HEAD");
         Assert
           (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
            "failed HEAD-lock branch switch must preserve index bytes");
         Assert
           (Version.Test_Support.Read_Text_File (A_Path) = "base",
            "failed HEAD-lock branch switch must preserve worktree");
         Assert
           (Version.Branch.Current_Branch_Name = "main",
            "failed HEAD-lock branch switch must preserve current branch");
         Assert
           (Ada.Directories.Exists (Lock_Path),
            "failed HEAD-lock branch switch must preserve stale lock");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Head_Lock_Preserves_Current_State;

   procedure Switch_Branch_Reflog_Lock_Preserves_Current_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String := Head_Reflog_Lock_Path (Root);
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (A_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      declare
         Head_Before : constant String :=
           Version.Files.Read_Binary_File (Version.Test_Support.Join (Root, ".git/HEAD"));
         Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
      begin
         Version.Test_Support.Write_Text_File (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Branch.Switch_Branch ("feature");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "stale HEAD reflog lock must fail branch switch");
         Assert
           (Version.Files.Read_Binary_File (Version.Test_Support.Join (Root, ".git/HEAD"))
            = Head_Before,
            "failed HEAD-reflog-lock branch switch must preserve HEAD");
         Assert
           (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
            "failed HEAD-reflog-lock branch switch must preserve index bytes");
         Assert
           (Version.Test_Support.Read_Text_File (A_Path) = "base",
            "failed HEAD-reflog-lock branch switch must preserve worktree");
         Assert
           (Version.Branch.Current_Branch_Name = "main",
            "failed HEAD-reflog-lock branch switch must preserve current branch");
         Assert
           (Ada.Directories.Exists (Lock_Path),
            "failed HEAD-reflog-lock branch switch must preserve stale lock");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Reflog_Lock_Preserves_Current_State;

   procedure Switch_Branch_Appends_HEAD_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      declare
         Old_Id : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);

         New_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Root, ".git/refs/heads/main"));
      begin
         Version.Branch.Switch_Branch ("main");

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            Old_Id & " " & New_Id,
            "branch switch HEAD reflog must contain old and new commit ids");

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            "branch switch: moving from feature to main",
            "branch switch must append a HEAD reflog entry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_Appends_HEAD_Reflog;

   procedure Update_Current_Branch_Appends_Reflogs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("two");

      Version.Branch.Switch_Branch ("main");

      declare
         Old_Id : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);

         New_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Root, ".git/refs/heads/feature"));
      begin
         Version.Branch.Update_Current_Branch ("feature");

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            Old_Id & " " & New_Id,
            "branch update HEAD reflog must contain old and new commit ids");

         Assert_File_Contains
           (Branch_Reflog_Path (Root, "main"),
            Old_Id & " " & New_Id,
            "branch update branch reflog must contain old and new commit ids");

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            "branch update: fast-forward to feature",
            "branch update must append a HEAD reflog entry");

         Assert_File_Contains
           (Branch_Reflog_Path (Root, "main"),
            "branch update: fast-forward to feature",
            "branch update must append a current branch reflog entry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Update_Current_Branch_Appends_Reflogs;

   procedure Integrate_Branch_Appends_Reflogs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Main_Path : constant String :=
        Version.Test_Support.Join (Root, "main.txt");

      Feature_Path : constant String :=
        Version.Test_Support.Join (Root, "feature.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Main_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Main_Path, "main change" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (Feature_Path, "feature change" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");

      Version.Branch.Switch_Branch ("main");

      declare
         Old_Id : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Branch.Integrate_Branch ("feature");

         declare
            New_Id : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Assert_File_Contains
              (Head_Reflog_Path (Root),
               Old_Id & " " & New_Id,
               "branch integrate HEAD reflog must contain old and new commit ids");

            Assert_File_Contains
              (Branch_Reflog_Path (Root, "main"),
               Old_Id & " " & New_Id,
               "branch integrate branch reflog must contain old and new commit ids");
         end;

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            "branch integrate: merge feature",
            "branch integrate must append a HEAD reflog entry");

         Assert_File_Contains
           (Branch_Reflog_Path (Root, "main"),
            "branch integrate: merge feature",
            "branch integrate must append a current branch reflog entry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Integrate_Branch_Appends_Reflogs;

   procedure Finalize_Integration_Appends_Reflogs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Integrate_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised, "conflicting integrate must leave merge state for finalize");

      Version.Test_Support.Write_Text_File
        (File_Path, "resolved" & Character'Val (10));

      declare
         Old_Id : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Branch.Finalize_Integration;

         declare
            New_Id : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Assert_File_Contains
              (Head_Reflog_Path (Root),
               Old_Id & " " & New_Id,
               "finalize integration HEAD reflog must contain old and new commit ids");

            Assert_File_Contains
              (Branch_Reflog_Path (Root, "main"),
               Old_Id & " " & New_Id,
               "finalize integration branch reflog must contain old and new commit ids");
         end;

         Assert_File_Contains
           (Head_Reflog_Path (Root),
            "branch finalize: merge finalized feature",
            "finalize integration must append a HEAD reflog entry");

         Assert_File_Contains
           (Branch_Reflog_Path (Root, "main"),
            "branch finalize: merge finalized feature",
            "finalize integration must append a current branch reflog entry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Finalize_Integration_Appends_Reflogs;

   procedure Rename_Branch_Moves_Ref_And_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      Version.Branch.Rename_Branch ("feature", "topic");

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse topic)"" = ""$(git rev-parse refs/heads/topic)""");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git branch --list feature)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Assert
        (not Ada.Directories.Exists
               (Branch_Reflog_Path (Root, "feature")),
         "rename must remove the old branch reflog path");

      Assert_File_Contains
        (Branch_Reflog_Path (Root, "topic"),
         "branch: renamed feature to topic",
         "rename must append a branch reflog entry at the new name");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Branch_Moves_Ref_And_Reflog;

   procedure Rename_Branch_From_Linked_Worktree_Uses_Common_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-linked";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Create_Branch ("linked");
      Version.Worktrees.Add (Path => Work, Branch => "linked");

      declare
         Linked_Git_Dir : constant String :=
           Version.Repository.Resolve_Git_Dir (Work);
         Linked_Topic_Log : constant String :=
           Version.Files.Join (Linked_Git_Dir, "logs/refs/heads/topic");

         procedure Rename_From_Linked is
         begin
            Version.Branch.Rename_Branch ("feature", "topic");
         end Rename_From_Linked;
      begin
         Assert
           (Ada.Directories.Exists (Branch_Reflog_Path (Root, "feature")),
            "setup must create common feature branch reflog");

         Version.Files.With_Directory (Work, Rename_From_Linked'Access);

         Assert
           (not Ada.Directories.Exists (Branch_Reflog_Path (Root, "feature")),
            "linked rename must remove old common branch reflog");
         Assert_File_Contains
           (Branch_Reflog_Path (Root, "topic"),
            "branch: renamed feature to topic",
            "linked rename must append new common branch reflog");
         Assert
           (not Ada.Directories.Exists (Linked_Topic_Log),
            "linked rename must not create per-worktree branch reflog");
      end;

      Version.Worktrees.Remove (Work);
      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Branch_From_Linked_Worktree_Uses_Common_Reflog;

   procedure Rename_Branch_Rejects_Non_File_Source_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Log_Path : constant String := Branch_Reflog_Path (Root, "feature");
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Make_Non_File_Branch_Reflog (Root, "feature");

      begin
         Version.Branch.Rename_Branch ("feature", "topic");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch rename must reject non-file source reflog");
      Assert
        (Version.Refs.Ref_Exists (Version.Repository.Open, "refs/heads/feature"),
         "failed branch rename must preserve source branch");
      Assert
        (not Version.Refs.Ref_Exists (Version.Repository.Open, "refs/heads/topic"),
         "failed branch rename must not create destination branch");
      Assert
        (Ada.Directories.Exists (Log_Path)
         and then Ada.Directories.Kind (Log_Path) = Ada.Directories.Directory,
         "failed branch rename must preserve non-file source reflog");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Branch_Rejects_Non_File_Source_Reflog;

   procedure Rename_Branch_Rolls_Back_On_Packed_Delete_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      declare
         Repo       : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Feature_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         Lock_Path  : constant String := Packed_Refs_Lock_Path (Root);
         Raised     : Boolean := False;
      begin
         Version.Branch.Switch_Branch ("main");
         Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");
         Version.Test_Support.Write_Text_File
           (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Branch.Rename_Branch ("feature", "topic");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Version.Files.Delete_File_If_Exists (Lock_Path);

         Assert
           (Raised,
            "branch rename must report packed-ref delete failure");
         Assert
           (Version.Refs.Ref_Exists (Repo, "refs/heads/feature"),
            "failed branch rename must preserve source branch");
         Assert
           (not Version.Refs.Ref_Exists (Repo, "refs/heads/topic"),
            "failed branch rename must remove destination branch");
         Assert
           (To_String (Version.Revisions.Resolve_Commit (Repo, "feature"))
            = Feature_Id,
            "failed branch rename must preserve source commit id");
         Assert
           (not Ada.Directories.Exists
                  (Branch_Reflog_Path (Root, "topic")),
            "failed branch rename must remove destination reflog");
         Version.Git_Fixtures.Run
           (Root, "test ""$(git symbolic-ref HEAD)"" = refs/heads/main");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Branch_Rolls_Back_On_Packed_Delete_Failure;

   procedure Rename_Current_Branch_Updates_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);

      Version.Branch.Rename_Current_Branch ("trunk");

      Version.Git_Fixtures.Run
        (Root, "test ""$(git symbolic-ref HEAD)"" = refs/heads/trunk");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git branch --list main)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Assert_File_Contains
        (Head_Reflog_Path (Root),
         "branch: renamed main to trunk",
         "current branch rename must append a HEAD reflog entry");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_Current_Branch_Updates_HEAD;

   procedure Delete_Merged_Branch_Removes_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Delete_Branch (Name => "feature", Force => False);

      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git branch --list feature)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Merged_Branch_Removes_Ref;

   procedure Delete_Branch_Rejects_Non_File_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Log_Path : constant String := Branch_Reflog_Path (Root, "feature");
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");

      declare
         Feature_Id : constant String :=
           To_String
             (Version.Refs.Resolve_Ref
                (Repo => Version.Repository.Open,
                 Name => "refs/heads/feature"));
      begin
         Make_Non_File_Branch_Reflog (Root, "feature");

         begin
            Version.Branch.Delete_Branch (Name => "feature", Force => False);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "branch delete must reject non-file branch reflog");
         Assert
           (Ada.Directories.Exists (Log_Path)
            and then Ada.Directories.Kind (Log_Path) = Ada.Directories.Directory,
            "failed branch delete must preserve non-file branch reflog");
         Assert
           (Version.Refs.Ref_Exists (Version.Repository.Open, "refs/heads/feature"),
            "failed branch delete must preserve branch ref");
         Assert
           (To_String
              (Version.Refs.Resolve_Ref
                 (Repo => Version.Repository.Open,
                  Name => "refs/heads/feature")) = Feature_Id,
            "failed branch delete must preserve original branch id");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Branch_Rejects_Non_File_Reflog;

   procedure Delete_Branch_Rejects_Restore_Lock_Before_Delete
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Lock_Path : constant String := Branch_Ref_Lock_Path (Root, "feature");
      Raised : Boolean := False;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);
      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Lock_Path, "stale" & Character'Val (10));

      begin
         Version.Branch.Delete_Branch (Name => "feature", Force => False);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch delete must reject stale restore lock");
      Assert
        (Version.Refs.Ref_Exists (Version.Repository.Open, "refs/heads/feature"),
         "restore-lock preflight must preserve branch ref");
      Assert
        (Ada.Directories.Exists (Lock_Path),
         "restore-lock preflight must preserve stale lock");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Branch_Rejects_Restore_Lock_Before_Delete;

   procedure Delete_Branch_Rolls_Back_On_Packed_Delete_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Test_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_Base_Commit (Root);

      Version.Branch.Create_Branch ("feature");

      declare
         Repo       : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Feature_Id : constant String :=
           To_String (Version.Revisions.Resolve_Commit (Repo, "feature"));
         Lock_Path  : constant String := Packed_Refs_Lock_Path (Root);
         Raised     : Boolean := False;
      begin
         Version.Git_Fixtures.Run (Root, "git pack-refs --all --prune");
         Version.Test_Support.Write_Text_File
           (Lock_Path, "locked" & Character'Val (10));

         begin
            Version.Branch.Delete_Branch (Name => "feature", Force => False);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Version.Files.Delete_File_If_Exists (Lock_Path);

         Assert
           (Raised,
            "branch delete must report packed-ref delete failure");
         Assert
           (Version.Refs.Ref_Exists (Repo, "refs/heads/feature"),
            "failed branch delete must preserve branch");
         Assert
           (To_String (Version.Revisions.Resolve_Commit (Repo, "feature"))
            = Feature_Id,
            "failed branch delete must preserve branch commit id");
         Version.Git_Fixtures.Run (Root, "git show-ref --verify refs/heads/feature");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Branch_Rolls_Back_On_Packed_Delete_Failure;

   procedure Delete_Rejects_Current_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised    : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      begin
         Version.Branch.Delete_Branch (Name => "main", Force => True);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "delete must reject the current symbolic branch");
      Version.Git_Fixtures.Run (Root, "git show-ref --verify refs/heads/main");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Rejects_Current_Branch;

   procedure Delete_Rejects_Unmerged_Unless_Forced
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised    : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      begin
         Version.Branch.Delete_Branch (Name => "feature", Force => False);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "non-force delete must reject an unmerged branch");
      Version.Git_Fixtures.Run
        (Root, "git show-ref --verify refs/heads/feature");

      Version.Branch.Delete_Branch (Name => "feature", Force => True);

      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git branch --list feature)""");
      Assert
        (not Ada.Directories.Exists
               (Branch_Reflog_Path (Root, "feature")),
         "force delete must remove the deleted branch reflog");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Rejects_Unmerged_Unless_Forced;

   procedure Rename_One_Arg_Rejects_Detached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised    : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Checkout.Checkout_Commit (Commit);
      end;

      begin
         Version.Branch.Rename_Current_Branch ("detached-name");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "one-argument branch rename must reject detached HEAD");
      Version.Git_Fixtures.Run (Root, "git show-ref --verify refs/heads/main");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rename_One_Arg_Rejects_Detached_HEAD;

   procedure Branch_List_Verbose_Prints_Tip_And_Subject
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Main_Id   : Version.Objects.Object_Id_Storage;
      Text      : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial subject");
      Main_Id :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Branch.Create_Branch ("feature");

      Text :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Branch.List_Branches_Verbose_Text);

      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Text), "  feature")
         /= 0,
         "verbose branch list must include non-current branches");
      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Text), "* main")
         /= 0,
         "verbose branch list must mark the current branch");
      declare
         Main_Text : constant String := To_String (Main_Id);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Ada.Strings.Unbounded.To_String (Text),
               Main_Text (Main_Text'First .. Main_Text'First + 11)
               & " initial subject")
            /= 0,
            "verbose branch list must include short tip id and commit subject");
      end;

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_List_Verbose_Prints_Tip_And_Subject;

   procedure Branch_List_Verbose_Omits_Malformed_Loose_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Broken_Ref : constant String :=
        Version.Test_Support.Join (Root, ".git/refs/heads/broken");
      Text : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("initial subject");
      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File (Broken_Ref, "not-an-object-id");

      Text :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Branch.List_Branches_Verbose_Text);

      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Text), "* main")
         /= 0,
         "verbose branch list must include the current branch");
      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Text), "  feature")
         /= 0,
         "verbose branch list must include valid loose branches");
      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Text), "broken")
         = 0,
         "verbose branch list must omit malformed loose branch refs");
      Assert
        (Version.Test_Support.Read_Text_File (Broken_Ref) = "not-an-object-id",
         "verbose branch list must not rewrite malformed loose branch refs");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_List_Verbose_Omits_Malformed_Loose_Refs;

   procedure Branch_Exists_Returns_True_For_Existing_Branch_And_False_For_Missing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Assert
        (Version.Branch.Branch_Exists ("main"),
         "branch exists must report the current branch after the first commit");

      Assert
        (Version.Branch.Branch_Exists ("feature"),
         "branch exists must report explicitly created branches");

      Assert
        (not Version.Branch.Branch_Exists ("missing"),
         "branch exists must return false for absent branch refs");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Exists_Returns_True_For_Existing_Branch_And_False_For_Missing;

   procedure Branch_Exists_Returns_False_For_Malformed_Loose_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Ref_Path : constant String :=
        Version.Test_Support.Join (Root, ".git/refs/heads/broken");
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File (Ref_Path, "not-an-object-id");

      Assert
        (not Version.Branch.Branch_Exists ("broken"),
         "branch exists must return false for malformed loose branch refs");
      Assert
        (Version.Test_Support.Read_Text_File (Ref_Path) = "not-an-object-id",
         "branch exists must not rewrite malformed loose branch refs");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Exists_Returns_False_For_Malformed_Loose_Ref;

   procedure Branch_Exists_Rejects_Invalid_Branch_Name
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         if Version.Branch.Branch_Exists ("bad..name") then
            Assert
              (False, "invalid branch name must not be reported as existing");
         end if;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch exists must reject invalid branch names");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Exists_Rejects_Invalid_Branch_Name;

   procedure Branch_Resolve_Prints_Loose_And_Packed_Branch_Tips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Main_Id   : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Main_Id :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Create_Branch ("feature");

      Assert
        (Version.Branch.Resolve_Branch_Text ("main")
         = To_String (Main_Id) & Character'Val (10),
         "branch resolve must print the loose branch tip object id plus newline");

      Version.Git_Fixtures.Run (Root, "git pack-refs --all");

      Assert
        (Version.Branch.Resolve_Branch_Text ("feature")
         = To_String (Main_Id) & Character'Val (10),
         "branch resolve must print packed branch tip object ids");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Resolve_Prints_Loose_And_Packed_Branch_Tips;

   procedure Branch_Resolve_Rejects_Missing_And_Invalid_Branch_Names
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Missing_Raised : Boolean := False;
      Invalid_Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Text : constant String :=
              Version.Branch.Resolve_Branch_Text ("missing");
         begin
            Assert
              (Text = "", "missing branch must not produce resolve output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Missing_Raised := True;
      end;

      begin
         declare
            Text : constant String :=
              Version.Branch.Resolve_Branch_Text ("bad..name");
         begin
            Assert
              (Text = "",
               "invalid branch name must not produce resolve output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Invalid_Raised := True;
      end;

      Assert (Missing_Raised, "branch resolve must reject missing branches");
      Assert
        (Invalid_Raised, "branch resolve must reject invalid branch names");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Resolve_Rejects_Missing_And_Invalid_Branch_Names;

   procedure Branch_Contains_Lists_Branches_Reaching_Revision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Base_Id   : Version.Objects.Object_Id_Storage;
      Main_Id   : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Base_Id :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");
      Main_Id :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");
      Version.Branch.Switch_Branch ("main");

      Assert
        (Version.Branch.Branches_Containing_Text (To_String (Base_Id))
         = "feature" & Character'Val (10) & "main" & Character'Val (10),
         "branch contains must list every branch whose tip reaches the revision");

      Assert
        (Version.Branch.Branches_Containing_Text (To_String (Main_Id))
         = "main" & Character'Val (10),
         "branch contains must exclude branches that do not contain the revision");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Contains_Lists_Branches_Reaching_Revision;

   procedure Branch_Contains_Rejects_Unknown_Revision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Text : constant String :=
              Version.Branch.Branches_Containing_Text ("does-not-exist");
         begin
            Assert (Text = "", "unknown revision must not produce output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch contains must reject unknown revisions");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Contains_Rejects_Unknown_Revision;

   procedure Branch_Merged_Lists_Branches_Merged_Into_Current_Or_Named_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Assert
        (Version.Branch.Merged_Branches_Text
         = "feature" & Character'Val (10) & "main" & Character'Val (10),
         "branch merged must list branches whose tips are ancestors of the current branch");

      Assert
        (Version.Branch.Merged_Branches_Text ("feature")
         = "feature" & Character'Val (10),
         "branch merged named base must use the selected branch tip");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Merged_Lists_Branches_Merged_Into_Current_Or_Named_Base;

   procedure Branch_Merged_Rejects_Missing_Base_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Text : constant String :=
              Version.Branch.Merged_Branches_Text ("missing");
         begin
            Assert (Text = "", "missing branch must not produce output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch merged must reject a missing base branch");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Merged_Rejects_Missing_Base_Branch;

   procedure Branch_Unmerged_Lists_Branches_Not_Merged_Into_Current_Or_Named_Base
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature");

      Version.Branch.Switch_Branch ("main");

      Version.Test_Support.Write_Text_File
        (File_Path, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main");

      Assert
        (Version.Branch.Unmerged_Branches_Text
         = "feature" & Character'Val (10),
         "branch unmerged must list branches whose tips are not ancestors of the current branch");

      Assert
        (Version.Branch.Unmerged_Branches_Text ("feature")
         = "main" & Character'Val (10),
         "branch unmerged named base must use the selected branch tip");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Unmerged_Lists_Branches_Not_Merged_Into_Current_Or_Named_Base;

   procedure Branch_Unmerged_Rejects_Missing_Base_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Text : constant String :=
              Version.Branch.Unmerged_Branches_Text ("missing");
         begin
            Assert (Text = "", "missing branch must not produce output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch unmerged must reject a missing base branch");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Unmerged_Rejects_Missing_Base_Branch;

   procedure Branch_Upstream_Prints_Current_Or_Named_Branch_Upstream
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      Version.Git_Fixtures.Run
        (Root,
         "git config remote.origin.url https://example.invalid/project.git");
      Version.Git_Fixtures.Run (Root, "git config branch.main.remote origin");
      Version.Git_Fixtures.Run
        (Root, "git config branch.main.merge refs/heads/main");

      Version.Branch.Create_Branch ("feature");
      Version.Git_Fixtures.Run
        (Root, "git config branch.feature.remote origin");
      Version.Git_Fixtures.Run
        (Root, "git config branch.feature.merge refs/heads/feature");

      Assert
        (Version.Branch.Upstream_Text = "origin/main" & Character'Val (10),
         "branch upstream must default to the current branch");

      Assert
        (Version.Branch.Upstream_Text ("feature")
         = "origin/feature" & Character'Val (10),
         "branch upstream named form must use the selected branch");

      Version.Git_Fixtures.Run (Root, "git diff --quiet");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Upstream_Prints_Current_Or_Named_Branch_Upstream;

   procedure Branch_Upstream_Rejects_Missing_Upstream_And_Missing_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir                 : constant String :=
        Ada.Directories.Current_Directory;
      Missing_Upstream_Raised : Boolean := False;
      Missing_Branch_Raised   : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Text : constant String := Version.Branch.Upstream_Text;
         begin
            Assert (Text = "", "missing upstream must not produce output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Missing_Upstream_Raised := True;
      end;

      begin
         declare
            Text : constant String := Version.Branch.Upstream_Text ("missing");
         begin
            Assert (Text = "", "missing branch must not produce output");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Missing_Branch_Raised := True;
      end;

      Assert
        (Missing_Upstream_Raised,
         "branch upstream must reject missing upstream config");
      Assert
        (Missing_Branch_Raised,
         "branch upstream must reject missing branches");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Upstream_Rejects_Missing_Upstream_And_Missing_Branch;

   procedure Current_Branch_Prints_Attached_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Assert
        (Version.Branch.Current_Branch_Name = "main",
         "branch current must return the attached branch name");

      Assert
        (Version.Branch.Current_Branch_Text = "main" & Character'Val (10),
         "branch current text must be branch name plus newline only");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Current_Branch_Prints_Attached_Branch;

   procedure Current_Branch_Rejects_Detached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised    : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Checkout.Checkout_Commit (Commit);
      end;

      begin
         declare
            Name : constant String := Version.Branch.Current_Branch_Name;
         begin
            Assert
              (Name = "", "detached branch current must not return a branch");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch current must reject detached HEAD");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Current_Branch_Rejects_Detached_HEAD;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Create_Branch_From_Current_Commit'Access,
         "Branch: create branch at current commit");

      Register_Routine
        (T,
         Create_Branch_Rejects_Existing_Lock'Access,
         "Branch: create rejects existing lock");

      Register_Routine
        (T,
         Current_Branch_Prints_Attached_Branch'Access,
         "Branch: current prints attached branch");

      Register_Routine
        (T,
         Current_Branch_Rejects_Detached_HEAD'Access,
         "Branch: current rejects detached HEAD");

      Register_Routine
        (T,
         Branch_List_Verbose_Prints_Tip_And_Subject'Access,
         "Branch: verbose list prints tip and subject");
      Register_Routine
        (T,
         Branch_List_Verbose_Omits_Malformed_Loose_Refs'Access,
         "Branch: verbose list omits malformed loose refs");

      Register_Routine
        (T,
         Branch_Exists_Returns_True_For_Existing_Branch_And_False_For_Missing'Access,
         "Branch: exists reports present and missing branches");
      Register_Routine
        (T,
         Branch_Exists_Returns_False_For_Malformed_Loose_Ref'Access,
         "Branch: exists rejects malformed loose branch refs");

      Register_Routine
        (T,
         Branch_Exists_Rejects_Invalid_Branch_Name'Access,
         "Branch: exists rejects invalid names");

      Register_Routine
        (T,
         Branch_Resolve_Prints_Loose_And_Packed_Branch_Tips'Access,
         "Branch: resolve prints loose and packed branch tips");

      Register_Routine
        (T,
         Branch_Resolve_Rejects_Missing_And_Invalid_Branch_Names'Access,
         "Branch: resolve rejects missing and invalid branch names");

      Register_Routine
        (T,
         Branch_Upstream_Prints_Current_Or_Named_Branch_Upstream'Access,
         "Branch: upstream prints current or named branch upstream");

      Register_Routine
        (T,
         Branch_Upstream_Rejects_Missing_Upstream_And_Missing_Branch'Access,
         "Branch: upstream rejects missing upstream or branch");

      Register_Routine
        (T,
         Branch_Contains_Lists_Branches_Reaching_Revision'Access,
         "Branch: contains lists branches reaching revision");

      Register_Routine
        (T,
         Branch_Contains_Rejects_Unknown_Revision'Access,
         "Branch: contains rejects unknown revision");

      Register_Routine
        (T,
         Branch_Merged_Lists_Branches_Merged_Into_Current_Or_Named_Base'Access,
         "Branch: merged lists branches merged into current or named branch");

      Register_Routine
        (T,
         Branch_Merged_Rejects_Missing_Base_Branch'Access,
         "Branch: merged rejects missing base branch");

      Register_Routine
        (T,
         Branch_Unmerged_Lists_Branches_Not_Merged_Into_Current_Or_Named_Base'Access,
         "Branch: unmerged lists branches not merged into current or named branch");

      Register_Routine
        (T,
         Branch_Unmerged_Rejects_Missing_Base_Branch'Access,
         "Branch: unmerged rejects missing base branch");

      Register_Routine
        (T,
         Switch_Branch_Restores_Working_Tree_And_Index'Access,
         "Branch: switch restores working tree and index");

      Register_Routine
        (T,
         Update_Current_Branch_Advances_Linear_History'Access,
         "Branch: update advances linear history");

      Register_Routine
        (T,
         Update_Current_Branch_Rejects_Diverged_History'Access,
         "Branch: update rejects diverged history");

      Register_Routine
        (T,
         Switch_Branch_Rejects_Modified_Working_Tree'Access,
         "Branch: switch rejects modified working tree");

      Register_Routine
        (T,
         Switch_Branch_Rejects_Staged_Changes'Access,
         "Branch: switch rejects staged changes");

      Register_Routine
        (T,
         Switch_Branch_Rejects_Untracked_File'Access,
         "Branch: switch rejects untracked file");

      Register_Routine
        (T,
         Integrate_Branch_Creates_Merge_Commit'Access,
         "Branch: integrate creates non-conflicting merge commit");

      Register_Routine
        (T,
         Integrate_Branch_Writes_Conflict_Markers'Access,
         "Branch: integrate writes conflict markers");

      Register_Routine
        (T,
         Conflicted_Integrate_Applies_Clean_Target_Delete'Access,
         "Branch: conflicted integrate applies clean target delete");

      Register_Routine
        (T,
         Abort_Integration_Restores_Current_Parent'Access,
         "Branch: abort integration restores current parent");

      Register_Routine
        (T,
         Git_Created_Conflict_Can_Be_Aborted'Access,
         "Branch: abort handles Git-created conflicted merge");

      Register_Routine
        (T,
         Git_Created_Conflict_Can_Be_Finalized'Access,
         "Branch: finalize handles Git-created conflicted merge");

      Register_Routine
        (T,
         Abort_Integration_Removes_Target_Only_Additions'Access,
         "Branch: abort integration removes target-only additions");

      Register_Routine
        (T,
         Merge_Whitespace_Option_Resolves_Equivalent_Text'Access,
         "Branch: merge ignores selected whitespace conflicts");

      Register_Routine
        (T,
         Merge_Config_Renormalize_Resolves_Line_Ending_Text'Access,
         "Branch: merge honors merge.renormalize config");

      Register_Routine
        (T,
         Merge_No_Renormalize_Overrides_Config'Access,
         "Branch: merge no-renormalize overrides config");

      Register_Routine
        (T,
         Merge_Attributes_Union_Resolves_Content_Conflict'Access,
         "Branch: merge honors union merge attributes");

      Register_Routine
        (T,
         Merge_Attributes_Nested_Text_Resets_Parent_Rule'Access,
         "Branch: nested merge attributes reset parent rules");

      Register_Routine
        (T,
         Merge_Attributes_Unset_Resets_Parent_Rule'Access,
         "Branch: unset merge attribute resets parent rule");

      Register_Routine
        (T,
         Merge_Info_Attributes_Override_Worktree_Rules'Access,
         "Branch: info merge attributes override worktree rules");

      Register_Routine
        (T,
         Merge_Conflict_Style_Diff3_Writes_Base_Markers'Access,
         "Branch: merge writes diff3 conflict markers");

      Register_Routine
        (T,
         Merge_Config_Conflict_Style_Normalizes_Value'Access,
         "Branch: merge normalizes conflict style config");

      Register_Routine
        (T,
         Merge_Config_FF_False_Creates_Merge_Commit'Access,
         "Branch: merge honors merge.ff false config");

      Register_Routine
        (T,
         Merge_FF_Option_Overrides_Config_False'Access,
         "Branch: merge ff option overrides merge.ff false");

      Register_Routine
        (T,
         Merge_Branch_Merge_Options_Config_Applies_Defaults'Access,
         "Branch: merge honors branch mergeOptions defaults");

      Register_Routine
        (T,
         Merge_Default_Message_Uses_Branch_Label'Access,
         "Branch: merge default message labels branches");

      Register_Routine
        (T,
         Merge_Message_Log_Signoff_And_Cleanup'Access,
         "Branch: merge message log signoff and cleanup");

      Register_Routine
        (T,
         Merge_Edit_Message_Uses_Configured_Editor'Access,
         "Branch: merge edit message uses configured editor");

      Register_Routine
        (T,
         Merge_Autostash_Restores_Dirty_Worktree'Access,
         "Branch: merge autostash restores dirty worktree");

      Register_Routine
        (T,
         Merge_Autostash_Applies_To_No_Commit_Result'Access,
         "Branch: merge autostash applies to no-commit result");

      Register_Routine
        (T,
         Merge_GPG_Sign_Writes_GPGSig_Header'Access,
         "Branch: merge gpg-sign writes gpgsig header");

      Register_Routine
        (T,
         Merge_External_Driver_Resolves_Content_Conflict'Access,
         "Branch: merge runs configured external driver");

      Register_Routine
        (T,
         Merge_External_Driver_Fatal_Status_Raises'Access,
         "Branch: merge treats fatal external driver status as failure");

      Register_Routine
        (T,
         Merge_External_Driver_Missing_Result_Raises'Access,
         "Branch: merge treats missing external driver result as failure");

      Register_Routine
        (T,
         Merge_External_Driver_Recursive_Union_For_Virtual_Base'Access,
         "Branch: merge honors external driver recursive union for virtual base");

      Register_Routine
        (T,
         Merge_External_Driver_Recursive_Delegates_To_Command'Access,
         "Branch: merge delegates recursive driver to configured command");

      Register_Routine
        (T,
         Merge_Materializes_Text_Conflict_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes conflicted recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Binary_Conflict_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes binary recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Delete_Modify_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes delete-modify recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Directory_File_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes directory-file recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Rename_Delete_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes rename-delete recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Rename_Rename_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes rename-rename recursive virtual base");

      Register_Routine
        (T,
         Merge_Materializes_Directory_Rename_For_Recursive_Virtual_Base'Access,
         "Branch: merge materializes directory-rename recursive virtual base");

      Register_Routine
        (T,
         Merge_Pre_Merge_Commit_Hook_Blocks_Auto_Commit'Access,
         "Branch: merge runs pre-merge-commit hook before commit");

      Register_Routine
        (T,
         Merge_Verify_Signatures_Preflight_No_Mutation'Access,
         "Branch: merge verify-signatures rejects before mutation");

      Register_Routine
        (T,
         Merge_Non_Overlapping_Text_Edits_Auto_Merge'Access,
         "Branch: merge auto-merges non-overlapping text edits");

      Register_Routine
        (T,
         Merge_Multiple_Line_Text_Edits_Auto_Merge'Access,
         "Branch: merge auto-merges multiple line edits");

      Register_Routine
        (T,
         Merge_Default_Strategy_Merges_Multi_Hunk_Insertions'Access,
         "Branch: merge default strategy combines independent insertion hunks");

      Register_Routine
        (T,
         Merge_Diff_Algorithm_Minimal_Merges_Multi_Hunk_Insertions'Access,
         "Branch: merge diff algorithm combines independent insertion hunks");

      Register_Routine
        (T,
         Merge_Resolve_Strategy_Disables_Rename_Detection'Access,
         "Branch: merge resolve strategy disables rename detection");

      Register_Routine
        (T,
         Merge_Rename_Limit_Config_Disables_Similarity_Rename'Access,
         "Branch: merge renameLimit config caps similarity rename scans");

      Register_Routine
        (T,
         Merge_Subtree_Option_Rewrites_Target_Paths'Access,
         "Branch: merge subtree option rewrites target paths");

      Register_Routine
        (T,
         Merge_Conflict_Style_ZDiff3_Trims_Common_Context'Access,
         "Branch: merge writes compact zdiff3 conflict markers");

      Register_Routine
        (T,
         Merge_Rerere_Reuses_Recorded_Resolution'Access,
         "Branch: merge reuses rerere resolution");

      Register_Routine
        (T,
         Merge_Rerere_Reuses_Resolution_With_Sides_Swapped'Access,
         "Branch: merge rerere reuses resolution with sides swapped");

      Register_Routine
        (T,
         Merge_Rerere_Autoupdate_Records_Preimage'Access,
         "Branch: merge rerere.autoupdate records preimage");

      Register_Routine
        (T,
         Merge_Rename_Modify_Moves_Modified_Content'Access,
         "Branch: merge handles rename plus content edit");

      Register_Routine
        (T,
         Merge_Directory_Rename_Moves_Added_File'Access,
         "Branch: merge applies simple directory rename to additions");

      Register_Routine
        (T,
         Merge_Case_Only_Rename_Preflight_Allows_Update'Access,
         "Branch: merge allows case-only rename preflight");

      Register_Routine
        (T,
         Merge_Directory_Rename_Case_Collision_Preflights'Access,
         "Branch: merge preflights directory rename case collisions");

      Register_Routine
        (T,
         Merge_Directory_Rename_Config_Disables_Addition_Move'Access,
         "Branch: merge honors directoryRenames=false");

      Register_Routine
        (T,
         Merge_Directory_Rename_Config_Conflict_Pauses'Access,
         "Branch: merge honors directoryRenames=conflict");

      Register_Routine
        (T,
         Merge_Directory_Rename_Ambiguous_Split_Pauses'Access,
         "Branch: merge pauses ambiguous split directory rename");

      Register_Routine
        (T,
         Merge_Copy_Detection_Uses_Source_As_Add_Add_Base'Access,
         "Branch: merge uses copy detection as add/add base");

      Register_Routine
        (T,
         Merge_Ignore_CR_At_EOL_Treats_CRLF_As_Equivalent'Access,
         "Branch: merge supports ignore-cr-at-eol");

      Register_Routine
        (T,
         Merge_Verify_Signatures_Config_Default_No_Mutation'Access,
         "Branch: merge.verifySignatures defaults signature checks");

      Register_Routine
        (T,
         Merge_Rename_Rename_Same_Path_Auto_Merges_Content'Access,
         "Branch: merge handles same-path rename/rename edits");

      Register_Routine
        (T,
         Merge_Rename_Rename_Same_Path_Preserves_Mode'Access,
         "Branch: merge same-path rename/rename preserves mode-only changes");

      Register_Routine
        (T,
         Merge_Rename_Add_Collision_Writes_Unmerged_Stages'Access,
         "Branch: merge writes stages for rename/add collisions");

      Register_Routine
        (T,
         Merge_Similarity_Rename_Modify_Auto_Merges_Content'Access,
         "Branch: merge detects similar rename plus content edit");

      Register_Routine
        (T,
         Merge_Find_Renames_Overrides_Config_False'Access,
         "Branch: merge find-renames overrides disabled config");

      Register_Routine
        (T,
         Merge_No_Renames_Overrides_Config_True'Access,
         "Branch: merge no-renames overrides enabled config");

      Register_Routine
        (T,
         Merge_Gitlink_Addition_Does_Not_Read_Submodule_Object'Access,
         "Branch: merge handles gitlink additions");

      Register_Routine
        (T,
         Merge_Materializes_Target_Symlink_Addition'Access,
         "Branch: merge materializes symlink additions");

      Register_Routine
        (T,
         Merge_Materializes_Disabled_Symlink_As_File'Access,
         "Branch: merge materializes disabled symlink as plain file");

      Register_Routine
        (T,
         Merge_Gitlink_Fast_Forwards_Local_Submodule_Update'Access,
         "Branch: merge fast-forwards local submodule gitlinks");

      Register_Routine
        (T,
         Merge_Gitlink_Dirty_Submodule_Blocks_Update'Access,
         "Branch: merge rejects dirty tracked/untracked submodule gitlink update");

      Register_Routine
        (T,
         History_Merge_Bases_Returns_Minimal_Common_Ancestors'Access,
         "History: merge bases returns criss-cross bases");

      Register_Routine
        (T,
         Merge_Uses_Recursive_Virtual_Base_For_Criss_Cross'Access,
         "Branch: merge uses recursive criss-cross base");

      Register_Routine
        (T,
         Merge_Resolve_Strategy_Merges_Criss_Cross_Bases'Access,
         "Branch: merge resolve merges criss-cross bases");

      Register_Routine
        (T,
         Merge_Multiple_Conflict_Writes_All_Merge_Heads'Access,
         "Branch: merge octopus conflict records all heads");

      Register_Routine
        (T,
         Merge_Octopus_Strategy_Rejects_Single_Target'Access,
         "Branch: merge octopus strategy rejects single target");

      Register_Routine
        (T,
         Merge_Multiple_Resolve_Strategy_Rejects_Octopus'Access,
         "Branch: merge resolve strategy rejects octopus merge");

      Register_Routine
        (T,
         Merge_Multiple_Creates_Octopus_Commit'Access,
         "Branch: merge multiple creates octopus commit");

      Register_Routine
        (T,
         Merge_Multiple_Squash_Writes_Squash_State'Access,
         "Branch: merge multiple squash writes squash state");

      Register_Routine
        (T,
         Merge_Multiple_No_Commit_Writes_Multi_Head_State'Access,
         "Branch: merge multiple no-commit writes multi-head state");

      Register_Routine
        (T,
         Merge_Directory_File_Conflict_Writes_Unmerged_Stages'Access,
         "Branch: merge records directory/file conflict stages");

      Register_Routine
        (T,
         Merge_Combines_Mode_And_Content_Changes'Access,
         "Branch: merge combines mode and content changes");

      Register_Routine
        (T,
         Merge_Auto_Text_Merge_Preserves_Target_Mode'Access,
         "Branch: merge auto text merge preserves target mode change");

      Register_Routine
        (T,
         Merge_Identical_Content_Preserves_Changed_Mode'Access,
         "Branch: merge identical content preserves changed mode");

      Register_Routine
        (T,
         Merge_LFS_Pointer_Is_Ordinary_Blob'Access,
         "Branch: merge smudges available LFS pointer media");
      Register_Routine
        (T,
         Merge_LFS_Pointer_Fetches_Local_LFS_Url_Media'Access,
         "Branch: merge fetches missing LFS media from local lfs url");
      Register_Routine
        (T,
         Merge_LFS_Pointer_Fetches_HTTP_Batch_Media'Access,
         "Branch: merge fetches missing LFS media through HTTP batch");

      Register_Routine
        (T,
         Switch_Branch_Appends_HEAD_Reflog'Access,
         "Branch: switch appends HEAD reflog");

      Register_Routine
        (T,
         Switch_Branch_Head_Lock_Preserves_Current_State'Access,
         "Branch: switch HEAD lock preserves current state");

      Register_Routine
        (T,
         Switch_Branch_Reflog_Lock_Preserves_Current_State'Access,
         "Branch: switch HEAD reflog lock preserves current state");

      Register_Routine
        (T,
         Update_Current_Branch_Appends_Reflogs'Access,
         "Branch: update appends reflogs");

      Register_Routine
        (T,
         Integrate_Branch_Appends_Reflogs'Access,
         "Branch: integrate appends reflogs");

      Register_Routine
        (T,
         Finalize_Integration_Appends_Reflogs'Access,
         "Branch: finalize integration appends reflogs");

      Register_Routine
        (T,
         Rename_Branch_Moves_Ref_And_Reflog'Access,
         "Branch: rename branch");
      Register_Routine
        (T,
         Rename_Branch_From_Linked_Worktree_Uses_Common_Reflog'Access,
         "Branch: linked rename uses common branch reflog");
      Register_Routine
        (T,
         Rename_Branch_Rejects_Non_File_Source_Reflog'Access,
         "Branch: rename rejects non-file source reflog");

      Register_Routine
        (T,
         Rename_Branch_Rolls_Back_On_Packed_Delete_Failure'Access,
         "Branch: rename rolls back packed delete failure");

      Register_Routine
        (T,
         Rename_Current_Branch_Updates_HEAD'Access,
         "Branch: rename current branch updates HEAD");

      Register_Routine
        (T,
         Delete_Merged_Branch_Removes_Ref'Access,
         "Branch: delete merged branch");
      Register_Routine
        (T,
         Delete_Branch_Rejects_Non_File_Reflog'Access,
         "Branch: delete rejects non-file reflog");
      Register_Routine
        (T,
         Delete_Branch_Rejects_Restore_Lock_Before_Delete'Access,
         "Branch: delete rejects restore lock before delete");

      Register_Routine
        (T,
         Delete_Branch_Rolls_Back_On_Packed_Delete_Failure'Access,
         "Branch: delete rolls back packed delete failure");

      Register_Routine
        (T,
         Delete_Rejects_Current_Branch'Access,
         "Branch: delete rejects current branch");

      Register_Routine
        (T,
         Delete_Rejects_Unmerged_Unless_Forced'Access,
         "Branch: delete rejects unmerged branch unless forced");

      Register_Routine
        (T,
         Rename_One_Arg_Rejects_Detached_HEAD'Access,
         "Branch: one-arg current rename rejects detached HEAD");

   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Branch");
   end Name;

end Version.Branch.Tests;
