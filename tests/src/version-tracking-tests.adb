with Ada.Directories;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Clone;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Remotes;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Tracking.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Configure_User (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
   end Configure_User;

   procedure Commit_File
     (Root    : String;
      Name    : String;
      Content : String;
      Message : String)
   is
      Path : constant String := Version.Test_Support.Join (Root, Name);
   begin
      Version.Test_Support.Write_Text_File (Path, Content);
      Version.Git_Fixtures.Run (Root, "git add " & Name);
      Version.Write.Save (Message);
   end Commit_File;

   procedure Prepare_Repo
     (Root : String)
   is
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "one");
      Version.Remotes.Add_Remote (Name => "origin", Url => "/tmp/source-repo");
   end Prepare_Repo;

   procedure Write_Remote_Tracking
     (Repo   : Version.Repository.Repository_Handle;
      Remote : String;
      Branch : String;
      Id     : String)
   is
      Path : constant String :=
        Version.Test_Support.Join
          (Version.Repository.Git_Dir (Repo),
           "refs/remotes/" & Remote & "/" & Branch);
   begin
      Ada.Directories.Create_Path
        (Version.Test_Support.Join
           (Version.Repository.Git_Dir (Repo),
            "refs/remotes/" & Remote));

      Version.Files.Write_Binary_File
        (Path    => Path,
         Content => Id & Character'Val (10));
   end Write_Remote_Tracking;

   procedure Set_And_Read_Upstream
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Prepare_Repo (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Tracking.Set_Upstream
           (Repo        => Repo,
            Branch_Name => "main",
            Remote_Name => "origin",
            Merge_Ref   => "refs/heads/main");

         declare
            Info : constant Version.Tracking.Upstream_Info :=
              Version.Tracking.Upstream (Repo, "main");
         begin
            Assert (To_String (Info.Remote) = "origin", "remote mismatch");
            Assert (To_String (Info.Merge) = "refs/heads/main", "merge mismatch");
            Assert
              (Version.Tracking.Remote_Tracking_Ref (Info) = "refs/remotes/origin/main",
               "remote-tracking ref mismatch");
         end;
      end;

      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git config --get branch.main.remote)"" = ""origin""");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git config --get branch.main.merge)"" = ""refs/heads/main""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Set_And_Read_Upstream;

   procedure Unset_Upstream
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Prepare_Repo (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Tracking.Set_Upstream (Repo, "main", "origin", "refs/heads/main");
         Version.Tracking.Unset_Upstream (Repo, "main");
         Assert (not Version.Tracking.Has_Upstream (Repo, "main"),
                 "unset must remove upstream");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Unset_Upstream;

   procedure Rejects_Missing_Remote
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
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "one");

      begin
         Version.Tracking.Set_Upstream
           (Version.Repository.Open, "main", "missing", "refs/heads/main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "set-upstream must reject missing remote");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Rejects_Missing_Remote;

   procedure Clone_Records_Upstream
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source");
      Target : constant String := Version.Test_Support.Join (Root, "target");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Source);
      Configure_User (Source);
      Ada.Directories.Set_Directory (Source);
      Commit_File (Source, "a.txt", "hello" & Character'Val (10), "initial");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Target);

      Ada.Directories.Set_Directory (Target);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Info : constant Version.Tracking.Upstream_Info :=
           Version.Tracking.Upstream (Repo, "main");
      begin
         Assert (To_String (Info.Remote) = "origin", "clone remote mismatch");
         Assert (To_String (Info.Merge) = "refs/heads/main", "clone merge mismatch");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Records_Upstream;

   procedure Ahead_Behind_Counts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Prepare_Repo (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Base_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Tracking.Set_Upstream (Repo, "main", "origin", "refs/heads/main");
         Write_Remote_Tracking (Repo, "origin", "main", Base_Id);

         Commit_File (Root, "a.txt", "two" & Character'Val (10), "two");

         declare
            Counts : constant Version.Tracking.Ahead_Behind :=
              Version.Tracking.Count_Ahead_Behind (Repo, "main");
         begin
            Assert (Counts.Ahead = 1, "ahead count mismatch");
            Assert (Counts.Behind = 0, "behind count mismatch");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ahead_Behind_Counts;

   procedure Diverged_Ahead_Behind_Counts
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Prepare_Repo (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Tracking.Set_Upstream (Repo, "main", "origin", "refs/heads/main");

         Version.Git_Fixtures.Run (Root, "git checkout -b upstream-side");
         Commit_File (Root, "remote.txt", "remote" & Character'Val (10), "remote");

         declare
            Remote_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Git_Fixtures.Run (Root, "git checkout main");
            Commit_File (Root, "local.txt", "local" & Character'Val (10), "local");
            Write_Remote_Tracking (Repo, "origin", "main", Remote_Id);
         end;

         declare
            Counts : constant Version.Tracking.Ahead_Behind :=
              Version.Tracking.Count_Ahead_Behind (Repo, "main");
         begin
            Assert (Counts.Ahead = 1, "diverged ahead count mismatch");
            Assert (Counts.Behind = 1, "diverged behind count mismatch");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diverged_Ahead_Behind_Counts;

   procedure Missing_Upstream_Ref_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Prepare_Repo (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Tracking.Set_Upstream (Repo, "main", "origin", "refs/heads/main");
         begin
            declare
               Counts : constant Version.Tracking.Ahead_Behind :=
                 Version.Tracking.Count_Ahead_Behind (Repo, "main");
               pragma Unreferenced (Counts);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;
      Assert (Raised, "missing upstream ref must be rejected");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Missing_Upstream_Ref_Rejected;

   procedure Branch_Without_Upstream
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "one");

      Assert (not Version.Tracking.Has_Upstream (Version.Repository.Open, "main"),
              "fresh branch must not report upstream");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Without_Upstream;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Set_And_Read_Upstream'Access,
                        "Tracking: set and read upstream");
      Register_Routine (T, Unset_Upstream'Access,
                        "Tracking: unset upstream");
      Register_Routine (T, Rejects_Missing_Remote'Access,
                        "Tracking: rejects missing remote");
      Register_Routine (T, Clone_Records_Upstream'Access,
                        "Tracking: clone records upstream");
      Register_Routine (T, Ahead_Behind_Counts'Access,
                        "Tracking: ahead count");
      Register_Routine (T, Diverged_Ahead_Behind_Counts'Access,
                        "Tracking: diverged ahead/behind count");
      Register_Routine (T, Missing_Upstream_Ref_Rejected'Access,
                        "Tracking: missing upstream ref rejected");
      Register_Routine (T, Branch_Without_Upstream'Access,
                        "Tracking: branch without upstream reports false");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Tracking");
   end Name;

end Version.Tracking.Tests;
