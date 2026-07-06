with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Checkout;
with Version.Files;
with Version.Cherry_Pick_State; use Version.Cherry_Pick_State;
with Version.Git_Fixtures;
with Version.Init;
with Version.Merge_State;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Revisions;
with Version.Test_Support;
with Version.Write;

package body Version.Cherry_Pick.Tests is
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

   procedure Prepare_Clean_Cherry_Pick
     (Root        : String;
      Pick        : out Version.Objects.Hex_Object_Id;
      Target_Head : out Version.Objects.Hex_Object_Id)
   is
   begin
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");
      Pick := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Branch.Switch_Branch ("main");
      Write_File (Root, "main.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add main.txt");
      Version.Write.Save ("main change");
      Target_Head := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
   end Prepare_Clean_Cherry_Pick;

   procedure Cherry_Pick_State_Write_Read_Clear
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Cherry_Pick_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      Commits.Append (C_Id);
      Commits.Append (D_Id);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                 "cherry-pick state must not exist initially");
         Version.Cherry_Pick_State.Write_State
           (Repo           => Repo,
            Kind           => Version.Cherry_Pick_State.Symbolic_Head,
            Head_Ref       => "refs/heads/main",
            Original_Head  => A_Id,
            Current_Head   => B_Id,
            Next_Index     => 1,
            Commits        => Commits,
            Paused         => True,
            Current_Commit => To_String (D_Id));
         declare
            State : constant Version.Cherry_Pick_State.State :=
              Version.Cherry_Pick_State.Read_State (Repo);
         begin
            Assert (Version.Cherry_Pick_State.Kind (State) = Version.Cherry_Pick_State.Symbolic_Head,
                    "head kind mismatch");
            Assert (Version.Cherry_Pick_State.Head_Ref (State) = "refs/heads/main",
                    "head ref mismatch");
            Assert (Version.Cherry_Pick_State.Original_Head (State) = A_Id,
                    "original head mismatch");
            Assert (Version.Cherry_Pick_State.Current_Head (State) = B_Id,
                    "current head mismatch");
            Assert (Version.Cherry_Pick_State.Next_Index (State) = 1,
                    "next index mismatch");
            Assert (Version.Cherry_Pick_State.Total_Commits (State) = 2,
                    "total commits mismatch");
            Assert (Version.Cherry_Pick_State.Paused (State),
                    "paused mismatch");
            Assert (Version.Cherry_Pick_State.Current_Commit (State) = D_Id,
                    "current commit mismatch");
         end;
         Version.Cherry_Pick_State.Clear_State (Repo);
         Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                 "cherry-pick state must clear");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_State_Write_Read_Clear;

   procedure Cherry_Pick_Single_Clean_Commit
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

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Feature_Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "main.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add main.txt");
         Version.Write.Save ("main change");
         Version.Cherry_Pick.Start (To_String (Feature_Commit));
         Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                 "clean cherry-pick must clear state");
         Assert (Version.Refs.Current_Commit_Id (Repo) /= To_String (Feature_Commit),
                 "cherry-pick must create a new commit");
      end;

      Assert (File_Text (Root, "feature.txt") = "feature",
              "cherry-picked file missing");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run (Root, "test ""$(git log -1 --format=%s)"" = ""feature change""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Single_Clean_Commit;

   procedure Cherry_Pick_Multiple_Commits_In_Order
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commits : Version.Cherry_Pick_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");

      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "one.txt", "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add one.txt");
      Version.Write.Save ("pick one");
      Commits.Append (Version.Revisions.Resolve_Commit (Version.Repository.Open, "HEAD"));
      Write_File (Root, "two.txt", "two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add two.txt");
      Version.Write.Save ("pick two");
      Commits.Append (Version.Revisions.Resolve_Commit (Version.Repository.Open, "HEAD"));

      Version.Branch.Switch_Branch ("main");
      Version.Cherry_Pick.Start (Commits);
      Version.Git_Fixtures.Run (Root, "test ""$(git log -2 --format=%s | paste -sd, -)"" = ""pick two,pick one""");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Multiple_Commits_In_Order;

   procedure Cherry_Pick_Detached_HEAD_Advances_Only_HEAD
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
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Feature_Commit : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Branch.Switch_Branch ("main");
         declare
            Main_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Checkout.Checkout_Commit (Version.Objects.To_Object_Id (Main_Before));
            Version.Cherry_Pick.Start (To_String (Feature_Commit));
            Assert (Version.Refs.Is_Detached (Repo), "HEAD must remain detached");
            Assert (Version.Refs.Current_Commit_Id (Repo) /= Main_Before,
                    "detached HEAD must advance");
            Version.Git_Fixtures.Run
              (Root,
               "test ""$(git rev-parse main)"" = """ & Main_Before & """");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Detached_HEAD_Advances_Only_HEAD;

   procedure Cherry_Pick_Rejects_Dirty_Working_Tree
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
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "dirty.txt", "dirty" & Character'Val (10));
         begin
            Version.Cherry_Pick.Start (Pick);
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
      end;
      Assert (Raised, "dirty working tree must reject cherry-pick");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Rejects_Dirty_Working_Tree;

   procedure Cherry_Pick_Rejects_Merge_Commits
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
         Version.Git_Fixtures.Run (Root, "git reset --hard HEAD~1");
         declare
            Original_Head : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            begin
               Version.Cherry_Pick.Start (Merge_Commit);
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
            Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                    "merge rejection must not write cherry-pick state");
            Assert (not Version.Merge_State.State_Exists (Repo),
                    "merge rejection must not write merge state");
         end;
      end;
      Assert (Raised, "merge commit cherry-pick must be rejected");
      Assert (Message_Matched, "merge rejection must mention mainline");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Rejects_Merge_Commits;

   procedure Cherry_Pick_Merge_Commit_With_Mainline
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
      declare
         Side_Parent : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "git checkout main");
         Write_File (Root, "main.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add main.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m main");
         declare
            Main_Parent : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Version.Git_Fixtures.Run (Root, "git merge --no-ff side -m merge-side");
            declare
               Merge_Commit : constant String :=
                 Version.Refs.Current_Commit_Id (Version.Repository.Open);
            begin
               Version.Git_Fixtures.Run (Root, "git reset --hard " & Main_Parent);
               Version.Cherry_Pick.Start (Merge_Commit, 1);
               Assert (File_Text (Root, "side.txt") = "side",
                       "mainline 1 cherry-pick must replay side changes");
               Assert (File_Text (Root, "main.txt") = "main",
                       "mainline 1 cherry-pick must keep current parent content");
               Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

               Version.Git_Fixtures.Run (Root, "git reset --hard " & Side_Parent);
               Version.Cherry_Pick.Start (Merge_Commit, 2);
               Assert (File_Text (Root, "main.txt") = "main",
                       "mainline 2 cherry-pick must replay main changes");
               Assert (File_Text (Root, "side.txt") = "side",
                       "mainline 2 cherry-pick must keep current parent content");
               Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
               Version.Git_Fixtures.Run (Root, "git fsck --strict");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Merge_Commit_With_Mainline;



   procedure Cherry_Pick_Merge_Mainline_Conflict_Continue_And_Abort
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
      declare
         Main_Parent : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "git merge --no-ff side -m merge-side || true");
         Write_File (Root, "conflict.txt", "merged" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add conflict.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m merge-side");
         declare
            Merge_Commit : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Version.Git_Fixtures.Run (Root, "git reset --hard " & Main_Parent);
            Write_File (Root, "conflict.txt", "other" & Character'Val (10));
            Version.Git_Fixtures.Run (Root, "git add conflict.txt");
            Version.Git_Fixtures.Run (Root, "git commit -m other");
            declare
               Original_Head : constant String :=
                 Version.Refs.Current_Commit_Id (Version.Repository.Open);
               Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open;
            begin
               begin
                  Version.Cherry_Pick.Start (Merge_Commit, 1);
               exception
                  when Ada.IO_Exceptions.Data_Error => Raised := True;
               end;
               Assert (Raised, "merge mainline cherry-pick must pause on conflict");
               Assert (Version.Cherry_Pick_State.State_Exists (Repo),
                       "conflicted merge cherry-pick must write state");
               Assert (Version.Cherry_Pick_State.Mainline
                         (Version.Cherry_Pick_State.Read_State (Repo)) = 1,
                       "conflicted merge cherry-pick must persist mainline");
               Assert (Version.Merge_State.State_Exists (Repo),
                       "conflicted merge cherry-pick must write merge state");
               Write_File (Root, "conflict.txt", "resolved" & Character'Val (10));
               Version.Cherry_Pick.Continue_Cherry_Pick;
               Assert (File_Text (Root, "conflict.txt") = "resolved",
                       "continued merge cherry-pick must keep resolved content");
               Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                       "continued merge cherry-pick must clear state");

               Version.Git_Fixtures.Run (Root, "git reset --hard " & Original_Head);
               Raised := False;
               begin
                  Version.Cherry_Pick.Start (Merge_Commit, 1);
               exception
                  when Ada.IO_Exceptions.Data_Error => Raised := True;
               end;
               Assert (Raised, "merge mainline cherry-pick abort fixture must conflict");
               Assert (Version.Cherry_Pick_State.Mainline
                         (Version.Cherry_Pick_State.Read_State (Repo)) = 1,
                       "aborted merge cherry-pick must persist mainline before abort");
               Version.Cherry_Pick.Abort_Cherry_Pick;
               Assert (Version.Refs.Current_Commit_Id (Repo) = Original_Head,
                       "abort must restore pre-merge-cherry-pick HEAD");
               Assert (File_Text (Root, "conflict.txt") = "other",
                       "abort must restore pre-merge-cherry-pick worktree");
               Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                       "abort must clear merge cherry-pick state");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Merge_Mainline_Conflict_Continue_And_Abort;

   procedure Cherry_Pick_Conflict_Pause_Continue_And_Abort
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
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         begin
            Version.Cherry_Pick.Start (Pick);
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
         Assert (Raised, "conflicting cherry-pick must pause");
         Assert (Version.Cherry_Pick_State.State_Exists (Repo),
                 "conflicting cherry-pick must persist state");
         Assert (Version.Merge_State.State_Exists (Repo),
                 "conflicting cherry-pick must persist merge state");
         Assert (Ada.Strings.Fixed.Index (File_Text (Root, "a.txt"), "<<<<<<<") /= 0,
                 "conflict markers expected");
         Write_File (Root, "a.txt", "resolved" & Character'Val (10));
         Version.Cherry_Pick.Continue_Cherry_Pick;
         Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                 "continue must clear cherry-pick state");
         Assert (File_Text (Root, "a.txt") = "resolved",
                 "resolved file must remain after continue");
      end;
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Conflict_Pause_Continue_And_Abort;

   procedure Cherry_Pick_Conflict_Does_Not_Create_Or_Rewrite_Rerere
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sentinel : constant String :=
        "disabled rerere sentinel" & Character'Val (10);
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "a.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         Seed_Rerere_Sentinel (Root, Sentinel);

         begin
            Version.Cherry_Pick.Start (Pick);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "conflicting cherry-pick must pause");
         Assert
           (Version.Files.Read_Binary_File (Rerere_Sentinel_Path (Root))
            = Sentinel,
            "cherry-pick conflict must preserve preexisting rerere metadata");
         Assert
           (Ada.Directories.Exists (Rerere_Cache_Path (Root)),
            "cherry-pick conflict must not remove preexisting rr-cache");

         Version.Cherry_Pick.Abort_Cherry_Pick;
         Assert
           (Version.Files.Read_Binary_File (Rerere_Sentinel_Path (Root))
            = Sentinel,
            "cherry-pick abort must preserve preexisting rerere metadata");

         Ada.Directories.Delete_Tree (Rerere_Cache_Path (Root));
         Raised := False;
         begin
            Version.Cherry_Pick.Start (Pick);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "second conflicting cherry-pick must pause");
         Assert
           (not Ada.Directories.Exists (Rerere_Cache_Path (Root)),
            "cherry-pick conflict must not create rerere metadata");
         Version.Cherry_Pick.Abort_Cherry_Pick;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Conflict_Does_Not_Create_Or_Rewrite_Rerere;

   procedure Cherry_Pick_Rerere_Records_Postimage_On_Continue
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
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original_Main : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Git_Fixtures.Run (Root, "git config rerere.enabled true");

            begin
               Version.Cherry_Pick.Start (Pick);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "rerere-enabled cherry-pick must pause on first conflict");
            Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/preimage");
            Write_File (Root, "a.txt", "resolved" & Character'Val (10));
            Version.Cherry_Pick.Continue_Cherry_Pick;
            Version.Git_Fixtures.Run (Root, "test -f .git/rr-cache/*/postimage");

            Version.Git_Fixtures.Run (Root, "git reset --hard " & Original_Main);
            Raised := False;
            begin
               Version.Cherry_Pick.Start (Pick);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
            Assert
              (not Raised,
               "rerere-enabled cherry-pick must reuse recorded resolution");
            Assert
              (File_Text (Root, "a.txt") = "resolved",
               "cherry-pick rerere reuse must materialize recorded postimage");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Rerere_Records_Postimage_On_Continue;

   procedure Cherry_Pick_Abort_Restores_Original_HEAD
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
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            begin
               Version.Cherry_Pick.Start (Pick);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "conflict expected before abort");
            Version.Cherry_Pick.Abort_Cherry_Pick;
            Assert (Version.Refs.Current_Commit_Id (Repo) = Original,
                    "abort must restore original branch HEAD");
            Assert (not Version.Cherry_Pick_State.State_Exists (Repo),
                    "abort must clear cherry-pick state");
            Assert (File_Text (Root, "a.txt") = "main",
                    "abort must restore worktree");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Abort_Restores_Original_HEAD;

   procedure Cherry_Pick_Abort_Restores_Original_Detached_HEAD
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
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "a.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Branch.Switch_Branch ("main");
         Write_File (Root, "a.txt", "main" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save ("main change");
         declare
            Original : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Checkout.Checkout_Commit
              (Version.Objects.To_Object_Id (Original));
            begin
               Version.Cherry_Pick.Start (Pick);
            exception
               when Ada.IO_Exceptions.Data_Error => Raised := True;
            end;
            Assert (Raised, "detached conflict expected before abort");
            Version.Cherry_Pick.Abort_Cherry_Pick;
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
   end Cherry_Pick_Abort_Restores_Original_Detached_HEAD;

   procedure Cherry_Pick_State_Blocks_Nested_Cherry_Pick
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
      Commits : Version.Cherry_Pick_State.Commit_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Write_File (Root, "base.txt", "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add base.txt");
      Version.Write.Save ("base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Write_File (Root, "feature.txt", "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add feature.txt");
      Version.Write.Save ("feature change");
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pick : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Branch.Switch_Branch ("main");
         Commits.Append (Pick);
         Version.Cherry_Pick_State.Write_State
           (Repo          => Repo,
            Kind          => Version.Cherry_Pick_State.Symbolic_Head,
            Head_Ref      => "refs/heads/main",
            Original_Head => Version.Objects.To_Object_Id
              (Version.Refs.Current_Commit_Id (Repo)),
            Current_Head  => Version.Objects.To_Object_Id
              (Version.Refs.Current_Commit_Id (Repo)),
            Next_Index    => 0,
            Commits       => Commits);
         begin
            Version.Cherry_Pick.Start (To_String (Pick));
         exception
            when Ada.IO_Exceptions.Data_Error => Raised := True;
         end;
         Version.Cherry_Pick_State.Clear_State (Repo);
      end;
      Assert (Raised, "existing cherry-pick state must block nested start");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_State_Blocks_Nested_Cherry_Pick;

   procedure Cherry_Pick_Root_Commit_Adds_Files
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

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Main_Head : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Git_Fixtures.Run (Root, "git checkout --orphan rootpick");
         Version.Git_Fixtures.Run (Root, "git rm -rf .");
         Write_File (Root, "root.txt", "root" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add root.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m root-pick");

         declare
            Root_Commit : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Version.Git_Fixtures.Run (Root, "git checkout main");
            Version.Cherry_Pick.Start (Root_Commit);

            Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) /= Main_Head,
                    "root cherry-pick must advance HEAD");
            Assert (File_Text (Root, "base.txt") = "base",
                    "root cherry-pick must preserve existing files");
            Assert (File_Text (Root, "root.txt") = "root",
                    "root cherry-pick must add root commit files");
            Assert (not Version.Cherry_Pick_State.State_Exists (Version.Repository.Open),
                    "clean root cherry-pick must not leave state");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Root_Commit_Adds_Files;

   procedure Cherry_Pick_Root_Commit_Conflicts_On_Add_Add
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);

      Write_File (Root, "same.txt", "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add same.txt");
      Version.Write.Save ("main root");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Main_Head : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Git_Fixtures.Run (Root, "git checkout --orphan rootpick-conflict");
         Version.Git_Fixtures.Run (Root, "git rm -rf .");
         Write_File (Root, "same.txt", "other" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add same.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m root-conflict");

         declare
            Root_Commit : constant String :=
              Version.Refs.Current_Commit_Id (Version.Repository.Open);
         begin
            Version.Git_Fixtures.Run (Root, "git checkout main");
            begin
               Version.Cherry_Pick.Start (Root_Commit);
               Assert (False, "conflicting root cherry-pick must raise Data_Error");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  null;
            end;

            Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = Main_Head,
                    "conflicting root cherry-pick must not advance HEAD");
            Assert (Version.Cherry_Pick_State.State_Exists (Version.Repository.Open),
                    "conflicting root cherry-pick must write state");
            Assert (Version.Merge_State.State_Exists (Version.Repository.Open),
                    "conflicting root cherry-pick must write merge state");
            Assert
              (Ada.Strings.Fixed.Index (File_Text (Root, "same.txt"), "<<<<<<<") /= 0,
               "conflicting root cherry-pick must write conflict markers");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Root_Commit_Conflicts_On_Add_Add;

   procedure Cherry_Pick_Post_Commit_Hook_Failure_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Pick : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Cherry_Pick (Root, Pick, Target_Head);
      Write_Hook
        (Root,
         "post-commit",
         "exit 1" & Character'Val (10));

      begin
         Version.Cherry_Pick.Start (To_String (Pick));
      exception
         when Ada.IO_Exceptions.Data_Error => Raised := True;
      end;

      Assert (Raised, "failing post-commit hook must reject cherry-pick");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "post-commit failure must leave branch tip unchanged");
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
              "post-commit failure must roll back worktree");
      Assert (File_Text (Root, "main.txt") = "main",
              "post-commit failure must restore original worktree content");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Post_Commit_Hook_Failure_Rolls_Back;

   procedure Cherry_Pick_Head_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Pick : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Cherry_Pick (Root, Pick, Target_Head);
      Version.Test_Support.Write_Text_File
        (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

      begin
         Version.Cherry_Pick.Start (To_String (Pick));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "HEAD reflog lock must reject cherry-pick");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "HEAD reflog lock must leave branch tip unchanged");
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
              "HEAD reflog lock must roll back worktree");
      Assert (File_Text (Root, "main.txt") = "main",
              "HEAD reflog lock must keep original worktree content");
      Assert (Ada.Directories.Exists (Head_Reflog_Lock_Path (Root)),
              "stale HEAD reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Head_Reflog_Lock_Rolls_Back;

   procedure Cherry_Pick_Branch_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Pick : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Cherry_Pick (Root, Pick, Target_Head);
      Version.Test_Support.Write_Text_File
        (Branch_Reflog_Lock_Path (Root, "main"), "locked" & Character'Val (10));

      begin
         Version.Cherry_Pick.Start (To_String (Pick));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "branch reflog lock must reject cherry-pick");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "branch reflog lock must leave branch tip unchanged");
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
              "branch reflog lock must roll back worktree");
      Assert (File_Text (Root, "main.txt") = "main",
              "branch reflog lock must keep original worktree content");
      Assert (Ada.Directories.Exists (Branch_Reflog_Lock_Path (Root, "main")),
              "stale branch reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Branch_Reflog_Lock_Rolls_Back;

   procedure Cherry_Pick_Detached_Head_Reflog_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Pick : Version.Objects.Object_Id_Storage;
      Target_Head : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Prepare_Clean_Cherry_Pick (Root, Pick, Target_Head);
      Version.Checkout.Checkout_Commit (Target_Head);
      Version.Test_Support.Write_Text_File
        (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

      begin
         Version.Cherry_Pick.Start (To_String (Pick));
      exception
         when Ada.IO_Exceptions.Use_Error => Raised := True;
      end;

      Assert (Raised, "detached HEAD reflog lock must reject cherry-pick");
      Assert (Version.Refs.Is_Detached (Version.Repository.Open),
              "detached HEAD reflog lock must preserve detached mode");
      Assert (Version.Refs.Current_Commit_Id (Version.Repository.Open) = To_String (Target_Head),
              "detached HEAD reflog lock must leave HEAD unchanged");
      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "feature.txt")),
              "detached HEAD reflog lock must roll back worktree");
      Assert (File_Text (Root, "main.txt") = "main",
              "detached HEAD reflog lock must keep original worktree content");
      Assert (Ada.Directories.Exists (Head_Reflog_Lock_Path (Root)),
              "stale HEAD reflog lock must remain for operator recovery");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cherry_Pick_Detached_Head_Reflog_Lock_Rolls_Back;

   procedure Cherry_Pick_No_State_Continue_Abort_Reject
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
         Version.Cherry_Pick.Continue_Cherry_Pick;
      exception
         when Ada.IO_Exceptions.Data_Error => Continue_Raised := True;
      end;
      begin
         Version.Cherry_Pick.Abort_Cherry_Pick;
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
   end Cherry_Pick_No_State_Continue_Abort_Reject;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Cherry_Pick_State_Write_Read_Clear'Access,
         "Cherry-pick state: write read clear paused state");
      Register_Routine
        (T, Cherry_Pick_Single_Clean_Commit'Access,
         "Cherry-pick: single clean commit");
      Register_Routine
        (T, Cherry_Pick_Multiple_Commits_In_Order'Access,
         "Cherry-pick: multiple commits in requested order");
      Register_Routine
        (T, Cherry_Pick_Detached_HEAD_Advances_Only_HEAD'Access,
         "Cherry-pick: detached HEAD advances only HEAD");
      Register_Routine
        (T, Cherry_Pick_Rejects_Dirty_Working_Tree'Access,
         "Cherry-pick: rejects dirty working tree");
      Register_Routine
        (T, Cherry_Pick_Rejects_Merge_Commits'Access,
         "Cherry-pick: rejects merge commits without mainline");
      Register_Routine
        (T, Cherry_Pick_Merge_Commit_With_Mainline'Access,
         "Cherry-pick: replays merge commits with mainline");
      Register_Routine
        (T, Cherry_Pick_Merge_Mainline_Conflict_Continue_And_Abort'Access,
         "Cherry-pick: merge mainline conflict continue and abort");
      Register_Routine
        (T, Cherry_Pick_Conflict_Pause_Continue_And_Abort'Access,
         "Cherry-pick: conflict pause and continue");
      Register_Routine
        (T, Cherry_Pick_Conflict_Does_Not_Create_Or_Rewrite_Rerere'Access,
         "Cherry-pick: disabled rerere preserves existing metadata");
      Register_Routine
        (T, Cherry_Pick_Rerere_Records_Postimage_On_Continue'Access,
         "Cherry-pick: rerere records and reuses postimage on replay");
      Register_Routine
        (T, Cherry_Pick_Root_Commit_Adds_Files'Access,
         "Cherry-pick: root commit adds files");
      Register_Routine
        (T, Cherry_Pick_Root_Commit_Conflicts_On_Add_Add'Access,
         "Cherry-pick: root commit add/add conflict pauses");
      Register_Routine
        (T, Cherry_Pick_Abort_Restores_Original_HEAD'Access,
         "Cherry-pick: abort restores original HEAD");
      Register_Routine
        (T, Cherry_Pick_Abort_Restores_Original_Detached_HEAD'Access,
         "Cherry-pick: abort restores original detached HEAD");
      Register_Routine
        (T, Cherry_Pick_State_Blocks_Nested_Cherry_Pick'Access,
         "Cherry-pick: state blocks nested cherry-pick");
      Register_Routine
        (T, Cherry_Pick_Post_Commit_Hook_Failure_Rolls_Back'Access,
         "Cherry-pick: post-commit hook failure rolls back");
      Register_Routine
        (T, Cherry_Pick_Head_Reflog_Lock_Rolls_Back'Access,
         "Cherry-pick: HEAD reflog lock rolls back");
      Register_Routine
        (T, Cherry_Pick_Branch_Reflog_Lock_Rolls_Back'Access,
         "Cherry-pick: branch reflog lock rolls back");
      Register_Routine
        (T, Cherry_Pick_Detached_Head_Reflog_Lock_Rolls_Back'Access,
         "Cherry-pick: detached HEAD reflog lock rolls back");
      Register_Routine
        (T, Cherry_Pick_No_State_Continue_Abort_Reject'Access,
         "Cherry-pick: continue and abort require state");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Cherry_Pick");
   end Name;

end Version.Cherry_Pick.Tests;
