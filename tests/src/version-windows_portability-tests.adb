with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Version.Files;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Path_Safety;
with Version.Platform;
with Version.Ref_Names;
with Version.Transport; use Version.Transport;
with Version.Test_Support;

package body Version.Windows_Portability.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   procedure Assert_Data_Error
     (Raised  : Boolean;
      Message : String)
   is
   begin
      Assert (Raised, Message);
   end Assert_Data_Error;

   procedure Drive_Absolute_Recognized
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Platform.Is_Windows_Drive_Path ("C:\Users\me\repo"),
         "backslash Windows drive path must be recognized");
      Assert
        (Version.Platform.Is_Windows_Drive_Path ("D:/work/repo"),
         "slash Windows drive path must be recognized");
      Assert
        (not Version.Platform.Is_Windows_Drive_Path ("host:path"),
         "scp-like remote must not be recognized as a drive path");
      Assert
        (not Version.Platform.Is_Windows_Drive_Path ("C:relative"),
         "drive-relative text is not an absolute drive path helper result");
   end Drive_Absolute_Recognized;

   procedure Backslashes_Normalize
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Path_Safety.Normalize_Relative_Path ("src\main.adb") =
         "src/main.adb",
         "Windows CLI backslashes must normalize to repository slashes");
   end Backslashes_Normalize;

   procedure Duplicate_Separators_Collapse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         declare
            Normalized : constant String :=
              Version.Path_Safety.Normalize_Relative_Path ("src//core\\main.adb");
            pragma Unreferenced (Normalized);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "duplicate separators must be rejected as empty components");
   end Duplicate_Separators_Collapse;

   procedure Reserved_Names_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path ("CON");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "Windows reserved device names must be rejected without extension");
   end Reserved_Names_Rejected;

   procedure Reserved_Names_With_Extensions_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path ("docs/NUL.md");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "Windows reserved device names must be rejected even with extensions");
   end Reserved_Names_With_Extensions_Rejected;

   procedure Invalid_Characters_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path ("src/bad<name.adb");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "Windows-invalid filename characters must be rejected");
   end Invalid_Characters_Rejected;

   procedure Trailing_Dot_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path ("src/name.");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "Windows trailing dot must be rejected");
   end Trailing_Dot_Rejected;

   procedure Trailing_Space_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path ("src/name ");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "Windows trailing space must be rejected");
   end Trailing_Space_Rejected;

   procedure Leading_Backslash_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Result : String := Version.Path_Safety.Normalize_Relative_Path ("\rooted\file.txt");
         pragma Unreferenced (Result);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "leading backslash must be rejected as rooted relative-path escape");
   end Leading_Backslash_Rejected;

   procedure Excessive_Path_Length_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Too_Long : constant String (1 .. 33_000) := [others => 'a'];
      Raised   : Boolean := False;
   begin
      begin
         Version.Files.Require_Reasonable_Path_Length (Too_Long);
      exception
         when Ada.IO_Exceptions.Name_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "excessively long paths must fail clearly instead of truncating");
   end Excessive_Path_Length_Rejected;

   procedure Drive_Path_Not_Ssh
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Detect_Transport ("C:\Users\me\repo") =
         Version.Transport.Local_Transport,
         "backslash drive path must be local, not SSH");
      Assert
        (Version.Transport.Detect_Transport ("C:/Users/me/repo") =
         Version.Transport.Local_Transport,
         "slash drive path must be local, not SSH");
      Assert
        (Version.Transport.Detect_Transport ("C:repo") =
         Version.Transport.Local_Transport,
         "drive-relative path text must remain local, not SSH");
      Assert
        (Version.Transport.Detect_Transport ("user@example.com:repo.git") =
         Version.Transport.Ssh_Transport,
         "scp-like remote must remain SSH");
   end Drive_Path_Not_Ssh;

   procedure Transport_Schemes_Classified
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Detect_Transport ("ssh://example.com/repo.git") =
         Version.Transport.Ssh_Transport,
         "ssh URL must be classified as SSH");
      Assert
        (Version.Transport.Detect_Transport ("file:///C:/Users/me/repo") =
         Version.Transport.Local_Transport,
         "file URL must be classified as local");
      Assert
        (Version.Transport.Detect_Transport ("ftp://example.com/repo.git") =
         Version.Transport.Unsupported_Transport,
         "unknown URI schemes must be rejected");
   end Transport_Schemes_Classified;

   procedure File_Scheme_Strips_Windows_Drive_URI
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Strip_File_Scheme ("file:///C:/Users/me/repo") =
         "C:/Users/me/repo",
         "file:///C:/... must strip to a usable Windows drive path");
      Assert
        (Version.Transport.Strip_File_Scheme ("file://C:/Users/me/repo") =
         "C:/Users/me/repo",
         "file://C:/... must remain a Windows drive path");
      Assert
        (Version.Transport.Strip_File_Scheme ("file:///tmp/repo") =
         "/tmp/repo",
         "POSIX file URLs must keep their absolute leading slash");
      Assert
        (Version.Transport.Strip_File_Scheme ("file:///tmp/repo%20with%20spaces") =
         "/tmp/repo with spaces",
         "file URLs must percent-decode escaped path bytes");
      Assert
        (Version.Transport.Strip_File_Scheme ("file:///tmp/a%2Fb.git") =
         "/tmp/a/b.git",
         "file URLs must percent-decode escaped slash bytes");

      declare
         procedure Assert_Invalid
           (Url      : String;
            Expected : String)
         is
            Raised : Boolean := False;
         begin
            begin
               declare
                  Ignored : constant String :=
                    Version.Transport.Strip_File_Scheme (Url);
               begin
                  pragma Unreferenced (Ignored);
               end;
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Assert
                    (Ada.Exceptions.Exception_Message (E) = Expected,
                     "wrong malformed file URL diagnostic: "
                     & Ada.Exceptions.Exception_Message (E));
            end;

            Assert (Raised, "malformed file URL must raise Data_Error");
         end Assert_Invalid;
      begin
         Assert_Invalid
           ("file:///tmp/repo%GG",
            "invalid percent escape in file URL: file:///tmp/repo%GG");
         Assert_Invalid
           ("file:///tmp/repo%",
            "truncated percent escape in file URL: file:///tmp/repo%");
      end;
   end File_Scheme_Strips_Windows_Drive_URI;

   procedure Case_Collision_Detected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths  : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (True);
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("README.md"),
            Is_Directory => False,
            Is_Symlink   => False));
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("readme.md"),
            Is_Directory => False,
            Is_Symlink   => False));

      begin
         Version.Filesystem_Guard.Require_No_Collisions (Paths);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);

      Assert_Data_Error
        (Raised,
         "case-insensitive Windows checkout policy must reject path collisions");
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         raise;
   end Case_Collision_Detected;

   procedure Gitdir_File_Parses_Windows_Path_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raw : constant String := "gitdir: C:\repo\.git\worktrees\foo";
      Prefix : constant String := "gitdir:";
      Start : Natural := Raw'First + Prefix'Length;
   begin
      while Start <= Raw'Last and then Raw (Start) = ' ' loop
         Start := Start + 1;
      end loop;

      declare
         Text : constant String := Raw (Start .. Raw'Last);
      begin
         Assert
           (Version.Platform.Is_Windows_Drive_Path (Text),
            "gitdir file parser inputs must allow Windows absolute paths");
         Assert
           (Version.Files.Normalize_Separators (Text) =
            "C:/repo/.git/worktrees/foo",
            "Windows gitdir text must normalize without losing the drive prefix");
      end;
   end Gitdir_File_Parses_Windows_Path_Text;

   procedure Filemode_Default_Follows_Executable_Support
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      if Version.Platform.Supports_Executable_Bit then
         Assert
           (Version.Platform.Core_Filemode_Default = "true",
            "POSIX-like platforms should default core.filemode to true");
      else
         Assert
           (Version.Platform.Core_Filemode_Default = "false",
            "Windows-like platforms should default core.filemode to false");
      end if;
   end Filemode_Default_Follows_Executable_Support;

   procedure Central_Directory_Tree_Delete
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Root : constant String :=
        Version.Test_Support.Fresh_Temp_Dir ("windows_delete_tree");
      Dir  : constant String := Version.Files.Join (Root, "subdir");
      File : constant String := Version.Files.Join (Dir, "file.txt");
   begin
      Version.Test_Support.Make_Directory (Dir);
      Version.Test_Support.Write_Text_File (File, "content");

      Version.Files.Delete_Directory_Tree_If_Exists (Dir);
      Assert
        (not Ada.Directories.Exists (Version.Files.To_Native_Path (Dir)),
         "central directory tree delete must remove existing directories");

      Version.Test_Support.Cleanup (Root);
   exception
      when others =>
         Version.Test_Support.Cleanup (Root);
         raise;
   end Central_Directory_Tree_Delete;

   procedure Central_Directory_Tree_Delete_Rejects_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Root   : constant String :=
        Version.Test_Support.Fresh_Temp_Dir ("windows_delete_tree_file");
      Target : constant String := Version.Files.Join (Root, "file.txt");
      Raised : Boolean := False;
   begin
      Version.Test_Support.Write_Text_File (Target, "content");

      begin
         Version.Files.Delete_Directory_Tree_If_Exists (Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "central directory tree delete must reject ordinary file targets");

      Version.Test_Support.Cleanup (Root);
   exception
      when others =>
         Version.Test_Support.Cleanup (Root);
         raise;
   end Central_Directory_Tree_Delete_Rejects_File;

   procedure Ref_Names_Reject_Windows_Filesystem_Components
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Version.Ref_Names.Is_Valid_Branch_Name ("CON"),
         "Windows reserved branch name must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Tag_Name ("docs/NUL.md"),
         "Windows reserved tag component with extension must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Remote_Name ("AUX"),
         "Windows reserved remote name must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Branch_Name ("topic/name."),
         "Windows trailing-dot branch component must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Branch_Name ("topic/bad<name"),
         "Windows-invalid branch filename character must be rejected");
   end Ref_Names_Reject_Windows_Filesystem_Components;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Drive_Absolute_Recognized'Access,
                        "WindowsPath: drive absolute recognized");
      Register_Routine (T, Backslashes_Normalize'Access,
                        "WindowsPath: backslashes normalize");
      Register_Routine (T, Duplicate_Separators_Collapse'Access,
                        "WindowsPath: duplicate separators rejected");
      Register_Routine (T, Reserved_Names_Rejected'Access,
                        "WindowsPath: reserved names rejected");
      Register_Routine (T, Reserved_Names_With_Extensions_Rejected'Access,
                        "WindowsPath: reserved names with extension rejected");
      Register_Routine (T, Invalid_Characters_Rejected'Access,
                        "WindowsPath: invalid chars rejected");
      Register_Routine (T, Trailing_Dot_Rejected'Access,
                        "WindowsPath: trailing dot rejected");
      Register_Routine (T, Trailing_Space_Rejected'Access,
                        "WindowsPath: trailing space rejected");
      Register_Routine (T, Leading_Backslash_Rejected'Access,
                        "WindowsPath: leading backslash rejected");
      Register_Routine (T, Excessive_Path_Length_Rejected'Access,
                        "WindowsPath: excessive path length rejected");
      Register_Routine (T, Drive_Path_Not_Ssh'Access,
                        "WindowsPath: drive path not SSH");
      Register_Routine (T, Transport_Schemes_Classified'Access,
                        "WindowsPath: transport schemes classified");
      Register_Routine (T, File_Scheme_Strips_Windows_Drive_URI'Access,
                        "WindowsPath: file scheme strips Windows drive URI");
      Register_Routine (T, Case_Collision_Detected'Access,
                        "WindowsPath: case collision detected");
      Register_Routine (T, Gitdir_File_Parses_Windows_Path_Text'Access,
                        "WindowsPath: gitdir file parses Windows path");
      Register_Routine (T, Filemode_Default_Follows_Executable_Support'Access,
                        "WindowsPath: filemode default follows platform");
      Register_Routine (T, Central_Directory_Tree_Delete'Access,
                        "WindowsPath: central directory tree delete");
      Register_Routine (T, Central_Directory_Tree_Delete_Rejects_File'Access,
                        "WindowsPath: central directory tree delete rejects file");
      Register_Routine (T, Ref_Names_Reject_Windows_Filesystem_Components'Access,
                        "WindowsPath: ref names reject Windows filesystem components");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Windows_Portability");
   end Name;

end Version.Windows_Portability.Tests;
