with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Checkout;
with Version.Git_Fixtures;
with Version.Init;
with Version.Merge_State;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Revert_State; use Version.Revert_State;
with Version.Test_Support;
with Version.Write;

package body Version.Revert.Tests is
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

   function Test_Repo (Root : String) return Version.Repository.Repository_Handle is
   begin
      return Version.Repository.Open_Git_Dir
        (Version.Test_Support.Join (Root, ".git"));
   end Test_Repo;

   function Head_Reflog_Lock_Path (Root : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "HEAD") & ".lock";
   end Head_Reflog_Lock_Path;

   function Branch_Reflog_Lock_Path
     (Root : String;
      Name : String) return String
   is
   begin
      return
        Version.Reflog.Path (Test_Repo (Root), "refs/heads/" & Name)
        & ".lock";
   end Branch_Reflog_Lock_Path;

   procedure Prepare_Clean_Revert
     (Root        : String;
      Reverted    : out Version.Objects.Hex_Object_Id;
      Target_Head : out Version.Objects.Hex_Object_Id)
   is
   begin
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add line");
      Reverted := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Target_Head := Reverted;
   end Prepare_Clean_Revert;

   procedure Revert_State_Write_Read_Clear
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      Commits.Append (C_Id);
      Commits.Append (D_Id);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (not Version.Revert_State.State_Exists (Repo),
                 "revert state must not exist initially");
         Version.Revert_State.Write_State
           (Repo           => Repo,
            Kind           => Version.Revert_State.Symbolic_Head,
            Head_Ref       => "refs/heads/main",
            Original_Head  => A_Id,
            Current_Head   => B_Id,
            Next_Index     => 1,
            Commits        => Commits,
            Paused         => True,
            Current_Commit => To_String (D_Id));
         declare
            State : constant Version.Revert_State.State :=
              Version.Revert_State.Read_State (Repo);
         begin
            Assert (Version.Revert_State.Kind (State) = Version.Revert_State.Symbolic_Head,
                    "head kind mismatch");
            Assert (Version.Revert_State.Head_Ref (State) = "refs/heads/main",
                    "head ref mismatch");
            Assert (Version.Revert_State.Original_Head (State) = A_Id,
                    "original head mismatch");
            Assert (Version.Revert_State.Current_Head (State) = B_Id,
                    "current head mismatch");
            Assert (Version.Revert_State.Next_Index (State) = 1,
                    "next index mismatch");
            Assert (Version.Revert_State.Total_Commits (State) = 2,
                    "total commits mismatch");
            Assert (Version.Revert_State.Paused (State),
                    "paused mismatch");
            Assert (Version.Revert_State.Current_Commit (State) = D_Id,
                    "current commit mismatch");
         end;
         Version.Revert_State.Clear_State (Repo);
         Assert (not Version.Revert_State.State_Exists (Repo),
                 "revert state must clear");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_State_Write_Read_Clear;

   procedure Revert_Single_Clean_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Reverted_Commit : String (1 .. 40);
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add line");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Reverted_Commit := Version.Refs.Current_Commit_Id (Repo);
         Version.Revert.Start (Reverted_Commit);
         Assert (not Version.Revert_State.State_Exists (Repo),
                 "clean revert must clear state");
         Assert (Version.Refs.Current_Commit_Id (Repo) /= Reverted_Commit,
                 "revert must create a new commit");
      end;
      Assert (File_Text (Root, "a.txt") = "base", "revert must restore base content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      declare
         Revert_Head : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git log -1 --format=%s)"" = 'Revert ""add line""'");
         Version.Git_Fixtures.Run
           (Root,
            "git log -1 --format=%B | grep -F ""This reverts commit "
            & Reverted_Commit & ".""");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git reflog -1 --format=%gs HEAD)"" = ""revert: add line""");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git reflog -1 --format=%gs main)"" = ""revert: add line""");
         Assert (Revert_Head /= Reverted_Commit,
                 "revert head must differ from reverted commit");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Single_Clean_Commit;

   procedure Revert_Multiple_Commits_In_Order
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Write_File (Root, "one.txt", "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add one.txt");
      Version.Write.Save ("add one");
      Commits.Append (Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Version.Repository.Open)));
      Write_File (Root, "two.txt", "two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add two.txt");
      Version.Write.Save ("add two");
      Commits.Append (Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Version.Repository.Open)));

      Version.Revert.Start (Commits);
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "one.txt")),
              "first reverted add must remove one.txt");
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "two.txt")),
              "second reverted add must remove two.txt");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git log -2 --format=%s | paste -sd, -)"" = "
         & "'Revert ""add two"",Revert ""add one""'");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Multiple_Commits_In_Order;

   procedure Revert_Detached_HEAD_Advances_Only_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add line");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Main_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Checkout.Checkout_Commit (Version.Objects.To_Object_Id (Main_Before));
         Version.Revert.Start (Main_Before);
         Assert (Version.Refs.Is_Detached (Repo), "HEAD must remain detached");
         Assert (Version.Refs.Current_Commit_Id (Repo) /= Main_Before,
                 "detached HEAD must advance");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse main)"" = """ & Main_Before & """");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Detached_HEAD_Advances_Only_HEAD;

   procedure Revert_Rejects_Dirty_Working_Tree
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
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add line");
      declare
         Rev : constant String := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Write_File (Root, "dirty.txt", "dirty" & Character'Val (10));
         begin
            Version.Revert.Start (Rev);
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
      end;
      Assert (Raised, "dirty working tree must reject revert");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Rejects_Dirty_Working_Tree;

   procedure Revert_Rejects_Merge_Commits
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
      Message_Matched : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Git_Fixtures.Run (Root, "git checkout -b side");
      Write_File (Root, "side.txt", "side" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add side.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m side");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m main");
      Version.Git_Fixtures.Run (Root, "git merge --no-ff side -m merge-side");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Merge_Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         declare
            Original_Head : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            begin
               Version.Revert.Start (Merge_Commit);
            exception
               when Error : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Message_Matched :=
                    Ada.Strings.Fixed.Index
                      (Ada.Exceptions.Exception_Message (Error),
                       "mainline") /= 0;
            end;
            Assert (Version.Refs.Current_Commit_Id (Repo) = Original_Head,
                    "merge rejection must not move HEAD");
            Assert (not Version.Revert_State.State_Exists (Repo),
                    "merge rejection must not write revert state");
            Assert (not Version.Merge_State.State_Exists (Repo),
                    "merge rejection must not write merge state");
         end;
      end;
      Assert (Raised, "merge commit revert must be rejected");
      Assert (Message_Matched, "merge rejection must mention mainline");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Rejects_Merge_Commits;

   procedure Revert_Merge_Commit_With_Mainline
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
      Version.Git_Fixtures.Run (Root, "git checkout -b side");
      Write_File (Root, "side.txt", "side" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add side.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m side");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m main");
      Version.Git_Fixtures.Run (Root, "git merge --no-ff side -m merge-side");
      declare
         Merge_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Revert.Start (Merge_Commit, 1);
         Assert (not Ada.Directories.Exists
                   (Version.Test_Support.Join (Root, "side.txt")),
                 "mainline 1 revert must remove side changes");
         Assert (File_Text (Root, "main.txt") = "main",
                 "mainline 1 revert must keep mainline content");
         Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

         Version.Git_Fixtures.Run (Root, "git reset --hard " & Merge_Commit);
         Version.Revert.Start (Merge_Commit, 2);
         Assert (not Ada.Directories.Exists
                   (Version.Test_Support.Join (Root, "main.txt")),
                 "mainline 2 revert must remove main changes");
         Assert (File_Text (Root, "side.txt") = "side",
                 "mainline 2 revert must keep side mainline content");
         Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
         Version.Git_Fixtures.Run (Root, "git fsck --strict");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Merge_Commit_With_Mainline;



   procedure Revert_Merge_Mainline_Conflict_Continue_And_Abort
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
      Version.Git_Fixtures.Run (Root, "git checkout -b side");
      Write_File (Root, "conflict.txt", "side" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m side");
      Version.Git_Fixtures.Run (Root, "git checkout main");
      Write_File (Root, "conflict.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m main");
      Version.Git_Fixtures.Run (Root, "git merge --no-ff side -m merge-side || true");
      Write_File (Root, "conflict.txt", "merged" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add conflict.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m merge-side");
      declare
         Merge_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Write_File (Root, "conflict.txt", "other" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add conflict.txt");
         Version.Write.Save ("other");
         declare
            Original_Head : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            begin
               Version.Revert.Start (Merge_Commit, 1);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "merge mainline revert must pause on conflict");
            Assert (Version.Revert_State.State_Exists (Repo),
                    "conflicted merge revert must write state");
            Assert (Version.Revert_State.Mainline
                      (Version.Revert_State.Read_State (Repo)) = 1,
                    "conflicted merge revert must persist mainline");
            Assert (Version.Merge_State.State_Exists (Repo),
                    "conflicted merge revert must write merge state");
            Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));
            Version.Revert.Continue_Revert;
            Assert (File_Text (Root, "conflict.txt") = "resolved",
                    "continued merge revert must keep resolved content");
            Assert (not Version.Revert_State.State_Exists (Repo),
                    "continued merge revert must clear state");

            Version.Git_Fixtures.Run (Root, "git reset --hard " & Original_Head);
            Raised := False;
            begin
               Version.Revert.Start (Merge_Commit, 1);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "merge mainline revert abort fixture must conflict");
            Assert (Version.Revert_State.Mainline
                      (Version.Revert_State.Read_State (Repo)) = 1,
                    "aborted merge revert must persist mainline before abort");
            Version.Revert.Abort_Revert;
            Assert (Version.Refs.Current_Commit_Id (Repo) = Original_Head,
                    "abort must restore pre-merge-revert HEAD");
            Assert (File_Text (Root, "conflict.txt") = "other",
                    "abort must restore pre-merge-revert worktree");
            Assert (not Version.Revert_State.State_Exists (Repo),
                    "abort must clear merge revert state");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Merge_Mainline_Conflict_Continue_And_Abort;

   procedure Revert_Conflict_Pause_Continue_And_Abort
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
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Reverted : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         begin
            Version.Revert.Start (Reverted);
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
         Assert (Raised, "conflicting revert must pause");
         Assert (Version.Revert_State.State_Exists (Repo),
                 "conflicting revert must persist state");
         Assert (Version.Merge_State.State_Exists (Repo),
                 "conflicting revert must persist merge state");
         Assert (Ada.Strings.Fixed.Index (File_Text (Root, "a.txt"), "<<<<<<<") /= 0,
                 "conflict markers expected");
         Write_Hook
           (Root,
            "post-commit",
            "echo revert continue > revert-post-commit.txt" & Character'Val (10)
            & "exit 0" & Character'Val (10));
         Write_File (Root, "a.txt", "resolved" & Character'Val (10));
         Version.Revert.Continue_Revert;
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "revert-post-commit.txt")),
            "revert continue must run post-commit hook");
         Assert (not Version.Revert_State.State_Exists (Repo),
                 "continue must clear revert state");
         Assert (File_Text (Root, "a.txt") = "resolved",
                 "resolved file must remain after continue");
      end;
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Conflict_Pause_Continue_And_Abort;

   procedure Revert_Rerere_Records_And_Reuses_Postimage
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
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Reverted : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original_Main : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Git_Fixtures.Run (Root, "git config rerere.enabled true");

            begin
               Version.Revert.Start (Reverted);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "rerere-enabled revert must pause on first conflict");
            Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/preimage");
            Write_File (Root, "a.txt", "resolved" & Character'Val (10));
            Version.Revert.Continue_Revert;
            Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/postimage");

            Version.Git_Fixtures.Run (Root, "git reset --hard " & Original_Main);
            Raised := False;
            begin
               Version.Revert.Start (Reverted);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
            Assert
              (not Raised,
               "rerere-enabled revert must reuse recorded resolution");
            Assert
              (File_Text (Root, "a.txt") = "resolved",
               "revert rerere reuse must materialize recorded postimage");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Rerere_Records_And_Reuses_Postimage;

   procedure Revert_Abort_Restores_Original_HEAD
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
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Reverted : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            begin
               Version.Revert.Start (Reverted);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "conflict expected before abort");
            Version.Revert.Abort_Revert;
            Assert (Version.Refs.Current_Commit_Id (Repo) = Original,
                    "abort must restore original branch HEAD");
            Assert (not Version.Revert_State.State_Exists (Repo),
                    "abort must clear revert state");
            Assert (File_Text (Root, "a.txt") = "main",
                    "abort must restore worktree");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Abort_Restores_Original_HEAD;

   procedure Revert_Abort_Restores_Original_Detached_HEAD
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
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Reverted : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Checkout.Checkout_Commit
              (Version.Objects.To_Object_Id (Original));
            begin
               Version.Revert.Start (Reverted);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "detached conflict expected before abort");
            Version.Revert.Abort_Revert;
            Assert (Version.Refs.Is_Detached (Repo),
                    "abort must preserve detached HEAD mode");
            Assert (Version.Refs.Current_Commit_Id (Repo) = Original,
                    "abort must restore original detached HEAD");
            Assert (File_Text (Root, "a.txt") = "main",
                    "detached abort must restore worktree");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Abort_Restores_Original_Detached_HEAD;

   procedure Revert_Abort_After_Partial_Multi_Restores_Original_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "one.txt", "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add one.txt");
      Version.Write.Save ("add one");
      Commits.Append
        (Version.Objects.To_Object_Id
           (Version.Refs.Current_Commit_Id (Version.Repository.Open)));
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      Commits.Append
        (Version.Objects.To_Object_Id
           (Version.Refs.Current_Commit_Id (Version.Repository.Open)));
      Write_File (Root, "a.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("main change");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Original : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         begin
            Version.Revert.Start (Commits);
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;

         Assert (Raised,
                 "second revert in multi-revert should pause on conflict");
         Assert (Version.Revert_State.State_Exists (Repo),
                 "partial multi-revert conflict must keep revert state");
         Assert (Version.Refs.Current_Commit_Id (Repo) /= Original,
                 "first clean revert should have advanced HEAD before conflict");
         Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "one.txt")),
                 "first clean revert should remove one.txt before conflict");

         Version.Revert.Abort_Revert;
         Assert (Version.Refs.Current_Commit_Id (Repo) = Original,
                 "abort must restore original HEAD after partial multi-revert");
         Assert (File_Text (Root, "a.txt") = "main",
                 "abort must restore original a.txt content");
         Assert (File_Text (Root, "one.txt") = "one",
                 "abort must restore files removed by earlier reverted commits");
         Assert (not Version.Revert_State.State_Exists (Repo),
                 "abort must clear partial multi-revert state");
      end;

      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Abort_After_Partial_Multi_Restores_Original_HEAD;

   procedure Revert_State_Blocks_Nested_Revert
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Write_File (Root, "a.txt", "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add line");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Rev : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Commits.Append (Rev);
         Version.Revert_State.Write_State
           (Repo          => Repo,
            Kind          => Version.Revert_State.Symbolic_Head,
            Head_Ref      => "refs/heads/main",
            Original_Head => Rev,
            Current_Head  => Rev,
            Next_Index    => 0,
            Commits       => Commits);
         begin
            Version.Revert.Start (To_String (Rev));
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
         Version.Revert_State.Clear_State (Repo);
      end;
      Assert (Raised, "existing revert state must block nested start");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_State_Blocks_Nested_Revert;

   procedure Revert_Root_Commit_Removes_Root_Files
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "root.txt", "root" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add root.txt");
      Version.Write.Save ("root");

      declare
         Root_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Write_File (Root, "later.txt", "later" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add later.txt");
         Version.Write.Save ("later");

         declare
            Before_Revert : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Version.Revert.Start (Root_Commit);

            Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) /= Before_Revert,
                    "root revert must advance HEAD");
            Assert
              (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "root.txt")),
               "root revert must remove files introduced by the root commit");
            Assert (File_Text (Root, "later.txt") = "later",
                    "root revert must preserve later files");
            Assert (not Version.Revert_State.State_Exists (Version.Repository.Open),
                    "clean root revert must not leave state");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Root_Commit_Removes_Root_Files;

   procedure Revert_Post_Commit_Hook_Failure_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Reverted : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Revert (Root, Reverted, Target_Head);
      Write_Hook
        (Root,
         "post-commit",
         "exit 1" & Character'Val (10));

      begin
         Version.Revert.Start (To_String (Reverted));
      exception
         when Ada.IO_Exceptions.Data_Error => Raised := True;
      end;

      Assert (Raised, "failing post-commit hook must reject revert");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "post-commit failure must leave branch tip unchanged");
      Assert (File_Text (Root, "a.txt") = "changed",
              "post-commit failure must roll back worktree");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Post_Commit_Hook_Failure_Rolls_Back;

   procedure Revert_Head_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Reverted : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Revert (Root, Reverted, Target_Head);
      Version.Test_Support.Write_Text_File
        (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

      begin
         Version.Revert.Start (To_String (Reverted));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "HEAD reflog lock must reject revert");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "HEAD reflog lock must leave branch tip unchanged");
      Assert (File_Text (Root, "a.txt") = "changed",
              "HEAD reflog lock must roll back worktree");
      Assert (Ada.Directories.Exists (Head_Reflog_Lock_Path (Root)),
              "stale HEAD reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Head_Reflog_Lock_Rolls_Back;

   procedure Revert_Branch_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Reverted : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Revert (Root, Reverted, Target_Head);
      Version.Test_Support.Write_Text_File
        (Branch_Reflog_Lock_Path (Root, "main"), "locked" & Character'Val (10));

      begin
         Version.Revert.Start (To_String (Reverted));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "branch reflog lock must reject revert");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "branch reflog lock must leave branch tip unchanged");
      Assert (File_Text (Root, "a.txt") = "changed",
              "branch reflog lock must roll back worktree");
      Assert (Ada.Directories.Exists (Branch_Reflog_Lock_Path (Root, "main")),
              "stale branch reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Branch_Reflog_Lock_Rolls_Back;

   procedure Revert_Detached_Head_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Reverted : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Revert (Root, Reverted, Target_Head);
      Version.Checkout.Checkout_Commit (Target_Head);
      Version.Test_Support.Write_Text_File
        (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

      begin
         Version.Revert.Start (To_String (Reverted));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "detached HEAD reflog lock must reject revert");
      Assert (Version.Refs.Is_Detached (Version.Repository.Open),
              "detached HEAD reflog lock must preserve detached mode");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "detached HEAD reflog lock must leave HEAD unchanged");
      Assert (File_Text (Root, "a.txt") = "changed",
              "detached HEAD reflog lock must roll back worktree");
      Assert (Ada.Directories.Exists (Head_Reflog_Lock_Path (Root)),
              "stale HEAD reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_Detached_Head_Reflog_Lock_Rolls_Back;

   procedure Revert_No_State_Continue_Abort_Reject
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Continue_Raised : Boolean := False;
      Abort_Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Revert.Continue_Revert;
      exception
         when Ada.IO_Exceptions.Data_Error => Continue_Raised := True;
      end;
      begin
         Version.Revert.Abort_Revert;
      exception
         when Ada.IO_Exceptions.Data_Error => Abort_Raised := True;
      end;
      Assert (Continue_Raised, "continue without state must reject");
      Assert (Abort_Raised, "abort without state must reject");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Revert_No_State_Continue_Abort_Reject;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Revert_State_Write_Read_Clear'Access,
                        "Revert state: write read clear paused state");
      Register_Routine (T, Revert_Single_Clean_Commit'Access,
                        "Revert: single clean commit");
      Register_Routine (T, Revert_Multiple_Commits_In_Order'Access,
                        "Revert: multiple commits in requested order");
      Register_Routine (T, Revert_Detached_HEAD_Advances_Only_HEAD'Access,
                        "Revert: detached HEAD advances only HEAD");
      Register_Routine (T, Revert_Rejects_Dirty_Working_Tree'Access,
                        "Revert: rejects dirty working tree");
      Register_Routine (T, Revert_Rejects_Merge_Commits'Access,
                        "Revert: rejects merge commits without mainline");
      Register_Routine (T, Revert_Merge_Commit_With_Mainline'Access,
                        "Revert: replays merge commits with mainline");
      Register_Routine
        (T, Revert_Merge_Mainline_Conflict_Continue_And_Abort'Access,
         "Revert: merge mainline conflict continue and abort");
      Register_Routine (T, Revert_Conflict_Pause_Continue_And_Abort'Access,
                        "Revert: conflict pause and continue");
      Register_Routine
        (T, Revert_Rerere_Records_And_Reuses_Postimage'Access,
         "Revert: rerere records and reuses postimage on replay");
      Register_Routine (T, Revert_Root_Commit_Removes_Root_Files'Access,
                        "Revert: root commit removes root files");
      Register_Routine (T, Revert_Abort_Restores_Original_HEAD'Access,
                        "Revert: abort restores original HEAD");
      Register_Routine (T, Revert_Abort_Restores_Original_Detached_HEAD'Access,
                        "Revert: abort restores original detached HEAD");
      Register_Routine
        (T, Revert_Abort_After_Partial_Multi_Restores_Original_HEAD'Access,
         "Revert: abort restores original HEAD after partial multi-revert");
      Register_Routine (T, Revert_State_Blocks_Nested_Revert'Access,
                        "Revert: state blocks nested revert");
      Register_Routine (T, Revert_Post_Commit_Hook_Failure_Rolls_Back'Access,
                        "Revert: post-commit hook failure rolls back");
      Register_Routine (T, Revert_Head_Reflog_Lock_Rolls_Back'Access,
                        "Revert: HEAD reflog lock rolls back");
      Register_Routine (T, Revert_Branch_Reflog_Lock_Rolls_Back'Access,
                        "Revert: branch reflog lock rolls back");
      Register_Routine (T, Revert_Detached_Head_Reflog_Lock_Rolls_Back'Access,
                        "Revert: detached HEAD reflog lock rolls back");
      Register_Routine (T, Revert_No_State_Continue_Abort_Reject'Access,
                        "Revert: continue and abort require state");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Revert");
   end Name;

end Version.Revert.Tests;
