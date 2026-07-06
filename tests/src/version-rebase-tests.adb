with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Checkout;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Merge_State;
with Version.Objects;
with Version.Rebase_State;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Test_Support;
with Version.Write;

package body Version.Rebase.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   A_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
   B_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
   C_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("cccccccccccccccccccccccccccccccccccccccc");
   D_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("dddddddddddddddddddddddddddddddddddddddd");

   procedure Configure_User (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_User;

   procedure Write_File (Root, Name, Content : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Name), Content);
   end Write_File;

   procedure Write_Hook
     (Root    : String;
      Name    : String;
      Content : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join (Root, ".git"), "hooks"), Name),
         "#!/bin/sh" & Character'Val (10) & Content);
      Version.Git_Fixtures.Run (Root, "chmod +x .git/hooks/" & Name);
   end Write_Hook;

   function File_Text (Root, Name : String) return String is
   begin
      return Version.Test_Support.Read_Text_File
        (Version.Test_Support.Join (Root, Name));
   end File_Text;

   function Rerere_Cache_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join
        (Version.Test_Support.Join (Root, ".git"), "rr-cache");
   end Rerere_Cache_Path;

   function Rerere_Sentinel_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join
        (Version.Test_Support.Join
           (Rerere_Cache_Path (Root), "0123456789abcdef"), "preimage");
   end Rerere_Sentinel_Path;

   procedure Seed_Rerere_Sentinel
     (Root    : String;
      Content : String) is
   begin
      Ada.Directories.Create_Path
        (Version.Test_Support.Join
           (Rerere_Cache_Path (Root), "0123456789abcdef"));
      Version.Files.Write_Binary_File (Rerere_Sentinel_Path (Root), Content);
   end Seed_Rerere_Sentinel;

   procedure Rebase_State_Write_Read_Clear
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Rebase_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      Commits.Append (C_Id);
      Commits.Append (D_Id);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "rebase state must not exist initially");

         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => "refs/heads/feature",
            Original_Head       => A_Id,
            Target_Head         => B_Id,
            Current_Replay_Head => B_Id,
            Next_Index          => 1,
            Commits             => Commits,
            Paused              => True,
            Current_Commit      => To_String (D_Id));

         declare
            State : constant Version.Rebase_State.Rebase_State :=
              Version.Rebase_State.Read_State (Repo);
         begin
            Assert (Version.Rebase_State.State_Exists (Repo),
                    "rebase state must exist after write");
            Assert (Version.Rebase_State.Branch_Ref (State) = "refs/heads/feature",
                    "branch ref mismatch");
            Assert (Version.Rebase_State.Original_Head (State) = A_Id,
                    "original head mismatch");
            Assert (Version.Rebase_State.Target_Head (State) = B_Id,
                    "target head mismatch");
            Assert (Version.Rebase_State.Current_Replay_Head (State) = B_Id,
                    "current replay head mismatch");
            Assert (Version.Rebase_State.Next_Index (State) = 1,
                    "next index mismatch");
            Assert (Version.Rebase_State.Total_Commits (State) = 2,
                    "total commits mismatch");
            Assert (Version.Rebase_State.Paused (State),
                    "paused flag mismatch");
            Assert (Version.Rebase_State.Current_Commit (State) = D_Id,
                    "current commit mismatch");
         end;

         Version.Rebase_State.Clear_State (Repo);
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "rebase state must not exist after clear");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_State_Write_Read_Clear;

   procedure Rebase_State_Rejects_Malformed_Progress
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Rebase_State.Commit_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      Commits.Append (C_Id);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         begin
            Version.Rebase_State.Write_State
              (Repo                => Repo,
               Branch_Ref          => "refs/heads/feature",
               Original_Head       => A_Id,
               Target_Head         => B_Id,
               Current_Replay_Head => B_Id,
               Next_Index          => 2,
               Commits             => Commits);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "invalid next_index must be rejected");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_State_Rejects_Malformed_Progress;

   procedure Rebase_Linear_Clean_Replay
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "common.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add common.txt");
      Version.Write.Save ("base");

      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature one");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Before_Feature : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Rebase.Start ("main");

         declare
            After_Feature : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Assert (Before_Feature /= After_Feature,
                    "clean rebase must create replayed commit");
            Assert (not Version.Rebase_State.State_Exists (Repo),
                    "clean rebase must clear state");
         end;
      end;

      Assert (File_Text (Root, "main.txt") = "main",
              "rebased working tree must include target branch change");
      Assert (File_Text (Root, "feature.txt") = "feature one",
              "rebased working tree must include replayed branch change");

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse feature^)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%s feature)"" = ""feature one""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Linear_Clean_Replay;

   procedure Rebase_Conflict_Pauses_And_Abort_Restores
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Original_Feature : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         begin
            Version.Rebase.Start ("main");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "conflicting rebase must pause with Data_Error");
         Assert (Version.Rebase_State.State_Exists (Repo),
                 "conflicting rebase must persist rebase state");

         declare
            State : constant Version.Rebase_State.Rebase_State :=
              Version.Rebase_State.Read_State (Repo);
         begin
            Assert (Version.Rebase_State.Paused (State),
                    "conflicting rebase state must be paused");
         end;

         Assert
           (Ada.Strings.Fixed.Index (File_Text (Root, "conflict.txt"), "<<<<<<<") /= 0,
            "conflicting rebase must leave conflict markers");

         Version.Rebase.Abort_Rebase;
         Assert (Version.Refs.Current_Commit_Id (Repo) = Original_Feature,
                 "abort must restore original branch head");
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "abort must clear rebase state");
      end;

      Assert (File_Text (Root, "conflict.txt") = "feature",
              "abort must restore original working tree content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Conflict_Pauses_And_Abort_Restores;

   procedure Rebase_Conflict_Continue_Completes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");

      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "conflicting rebase must pause before continue");
      Write_Hook
        (Root,
         "post-commit",
         "echo rebase continue > rebase-post-commit.txt" & Character'Val (10)
         & "exit 0" & Character'Val (10));
      Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));
      Version.Rebase.Continue_Rebase;
      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "rebase-post-commit.txt")),
         "rebase continue must run post-commit hook");
      Ada.Directories.Delete_File
        (Version.Test_Support.Join (Root, "rebase-post-commit.txt"));

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "continue must clear completed rebase state");
      end;

      Assert (File_Text (Root, "conflict.txt") = "resolved",
              "continue must keep resolved working tree content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse feature^)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%s feature)"" = ""feature change""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Conflict_Continue_Completes;

   procedure Rebase_Conflict_Does_Not_Create_Or_Rewrite_Rerere
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sentinel : constant String :=
        "disabled rerere sentinel" & Character'Val (10);
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");

      Seed_Rerere_Sentinel (Root, Sentinel);

      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "conflicting rebase must pause");
      Assert
        (Version.Files.Read_Binary_File (Rerere_Sentinel_Path (Root))
         = Sentinel,
         "rebase conflict must preserve preexisting rerere metadata");
      Assert
        (Ada.Directories.Exists (Rerere_Cache_Path (Root)),
         "rebase conflict must not remove preexisting rr-cache");

      Version.Rebase.Abort_Rebase;
      Assert
        (Version.Files.Read_Binary_File (Rerere_Sentinel_Path (Root))
         = Sentinel,
         "rebase abort must preserve preexisting rerere metadata");

      Ada.Directories.Delete_Tree (Rerere_Cache_Path (Root));
      Raised := False;
      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "second conflicting rebase must pause");
      Assert
        (not Ada.Directories.Exists (Rerere_Cache_Path (Root)),
         "rebase conflict must not create rerere metadata");
      Version.Rebase.Abort_Rebase;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Conflict_Does_Not_Create_Or_Rewrite_Rerere;

   procedure Rebase_Rerere_Records_Postimage_On_Continue
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");
      declare
         Original_Feature : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "git config rerere.enabled true");

         begin
            Version.Rebase.Start ("main");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "rerere-enabled rebase must pause on first conflict");
         Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/preimage");
         Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));
         Version.Rebase.Continue_Rebase;
         Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/postimage");

         Version.Git_Fixtures.Run (Root, "git reset --hard " & Original_Feature);
         Raised := False;
         begin
            Version.Rebase.Start ("main");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
         Assert
           (not Raised,
            "rerere-enabled rebase must reuse recorded resolution");
         Assert
           (File_Text (Root, "conflict.txt") = "resolved",
            "rebase rerere reuse must materialize recorded postimage");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Rerere_Records_Postimage_On_Continue;

   procedure Rebase_Continue_Post_Commit_Failure_Preserves_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir  : constant String := Ada.Directories.Current_Directory;
      Paused   : Boolean := False;
      Reported : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");

      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Paused := True;
      end;
      Assert (Paused, "conflicting rebase must pause before continue");

      Write_Hook
        (Root,
         "post-commit",
         "echo failing rebase post > rebase-post-commit-failed.txt" & Character'Val (10)
         & "exit 1" & Character'Val (10));
      Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));

      begin
         Version.Rebase.Continue_Rebase;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Reported := True;
      end;

      Assert (Reported, "failing rebase post-commit must be reported");
      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "rebase-post-commit-failed.txt")),
         "failing rebase post-commit must have run after completed commit");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "post-commit failure must not restore completed rebase state");
      end;

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse feature^)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%s feature)"" = ""feature change""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Continue_Post_Commit_Failure_Preserves_Commit;

   procedure Rebase_Continue_Rejects_Untracked_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "conflict.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "conflict.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Write.Save ("feature change");

      begin
         Version.Rebase.Start ("main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));
      Write_File (Root, "untracked.txt", "must not be staged" & Character'Val (10));

      begin
         Version.Rebase.Continue_Rebase;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised,
              "continue must reject unrelated untracked files");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Rebase_State.Clear_State (Repo);
         Version.Merge_State.Clear_State (Repo);
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Rebase_State.Clear_State (Repo);
            Version.Merge_State.Clear_State (Repo);
         exception
            when others =>
               null;
         end;
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Continue_Rejects_Untracked_File;

   procedure Rebase_Rejects_Unclean_Working_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "dirty.txt", "dirty" & Character'Val (10));

      begin
         Version.Rebase.Start ("HEAD");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "rebase must reject unclean working tree");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Rejects_Unclean_Working_Tree;

   procedure Rebase_Rejects_Detached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Checkout.Checkout_Commit (Head);
         begin
            Version.Rebase.Start ("HEAD");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "rebase must reject detached HEAD");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Rejects_Detached_HEAD;

   procedure Rebase_Preserves_Two_Commit_Order_And_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Before_Feature : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "one.txt", "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add one.txt");
      Version.Write.Save ("feature first");
      Write_File (Root, "two.txt", "two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add two.txt");
      Version.Write.Save ("feature second");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Before_Feature :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Version.Rebase.Start ("main");
      end;

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log --format=%s -n 1 feature)"" = ""feature second""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log --format=%s -n 1 feature^)"" = ""feature first""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse feature^^)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run
        (Root,
         "git cat-file -e " & To_String (Before_Feature) & "^{commit}");

      declare
         Reflog_Text : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Reflog.Path
                (Version.Repository.Open, "refs/heads/feature"));
      begin
         Assert
           (Ada.Strings.Fixed.Index (Reflog_Text, To_String (Before_Feature)) /= 0,
            "branch reflog must retain original feature tip");
         Assert
           (Ada.Strings.Fixed.Index (Reflog_Text, "rebase: onto") /= 0,
            "branch reflog must record rebase completion");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Preserves_Two_Commit_Order_And_Reflog;

   procedure Rebase_Preserves_Author_And_Message
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");

      Version.Branch.Switch_Branch ("feature");
      Version.Git_Fixtures.Run
        (Root, "git config user.name 'Original Author'");
      Version.Git_Fixtures.Run
        (Root, "git config user.email original@example.com");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save
        ("subject" & Character'Val (10) & Character'Val (10) & "body line");

      Version.Git_Fixtures.Run
        (Root, "git config user.name 'Rebase Committer'");
      Version.Git_Fixtures.Run
        (Root, "git config user.email committer@example.com");
      Version.Rebase.Start ("main");

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%an feature)"" = ""Original Author""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%ae feature)"" = ""original@example.com""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%cn feature)"" = ""Rebase Committer""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -1 --format=%ce feature)"" = ""committer@example.com""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s feature)"" = ""subject""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%b feature)"" = ""body line""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Preserves_Author_And_Message;

   procedure Rebase_Rejects_Root_Replay_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root_Commit : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Root_Commit :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      end;

      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Before_Head : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         begin
            declare
               Result : constant Version.Rebase.Replay_Result :=
                 Version.Rebase.Replay_Commit
                   (Repo          => Repo,
                    Replay_Parent => Version.Objects.To_Object_Id (Before_Head),
                    Commit_Id     => Root_Commit);
               pragma Unreferenced (Result);
            begin
               null;
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Rebase.Root_Rebase_Not_Supported,
                  "root replay diagnostic must remain stable");
         end;

         Assert (Raised, "rebase must reject replaying root commits");
         Assert
           (Version.Refs.Current_Commit_Id (Repo) = Before_Head,
            "root replay rejection must not move branch head");
         Assert
           (not Version.Rebase_State.State_Exists (Repo),
            "root replay rejection must not leave rebase state");
         Assert
           (not Version.Merge_State.State_Exists (Repo),
            "root replay rejection must not leave merge state");
      end;

      Assert
        (File_Text (Root, "base.txt") = "base",
         "root replay rejection must preserve existing file content");
      Assert
        (File_Text (Root, "main.txt") = "main",
         "root replay rejection must preserve working tree content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Rejects_Root_Replay_Without_Mutation;

   procedure Rebase_Rejects_Merge_Commit_Replay
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main one");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature one");
      Version.Git_Fixtures.Run (Root, "git merge main --no-ff -m 'merge main'");

      Version.Branch.Switch_Branch ("main");
      Write_File (Root, "main2.txt", "main two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main2.txt");
      Version.Write.Save ("main two");
      Version.Branch.Switch_Branch ("feature");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Before_Feature : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         begin
            Version.Rebase.Start ("main");
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Rebase.Merge_Commit_Rebase_Not_Supported,
                  "merge rebase diagnostic must remain stable");
         end;

         Assert (Raised, "rebase must reject replaying merge commits");
         Assert
           (Version.Refs.Current_Commit_Id (Repo) = Before_Feature,
            "merge commit rejection must not move branch head");
         Assert
           (not Version.Rebase_State.State_Exists (Repo),
            "merge commit rejection must not leave rebase state");
         Assert
           (not Version.Merge_State.State_Exists (Repo),
            "merge commit rejection must not leave merge state");
      end;

      Assert
        (File_Text (Root, "base.txt") = "base",
         "merge commit rejection must preserve base file content");
      Assert
        (File_Text (Root, "feature.txt") = "feature",
         "merge commit rejection must preserve feature file content");
      Assert
        (File_Text (Root, "main.txt") = "main",
         "merge commit rejection must preserve merged file content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Rejects_Merge_Commit_Replay;

   procedure Rebase_State_Blocks_Branch_Switch_And_Checkout
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Switch_Raised   : Boolean := False;
      Checkout_Raised : Boolean := False;
      Commits : Version.Rebase_State.Commit_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Branch_Ref : constant String :=
           "refs/heads/" & Version.Refs.Current_Branch_Name (Repo);
      begin
         Version.Branch.Create_Branch ("other");
         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Branch_Ref,
            Original_Head       => Head,
            Target_Head         => Head,
            Current_Replay_Head => Head,
            Next_Index          => 0,
            Commits             => Commits);

         begin
            Version.Branch.Switch_Branch ("other");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Switch_Raised := True;
         end;

         begin
            Version.Checkout.Checkout_Commit (Head);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Checkout_Raised := True;
         end;

         Version.Rebase_State.Clear_State (Repo);
      end;

      Assert (Switch_Raised,
              "branch switch must reject an in-progress rebase state");
      Assert (Checkout_Raised,
              "detached checkout must reject an in-progress rebase state");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_State_Blocks_Branch_Switch_And_Checkout;

   procedure Rebase_Continue_Rejects_Missing_Merge_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
      Commits : Version.Rebase_State.Commit_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Branch_Ref : constant String :=
           "refs/heads/" & Version.Refs.Current_Branch_Name (Repo);
      begin
         Commits.Append (Head);
         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Branch_Ref,
            Original_Head       => Head,
            Target_Head         => Head,
            Current_Replay_Head => Head,
            Next_Index          => 0,
            Commits             => Commits,
            Paused              => True,
            Current_Commit      => To_String (Head));

         begin
            Version.Rebase.Continue_Rebase;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Version.Rebase_State.Clear_State (Repo);
      end;

      Assert (Raised,
              "continue must reject paused rebase without merge state");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Continue_Rejects_Missing_Merge_State;

   procedure Rebase_Interactive_Drops_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      for C of String'("ABC") loop
         Write_File (Root, C & ".txt", C & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add " & C & ".txt");
         Version.Write.Save ("add " & C);
      end loop;

      --  A sequence editor that deletes the "add B" pick line.
      Ada.Environment_Variables.Set
        ("GIT_SEQUENCE_EDITOR", "sed -i '/add B/d'");
      Version.Rebase.Start_Interactive ("HEAD~3");
      Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert (not Version.Rebase_State.State_Exists (Repo),
                 "interactive rebase must finish and clear state");
      end;
      Version.Git_Fixtures.Run (Root, "test ! -e B.txt");
      Version.Git_Fixtures.Run (Root, "test -e A.txt");
      Version.Git_Fixtures.Run (Root, "test -e C.txt");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --count HEAD)"" = ""3""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Interactive_Drops_Commit;

   procedure Rebase_Interactive_Squashes_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      for C of String'("ABC") loop
         Write_File (Root, C & ".txt", C & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add " & C & ".txt");
         Version.Write.Save ("add " & C);
      end loop;

      --  Squash "add C" into "add B".
      Ada.Environment_Variables.Set
        ("GIT_SEQUENCE_EDITOR", "sed -i '/add C/s/^pick/squash/'");
      Version.Rebase.Start_Interactive ("HEAD~3");
      Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");

      --  All three file changes survive, but B and C are now one commit.
      Version.Git_Fixtures.Run (Root, "test -e A.txt");
      Version.Git_Fixtures.Run (Root, "test -e B.txt");
      Version.Git_Fixtures.Run (Root, "test -e C.txt");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --count HEAD)"" = ""3""");
      --  The squashed commit message keeps both subjects.
      Version.Git_Fixtures.Run
        (Root, "git log -1 --format=%B | grep -q 'add B'");
      Version.Git_Fixtures.Run
        (Root, "git log -1 --format=%B | grep -q 'add C'");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Interactive_Squashes_Commit;

   procedure Rebase_Root_Onto_Newbase
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "nb.txt", "NB" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add nb.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m newbase");

      --  A feature branch with its own root commit (unrelated history).
      Version.Git_Fixtures.Run (Root, "git checkout -q --orphan feature");
      Version.Git_Fixtures.Run (Root, "git rm -q -rf .");
      Write_File (Root, "f1.txt", "f1" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f1.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m froot");
      Write_File (Root, "f2.txt", "f2" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f2.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m fsecond");

      Version.Rebase.Start_Root ("main");

      --  Feature now sits on top of newbase: three commits, all files present.
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --count HEAD)"" = ""3""");
      Version.Git_Fixtures.Run (Root, "test -e nb.txt");
      Version.Git_Fixtures.Run (Root, "test -e f1.txt");
      Version.Git_Fixtures.Run (Root, "test -e f2.txt");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git rev-parse HEAD~2)"" = ""$(git rev-parse main)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Root_Onto_Newbase;

   procedure Rebase_Merges_Preserves_Topology
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("c1");
      Write_File (Root, "u.txt", "U" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add u.txt");
      Version.Write.Save ("U");  --  upstream tip on main

      Version.Git_Fixtures.Run (Root, "git checkout -q -b feature HEAD~1");
      Write_File (Root, "f1.txt", "f1" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f1.txt");
      Version.Write.Save ("f1");
      Version.Git_Fixtures.Run (Root, "git checkout -q -b side");
      Write_File (Root, "s1.txt", "s1" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add s1.txt");
      Version.Write.Save ("s1");
      Version.Git_Fixtures.Run (Root, "git checkout -q feature");
      Write_File (Root, "f2.txt", "f2" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f2.txt");
      Version.Write.Save ("f2");
      Version.Git_Fixtures.Run (Root, "git merge -q --no-ff side -m ""merge side""");

      Version.Rebase.Start_Rebase_Merges ("main");

      --  The internal merge is recreated (HEAD has two parents) and the branch
      --  now sits on top of main with every change present.
      Version.Git_Fixtures.Run
        (Root, "test ""$(git rev-list --parents -1 HEAD | wc -w)"" = ""3""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git merge-base HEAD main)"" = ""$(git rev-parse main)""");
      Version.Git_Fixtures.Run (Root, "test -e f1.txt");
      Version.Git_Fixtures.Run (Root, "test -e f2.txt");
      Version.Git_Fixtures.Run (Root, "test -e s1.txt");
      Version.Git_Fixtures.Run (Root, "test -e u.txt");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Merges_Preserves_Topology;

   procedure Rebase_Interactive_Rewords_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "f.txt", "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("A base");
      Write_File (Root, "f.txt", "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("B middle");
      Write_File (Root, "f.txt", "c" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("C tip");

      --  The reword editor overwrites the message file with this content.
      --  Kept under .git so it does not dirty the working tree before rebase.
      Write_File (Root, ".git/newmsg.txt", "REWORDED B" & LF);

      Ada.Environment_Variables.Set
        ("GIT_SEQUENCE_EDITOR", "sed -i '/B middle/s/^pick/reword/'");
      Ada.Environment_Variables.Set
        ("GIT_EDITOR",
         "cp " & Version.Test_Support.Join (Root, ".git/newmsg.txt"));

      Version.Rebase.Start_Interactive ("HEAD~2");

      Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
      Ada.Environment_Variables.Clear ("GIT_EDITOR");

      Assert (not Version.Rebase_State.State_Exists (Version.Repository.Open),
              "reword rebase must clear state");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD~2)"" = ""A base""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD~1)"" = ""REWORDED B""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD)"" = ""C tip""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
         Ada.Environment_Variables.Clear ("GIT_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Interactive_Rewords_Commit;

   procedure Rebase_Interactive_Reword_Empty_Message_Aborts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "f.txt", "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("A base");
      Write_File (Root, "f.txt", "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("B tip");

      --  A message that cleans to empty (comment + blank only) must abort,
      --  matching git's "aborting due to empty commit message". Kept under .git
      --  so the working tree stays clean (the abort must be from the message,
      --  not a dirty tree).
      Write_File (Root, ".git/emptymsg.txt", "# only a comment" & LF & LF);

      Ada.Environment_Variables.Set
        ("GIT_SEQUENCE_EDITOR", "sed -i '/B tip/s/^pick/reword/'");
      Ada.Environment_Variables.Set
        ("GIT_EDITOR",
         "cp " & Version.Test_Support.Join (Root, ".git/emptymsg.txt"));

      begin
         Version.Rebase.Start_Interactive ("HEAD~1");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
      Ada.Environment_Variables.Clear ("GIT_EDITOR");

      Assert (Raised, "empty reworded message must abort the rebase");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
         Ada.Environment_Variables.Clear ("GIT_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Interactive_Reword_Empty_Message_Aborts;

   procedure Rebase_Interactive_Edit_Stops_And_Continues
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "f.txt", "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("A base");
      Write_File (Root, "f.txt", "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("B middle");
      Write_File (Root, "f.txt", "c" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("C tip");

      Ada.Environment_Variables.Set
        ("GIT_SEQUENCE_EDITOR", "sed -i '/B middle/s/^pick/edit/'");

      Version.Rebase.Start_Interactive ("HEAD~2");
      Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");

      --  Stopped for edit at B: rebase still in progress, branch at B, clean.
      Assert (Version.Rebase.In_Progress,
              "edit must stop the rebase in progress");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s)"" = ""B middle""");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git status --porcelain)""");

      --  A new commit made during the stop must be preserved, with the
      --  remaining commit replayed on top on --continue.
      Write_File (Root, "g.txt", "inserted" & LF);
      Version.Git_Fixtures.Run (Root, "git add g.txt");
      Version.Write.Save ("inserted");

      Version.Rebase.Continue_Rebase;

      Assert (not Version.Rebase_State.State_Exists (Version.Repository.Open),
              "continue must finish the rebase");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD~3)"" = ""A base""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD~2)"" = ""B middle""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD~1)"" = ""inserted""");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log -1 --format=%s HEAD)"" = ""C tip""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_SEQUENCE_EDITOR");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rebase_Interactive_Edit_Stops_And_Continues;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Rebase_Interactive_Rewords_Commit'Access,
         "Rebase: interactive todo rewords a commit (Git-compatible)");
      Register_Routine
        (T,
         Rebase_Interactive_Reword_Empty_Message_Aborts'Access,
         "Rebase: interactive reword aborts on empty message");
      Register_Routine
        (T,
         Rebase_Interactive_Edit_Stops_And_Continues'Access,
         "Rebase: interactive edit stops, preserves a commit, continues");
      Register_Routine
        (T,
         Rebase_Merges_Preserves_Topology'Access,
         "Rebase: --rebase-merges recreates an internal merge commit");
      Register_Routine
        (T,
         Rebase_Root_Onto_Newbase'Access,
         "Rebase: --root --onto replays the whole branch incl. root");
      Register_Routine
        (T,
         Rebase_Interactive_Drops_Commit'Access,
         "Rebase: interactive todo drops a commit");
      Register_Routine
        (T,
         Rebase_Interactive_Squashes_Commit'Access,
         "Rebase: interactive todo squashes a commit");
      Register_Routine
        (T,
         Rebase_State_Write_Read_Clear'Access,
         "Rebase state: write read clear paused state");
      Register_Routine
        (T,
         Rebase_State_Rejects_Malformed_Progress'Access,
         "Rebase state: reject malformed progress");
      Register_Routine
        (T,
         Rebase_Linear_Clean_Replay'Access,
         "Rebase: linear clean replay is Git compatible");
      Register_Routine
        (T,
         Rebase_State_Blocks_Branch_Switch_And_Checkout'Access,
         "Rebase: state blocks branch switch and checkout");
      Register_Routine
        (T,
         Rebase_Continue_Rejects_Missing_Merge_State'Access,
         "Rebase: continue rejects missing merge state");

      Register_Routine
        (T,
         Rebase_Continue_Rejects_Untracked_File'Access,
         "Rebase: continue rejects unrelated untracked files");

      Register_Routine
        (T,
         Rebase_Preserves_Two_Commit_Order_And_Reflog'Access,
         "Rebase: preserves replay order and reflog recovery");
      Register_Routine
        (T,
         Rebase_Preserves_Author_And_Message'Access,
         "Rebase: preserves author and commit message");
      Register_Routine
        (T,
         Rebase_Rejects_Root_Replay_Without_Mutation'Access,
         "Rebase: root replay rejected without mutation");
      Register_Routine
        (T,
         Rebase_Rejects_Merge_Commit_Replay'Access,
         "Rebase: merge commit replay rejected");
      Register_Routine
        (T,
         Rebase_Conflict_Pauses_And_Abort_Restores'Access,
         "Rebase: conflict pauses and abort restores branch");
      Register_Routine
        (T,
         Rebase_Conflict_Continue_Completes'Access,
         "Rebase: conflict continue completes replay");
      Register_Routine
        (T,
         Rebase_Conflict_Does_Not_Create_Or_Rewrite_Rerere'Access,
         "Rebase: disabled rerere preserves existing metadata");
      Register_Routine
        (T,
         Rebase_Rerere_Records_Postimage_On_Continue'Access,
         "Rebase: rerere records and reuses postimage on replay");
      Register_Routine
        (T,
         Rebase_Continue_Post_Commit_Failure_Preserves_Commit'Access,
         "Rebase: post-commit failure preserves completed continuation");
      Register_Routine
        (T,
         Rebase_Rejects_Unclean_Working_Tree'Access,
         "Rebase: clean working tree required");
      Register_Routine
        (T,
         Rebase_Rejects_Detached_HEAD'Access,
         "Rebase: detached HEAD rejected");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Rebase");
   end Name;

end Version.Rebase.Tests;
