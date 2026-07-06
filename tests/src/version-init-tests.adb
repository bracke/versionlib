with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Write;
with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Push;
with Version.Remotes;
with Version.Clone;

package body Version.Init.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Init_Creates_Git_Compatible_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Repo_Path : constant String :=
        Version.Test_Support.Join (Root, "repo");
   begin
      Version.Init.Init (Repo_Path);

      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Repo_Path, ".git")),
         "init must create .git directory");

      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join
              (Version.Test_Support.Join (Repo_Path, ".git"), "objects")),
         "init must create objects directory");

      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join
              (Version.Test_Support.Join
                 (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
               "heads")),
         "init must create refs/heads directory");

      Version.Git_Fixtures.Run
        (Repo_Path,
         "test ""$(cat .git/HEAD)"" = ""ref: refs/heads/main""");

      Version.Git_Fixtures.Run
        (Repo_Path,
         "git fsck --strict");
   end Init_Creates_Git_Compatible_Repository;

   procedure Init_Allows_Version_Save
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Repo_Path : constant String :=
      Version.Test_Support.Join (Root, "save-repo");

      File_Path : constant String :=
      Version.Test_Support.Join (Repo_Path, "a.txt");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Repo_Path);

      Version.Git_Fixtures.Run (Repo_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.name Test");

      Ada.Directories.Set_Directory (Repo_Path);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "native init" & Character'Val (10));

      Version.Git_Fixtures.Run (Repo_Path, "git add a.txt");
      Version.Write.Save ("native init save");

      Version.Git_Fixtures.Run (Repo_Path, "git fsck --strict");
      Version.Git_Fixtures.Run
      (Repo_Path,
         "test ""$(git log -1 --format=%s)"" = ""native init save""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Init_Allows_Version_Save;

   procedure Init_Bare_Creates_Git_Compatible_Repository
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Repo_Path : constant String :=
      Version.Test_Support.Join (Root, "bare.git");
   begin
      Version.Init.Init_Bare (Repo_Path);

      Assert
      (Ada.Directories.Exists
         (Version.Test_Support.Join (Repo_Path, "objects")),
         "bare init must create objects directory");

      Assert
      (Ada.Directories.Exists
         (Version.Test_Support.Join
            (Version.Test_Support.Join (Repo_Path, "refs"), "heads")),
         "bare init must create refs/heads directory");

      Version.Git_Fixtures.Run
      (Repo_Path,
         "test ""$(cat HEAD)"" = ""ref: refs/heads/main""");

      Version.Git_Fixtures.Run
      (Repo_Path,
         "test ""$(git config --bool core.bare)"" = ""true""");

      Version.Git_Fixtures.Run
      (Repo_Path,
         "git fsck --strict");
   end Init_Bare_Creates_Git_Compatible_Repository;

   procedure Init_Bare_Accepts_Version_Push
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Bare_Path : constant String :=
      Version.Test_Support.Join (Root, "remote.git");

      Work_Path : constant String :=
      Version.Test_Support.Join (Root, "work");

      File_Path : constant String :=
      Version.Test_Support.Join (Work_Path, "a.txt");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;
   begin
      Version.Init.Init_Bare (Bare_Path);
      Version.Init.Init (Work_Path);

      Version.Git_Fixtures.Run (Work_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work_Path, "git config user.name Test");

      Ada.Directories.Set_Directory (Work_Path);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "push to bare" & Character'Val (10));

      Version.Git_Fixtures.Run (Work_Path, "git add a.txt");
      Version.Write.Save ("push to bare");

      Version.Remotes.Add_Remote
      (Name => "origin",
         Url  => Bare_Path);

      Version.Push.Push
      (Remote_Name => "origin",
         Branch_Name => "main");

      Version.Git_Fixtures.Run
      (Bare_Path,
         "git fsck --strict");

      Version.Git_Fixtures.Run
      (Bare_Path,
         "test ""$(git log --format=%s -1 main)"" = ""push to bare""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Init_Bare_Accepts_Version_Push;

   procedure Init_Bare_Can_Be_Cloned
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Bare_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-source.git");

      Work_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-work");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-target");

      Work_File : constant String :=
      Version.Test_Support.Join (Work_Path, "a.txt");

      Clone_File : constant String :=
      Version.Test_Support.Join (Clone_Path, "a.txt");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;
   begin
      Version.Init.Init_Bare (Bare_Path);
      Version.Init.Init (Work_Path);

      Version.Git_Fixtures.Run (Work_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work_Path, "git config user.name Test");

      Ada.Directories.Set_Directory (Work_Path);

      Version.Test_Support.Write_Text_File
      (Work_File,
         "push to bare" & Character'Val (10));

      Version.Git_Fixtures.Run (Work_Path, "git add a.txt");
      Version.Write.Save ("push to bare");

      Version.Remotes.Add_Remote
      (Name => "origin",
         Url  => Bare_Path);

      Version.Push.Push
      (Remote_Name => "origin",
         Branch_Name => "main");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Bare_Path,
         Target => Clone_Path);

      Assert
      (Version.Test_Support.Read_Text_File (Clone_File) = "push to bare",
         "clone from native bare repo must restore committed file");

      Version.Git_Fixtures.Run
      (Clone_Path,
         "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Init_Bare_Can_Be_Cloned;
   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Init_Creates_Git_Compatible_Repository'Access,
         "Init: creates Git-compatible repository");

      Register_Routine
         (T,
            Init_Allows_Version_Save'Access,
            "Init: allows Version save");

      Register_Routine
         (T,
            Init_Bare_Creates_Git_Compatible_Repository'Access,
            "Init: creates bare Git-compatible repository");

      Register_Routine
         (T,
            Init_Bare_Accepts_Version_Push'Access,
            "Init: bare repository accepts Version push");

      Register_Routine
         (T,
            Init_Bare_Can_Be_Cloned'Access,
            "Init: bare repository can be cloned");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Init");
   end Name;

end Version.Init.Tests;