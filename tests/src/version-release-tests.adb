with Ada.Directories;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;


with Version.Branch;
with Version.Clone;
with Version.Git_Fixtures;
with Version.Init;
with Version.Path_Safety;
with Version.Test_Support;
with Version.Transport;
with Version.Write;

package body Version.Release.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Root_Of (T : in out AUnit.Test_Cases.Test_Case'Class) return String
   is
   begin
      return Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   end Root_Of;

   procedure Configure_Git_Identity (Root : String) is
   begin
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Git_Identity;

   procedure Save_From_Index (Root : String; Message : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save (Message);
      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Save_From_Index;

   procedure Assert_Data_Error
     (Action : not null access procedure; Message : String)
   is
      Raised : Boolean := False;
   begin
      begin
         Action.all;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, Message);
   end Assert_Data_Error;

   procedure Release_Native_Init_Save_Git_Fsck
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Root_Of (T);
   begin
      Version.Init.Init (Root);
      Configure_Git_Identity (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "release" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Save_From_Index (Root, "release-native-save");

      Version.Git_Fixtures.Run (Root, "git rev-parse --verify HEAD");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "test ""$(git log --format=%s -1)"" = ""release-native-save""");
   end Release_Native_Init_Save_Git_Fsck;

   procedure Release_Git_Init_Version_Save_Git_Fsck
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Root_Of (T);
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Configure_Git_Identity (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "git-created.txt"),
         "git repo" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add git-created.txt");

      Save_From_Index (Root, "version-save-in-git-repo");

      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git ls-tree -r --name-only HEAD)"" = ""git-created.txt""");
   end Release_Git_Init_Version_Save_Git_Fsck;

   procedure Release_Local_Clone_Is_Git_Readable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Root_Of (T);
      Source : constant String := Version.Test_Support.Join (Root, "source");
      Target : constant String := Version.Test_Support.Join (Root, "target");
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);

      Version.Clone.Clone (Source => Source, Target => Target);

      Version.Git_Fixtures.Run (Target, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Target, "test ""$(git log --format=%s -1)"" = ""initial""");
   end Release_Local_Clone_Is_Git_Readable;

   procedure Release_File_Clone_Is_Git_Readable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String := Root_Of (T);
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-file");
      Target : constant String :=
        Version.Test_Support.Join (Root, "target-file");
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);

      Version.Clone.Clone (Source => "file://" & Source, Target => Target);

      Version.Git_Fixtures.Run (Target, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Target, "test ""$(git status --porcelain)"" = """"");
   end Release_File_Clone_Is_Git_Readable;

   procedure Release_Branch_Switch_Round_Trip_Clean
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Root_Of (T);
      File_A  : constant String := Version.Test_Support.Join (Root, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_Git_Identity (Root);

      Version.Test_Support.Write_Text_File
        (File_A, "main" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Save_From_Index (Root, "main-base");

      Ada.Directories.Set_Directory (Root);
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Version.Test_Support.Write_Text_File
        (File_A, "feature" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("feature-change");
      Version.Branch.Switch_Branch ("main");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "test ""$(git status --porcelain)"" = """"");
      Version.Git_Fixtures.Run (Root, "test ""$(cat a.txt)"" = ""main""");

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Release_Branch_Switch_Round_Trip_Clean;

   procedure Release_Hostile_Path_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Safe_Relative_Path ("../escape.txt");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "release safety must reject traversal paths");
   end Release_Hostile_Path_Rejected;

   procedure Release_Unknown_Transport_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Transport.Require_Supported_Url
           ("ftp://example.invalid/repo.git");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "unknown transport schemes must fail deterministically");
   end Release_Unknown_Transport_Rejected;


   procedure Release_Scp_Like_Ssh_Is_Supported_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Version.Transport.Require_Supported_Url ("git@example.invalid:repo.git");
      Version.Transport.Require_Supported_Url ("example.invalid:repo.git");
   end Release_Scp_Like_Ssh_Is_Supported_Url;

   procedure Release_File_Scheme_Strips_To_Local_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Strip_File_Scheme ("file:///tmp/repo.git")
         = "/tmp/repo.git",
         "file:// release paths must strip to a local path deterministically");
   end Release_File_Scheme_Strips_To_Local_Path;

   procedure Release_Binary_File_Round_Trip_Exact
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Root_Of (T);
   begin
      Version.Init.Init (Root);
      Configure_Git_Identity (Root);

      Version.Git_Fixtures.Run
        (Root,
         "printf '\000\001\002\003\004\005\376\377binary\015\012' > bytes.bin");
      Version.Git_Fixtures.Run (Root, "git add bytes.bin");

      Save_From_Index (Root, "binary-release-round-trip");

      Version.Git_Fixtures.Run
        (Root, "git show HEAD:bytes.bin > from-commit.bin");
      Version.Git_Fixtures.Run (Root, "cmp bytes.bin from-commit.bin");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
   end Release_Binary_File_Round_Trip_Exact;

   procedure Release_Corrupt_Head_Rejects_Save
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Root_Of (T);
      Head    : constant String :=
        Version.Test_Support.Join (Root, ".git/HEAD");
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Save_With_Corrupt_Head is
      begin
         Ada.Directories.Set_Directory (Root);
         Version.Write.Save ("must-not-write-ref");
      end Save_With_Corrupt_Head;
   begin
      Version.Init.Init (Root);
      Configure_Git_Identity (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "corrupt-head.txt"),
         "content" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add corrupt-head.txt");
      Version.Test_Support.Write_Text_File
        (Head, "ref: refs/heads/../escape" & Character'Val (10));

      Assert_Data_Error
        (Save_With_Corrupt_Head'Access,
         "corrupt HEAD ref must reject save before ref writes");

      if Ada.Directories.Current_Directory /= Old_Dir then
         Ada.Directories.Set_Directory (Old_Dir);
      end if;

   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Release_Corrupt_Head_Rejects_Save;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Release_Native_Init_Save_Git_Fsck'Access,
         "Release: native init + save + git fsck");

      Register_Routine
        (T,
         Release_Git_Init_Version_Save_Git_Fsck'Access,
         "Release: Git init + Version save + git fsck");

      Register_Routine
        (T,
         Release_Local_Clone_Is_Git_Readable'Access,
         "Release: local clone is Git-readable");

      Register_Routine
        (T,
         Release_File_Clone_Is_Git_Readable'Access,
         "Release: file:// clone is Git-readable");

      Register_Routine
        (T,
         Release_Branch_Switch_Round_Trip_Clean'Access,
         "Release: branch switch round trip has clean Git status");

      Register_Routine
        (T,
         Release_Hostile_Path_Rejected'Access,
         "Release: hostile path rejected");

      Register_Routine
        (T,
         Release_Binary_File_Round_Trip_Exact'Access,
         "Release: binary file round-trips exact bytes");

      Register_Routine
        (T,
         Release_Unknown_Transport_Rejected'Access,
         "Release: unknown transport rejected");


      Register_Routine
        (T,
         Release_Scp_Like_Ssh_Is_Supported_Url'Access,
         "Release: scp-like SSH URL is supported");

      Register_Routine
        (T,
         Release_File_Scheme_Strips_To_Local_Path'Access,
         "Release: file:// scheme strips to local path");

      Register_Routine
        (T,
         Release_Corrupt_Head_Rejects_Save'Access,
         "Release: corrupt HEAD rejects save before ref write");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Release");
   end Name;

end Version.Release.Tests;
