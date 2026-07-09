with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Hash;
with Version.Init;
with Version.Repository;
with Version.Write;
with Version.Test_Support;
with Version.Unsupported;
with Version.Git_Fixtures;

package body Version.Repository_Format.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;
   use type Version.Hash.Hash_Algorithm;

   function Join
     (Left  : String;
      Right : String)
      return String renames Version.Test_Support.Join;

   procedure Write_Config
     (Git_Dir : String;
      Content : String)
   is
   begin
      Version.Test_Support.Make_Directory (Git_Dir);
      Version.Test_Support.Write_Text_File (Join (Git_Dir, "config"), Content);
   end Write_Config;

   procedure Assert_Unsupported
     (Git_Dir  : String;
      Expected : String)
   is
   begin
      Version.Repository_Format.Require_Compatible (Git_Dir);
      Assert (False, "expected unsupported repository format: " & Expected);
   exception
      when E : Ada.IO_Exceptions.Data_Error =>
         Assert
           (Ada.Strings.Fixed.Index
              (Ada.Exceptions.Exception_Message (E),
               Expected) /= 0,
            "wrong rejection message: " & Ada.Exceptions.Exception_Message (E));
   end Assert_Unsupported;

   procedure Default_Format_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Version.Test_Support.Make_Directory (Git_Dir);
      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "missing config must default to compatible sha1/files format");
   end Default_Format_Is_Compatible;

   procedure Explicit_Sha1_Files_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 0" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "objectFormat = sha1" & Character'Val (10)
         & Character'Val (9) & "refStorage = files" & Character'Val (10));

      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "explicit sha1/files format must be compatible");
   end Explicit_Sha1_Files_Is_Compatible;

   procedure Repository_Format_Version_Two_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 2" & Character'Val (10));

      Assert_Unsupported (Git_Dir, "unsupported repository format version: 2");
   end Repository_Format_Version_Two_Rejected;

   procedure Repository_Format_Invalid_Numeric_Version_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");

      procedure Assert_Invalid
        (Value    : String;
         Expected : String)
      is
      begin
         Write_Config
           (Git_Dir,
            "[core]" & Character'Val (10)
            & Character'Val (9) & "repositoryformatversion = " & Value
            & Character'Val (10));

         declare
            Ignored : constant Version.Repository_Format.Format_Info :=
              Version.Repository_Format.Read (Git_Dir);
         begin
            pragma Unreferenced (Ignored);
            Assert (False, "invalid repository format version should raise");
         end;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Assert
              (Ada.Exceptions.Exception_Message (E) = Expected,
               "wrong repository format version diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end Assert_Invalid;
   begin
      Assert_Invalid
        ("",
         "repository format version must not be empty");
      Assert_Invalid
        ("abc",
         "invalid repository format version: abc");
      Assert_Invalid
        ("999999999999999999999999",
         "invalid repository format version: 999999999999999999999999");
   end Repository_Format_Invalid_Numeric_Version_Rejected;

   procedure Sha256_Object_Format_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "objectFormat = sha256" & Character'Val (10));

      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "sha256 object-format repositories must now be compatible");
      Assert (Version.Repository_Format.Algorithm (Info) = Version.Hash.Sha256,
              "sha256 config must resolve to the Sha256 algorithm");
   end Sha256_Object_Format_Is_Compatible;

   procedure Reftable_Ref_Storage_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      --  reftable is now a supported ref backend (read via Version.Reftable).
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "refStorage = reftable" & Character'Val (10));

      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "reftable ref-storage repositories must now be compatible");
   end Reftable_Ref_Storage_Is_Compatible;

   procedure Partial_Clone_Format_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "partialClone = origin" & Character'Val (10));

      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "partial clone format metadata must be compatible");
      Assert (To_String (Info.Partial_Clone_Remote) = "origin",
              "partial clone remote must be recorded");
   end Partial_Clone_Format_Is_Compatible;

   procedure Unknown_Extension_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
   begin
      Write_Config
        (Git_Dir,
         "[extensions]" & Character'Val (10)
         & Character'Val (9) & "futureFeature = enabled" & Character'Val (10));

      Assert_Unsupported (Git_Dir, "unsupported repository extension: futureFeature");
   end Unknown_Extension_Rejected;

   procedure Worktree_Config_Repository_Is_Compatible
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "worktreeConfig = true" & Character'Val (10));

      begin
         Version.Repository_Format.Require_Compatible (Git_Dir);
      exception
         when E : others =>
            Assert
              (False,
               "worktreeConfig repository must be compatible, got: "
               & Ada.Exceptions.Exception_Message (E));
      end;
   end Worktree_Config_Repository_Is_Compatible;

   procedure Key_Only_Unknown_Extension_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
   begin
      Write_Config
        (Git_Dir,
         "[extensions]" & Character'Val (10)
         & Character'Val (9) & "futureFeature" & Character'Val (10));

      Assert_Unsupported (Git_Dir, "unsupported repository extension: futureFeature");
   end Key_Only_Unknown_Extension_Rejected;

   procedure Inline_Comments_Do_Not_Break_Supported_Format
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Git_Dir : constant String := Join (Root, ".git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Write_Config
        (Git_Dir,
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 0  # ordinary sha1 repo"
         & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "objectFormat = sha1  ; supported object format"
         & Character'Val (10)
         & Character'Val (9) & "refStorage = files  # loose/packed refs"
         & Character'Val (10));

      Info := Version.Repository_Format.Read (Git_Dir);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "inline config comments must not turn supported values unsupported");
   end Inline_Comments_Do_Not_Break_Supported_Format;

   procedure Bare_Repository_Config_Checked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Bare : constant String := Join (Root, "bare.git");
      Info : Version.Repository_Format.Format_Info;
   begin
      Version.Init.Init_Bare (Bare);
      Info := Version.Repository_Format.Read (Bare);
      Assert (Version.Repository_Format.Is_Supported (Info),
              "bare repository config must be checked as a git-dir config");

      Version.Test_Support.Write_Text_File
        (Join (Bare, "config"),
         "[extensions]" & Character'Val (10)
         & Character'Val (9) & "refStorage = unknownbackend" & Character'Val (10));

      Assert_Unsupported
        (Bare, Version.Unsupported.Ref_Storage ("unknownbackend"));
   end Bare_Repository_Config_Checked;

   procedure Repository_Open_Rejects_Unsupported_Format
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Test_Support.Write_Text_File
        (Join (Join (Root, ".git"), "config"),
         "[extensions]" & Character'Val (10)
         & Character'Val (9) & "refStorage = unknownbackend" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : Version.Repository.Repository_Handle;
      begin
         Repo := Version.Repository.Open;
         Assert (False, "Repository.Open must reject unsupported formats");
         Assert (Version.Repository.Git_Dir (Repo)'Length = 0,
                 "unreachable repository handle use");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Repository_Open_Rejects_Unsupported_Format;

   procedure Assert_Unsupported_Branch_Create_Does_Not_Mutate
     (Root           : String;
      Config_Content : String;
      Expected       : String;
      Context        : String)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Ref_Path : constant String :=
        Join (Join (Join (Join (Root, ".git"), "refs"), "heads"), "feature");
   begin
      Version.Init.Init (Root);
      Version.Test_Support.Write_Text_File
        (Join (Join (Root, ".git"), "config"),
         Config_Content);

      Ada.Directories.Set_Directory (Root);
      begin
         Version.Branch.Create_Branch ("feature");
         Assert
           (False,
            Context & " branch creation must reject before mutation");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E),
                  Expected) /= 0,
               Context & " returned wrong message: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (not Ada.Directories.Exists (Ref_Path),
              Context & " branch attempt must not create a ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Assert_Unsupported_Branch_Create_Does_Not_Mutate;

   procedure Unsupported_Format_Does_Not_Mutate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Assert_Unsupported_Branch_Create_Does_Not_Mutate
        (Root,
         "[extensions]" & Character'Val (10)
         & Character'Val (9) & "refStorage = unknownbackend" & Character'Val (10),
         Version.Unsupported.Ref_Storage ("unknownbackend"),
         "unknown ref-storage repository");
   end Unsupported_Format_Does_Not_Mutate;

   procedure Partial_Clone_Branch_Create_Succeeds
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Ref_Path : constant String :=
        Join (Join (Join (Join (Root, ".git"), "refs"), "heads"), "feature");
   begin
      Version.Init.Init (Root);

      --  Create an initial commit so HEAD is born (git rejects branch
      --  creation on an unborn HEAD, and so does this tool).
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File
        (Join (Root, "a.txt"), "x" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("init");

      Version.Test_Support.Write_Text_File
        (Join (Join (Root, ".git"), "config"),
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "partialClone = origin" & Character'Val (10));

      Version.Branch.Create_Branch ("feature");
      Ada.Directories.Set_Directory (Old_Dir);

      Assert (Ada.Directories.Exists (Ref_Path),
              "partial clone branch creation must create the ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Partial_Clone_Branch_Create_Succeeds;

   procedure Partial_Clone_Merge_Succeeds
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Work_Path : constant String := Join (Root, "a.txt");
      Options : Version.Branch.Merge_Options;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
        (Work_Path, "base" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("base", Run_Hooks => False);
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (Work_Path, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature", Run_Hooks => False);
      Version.Branch.Switch_Branch ("main");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File
        (Join (Join (Root, ".git"), "config"),
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "partialClone = origin" & Character'Val (10)
         & "[user]" & Character'Val (10)
         & Character'Val (9) & "email = test@example.com" & Character'Val (10)
         & Character'Val (9) & "name = Test" & Character'Val (10));

      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Ada.Directories.Set_Directory (Root);
      Version.Branch.Merge ("feature", Options);
      Ada.Directories.Set_Directory (Old_Dir);

      Assert (Version.Test_Support.Read_Text_File (Work_Path) = "feature",
              "partial clone merge must materialize the target content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Partial_Clone_Merge_Succeeds;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Default_Format_Is_Compatible'Access,
                        "RepositoryFormat: default format is compatible");
      Register_Routine (T, Explicit_Sha1_Files_Is_Compatible'Access,
                        "RepositoryFormat: explicit sha1 files compatible");
      Register_Routine (T, Repository_Format_Version_Two_Rejected'Access,
                        "RepositoryFormat: repositoryformatversion 2 rejected");
      Register_Routine
        (T,
         Repository_Format_Invalid_Numeric_Version_Rejected'Access,
         "RepositoryFormat: invalid repositoryformatversion rejected");
      Register_Routine (T, Sha256_Object_Format_Is_Compatible'Access,
                        "RepositoryFormat: sha256 object format is compatible");
      Register_Routine (T, Reftable_Ref_Storage_Is_Compatible'Access,
                        "RepositoryFormat: reftable ref storage compatible");
      Register_Routine (T, Partial_Clone_Format_Is_Compatible'Access,
                        "RepositoryFormat: partialClone format is compatible");
      Register_Routine (T, Unknown_Extension_Rejected'Access,
                        "RepositoryFormat: unknown extension rejected");
      Register_Routine (T, Worktree_Config_Repository_Is_Compatible'Access,
                        "RepositoryFormat: worktreeConfig repository is compatible");
      Register_Routine (T, Key_Only_Unknown_Extension_Rejected'Access,
                        "RepositoryFormat: key-only unknown extension rejected");
      Register_Routine (T, Inline_Comments_Do_Not_Break_Supported_Format'Access,
                        "RepositoryFormat: inline comments preserve supported values");
      Register_Routine (T, Bare_Repository_Config_Checked'Access,
                        "RepositoryFormat: bare repo format checked");
      Register_Routine (T, Repository_Open_Rejects_Unsupported_Format'Access,
                        "RepositoryFormat: Repository.Open rejects unsupported format");
      Register_Routine (T, Unsupported_Format_Does_Not_Mutate'Access,
                        "RepositoryFormat: unsupported repo does not mutate");
      Register_Routine
        (T,
         Partial_Clone_Branch_Create_Succeeds'Access,
         "RepositoryFormat: partialClone branch create succeeds");
      Register_Routine
        (T,
         Partial_Clone_Merge_Succeeds'Access,
         "RepositoryFormat: partialClone merge succeeds");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Repository_Format");
   end Name;

end Version.Repository_Format.Tests;
