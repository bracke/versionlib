with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Files.Rollback;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Git_Fixtures;
with Version.Path_Safety;

package body Version.Platform.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Assert_Raises_Data_Error
     (Raised  : Boolean; Message : String) is
   begin
      Assert (Raised, Message);
   end Assert_Raises_Data_Error;

   procedure Join_Normalizes_Separators
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Files.Join ("repo\nested", "dir\file.txt") =
           "repo/nested/dir/file.txt",
         "Join should normalize repository-internal separators to slash");
   end Join_Normalizes_Separators;

   procedure Windows_Reserved_Names_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path
           ("src/CON.txt",
            "checkout path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "Windows device names including extensions must be rejected");
   end Windows_Reserved_Names_Rejected;

   procedure Windows_Invalid_Characters_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path
           ("bad/name?.txt",
            "checkout path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "Windows-invalid characters must be rejected");
   end Windows_Invalid_Characters_Rejected;

   procedure Windows_Trailing_Dot_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path
           ("docs/name.",
            "checkout path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "Windows trailing dots must be rejected");
   end Windows_Trailing_Dot_Rejected;

   procedure Expect_Windows_Path_Rejected
     (Path  : String;
      Label : String)
   is
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Windows_Safe_Relative_Path
           (Path,
            "checkout path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         Label & " must be rejected by Windows path policy");
   end Expect_Windows_Path_Rejected;

   procedure Windows_Drive_And_UNC_Escapes_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Expect_Windows_Path_Rejected ("C:/escape.txt", "drive-root path");
      Expect_Windows_Path_Rejected ("C:\escape.txt", "drive-root backslash path");
      Expect_Windows_Path_Rejected ("C:escape.txt", "drive-relative path");
      Expect_Windows_Path_Rejected ("\\server\share\x", "UNC path");
      Expect_Windows_Path_Rejected ("/absolute.txt", "slash absolute path");
   end Windows_Drive_And_UNC_Escapes_Rejected;

   procedure Windows_Device_Names_Comprehensive_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Expect_Windows_Path_Rejected ("CON", "CON device name");
      Expect_Windows_Path_Rejected ("src/con.txt", "case-folded CON device name with extension");
      Expect_Windows_Path_Rejected ("PRN.log", "PRN device name with extension");
      Expect_Windows_Path_Rejected ("AUX", "AUX device name");
      Expect_Windows_Path_Rejected ("NUL.data", "NUL device name with extension");
      Expect_Windows_Path_Rejected ("COM1", "COM1 device name");
      Expect_Windows_Path_Rejected ("tools/LPT9.txt", "LPT9 device name with extension");
   end Windows_Device_Names_Comprehensive_Rejected;

   procedure Windows_Backslash_Traversal_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Expect_Windows_Path_Rejected ("safe\..\escape.txt", "backslash parent traversal");
      Expect_Windows_Path_Rejected ("safe/..\escape.txt", "mixed-separator parent traversal");
   end Windows_Backslash_Traversal_Rejected;

   procedure Case_Collision_Detected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths  : Version.Path_Safety.Path_Vector;
      Raised : Boolean := False;
   begin
      Paths.Append ("Readme.md");
      Paths.Append ("README.md");

      begin
         Version.Path_Safety.Check_Case_Collisions
           (Paths            => Paths,
            Case_Insensitive => True);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "case-insensitive checkout policy must detect colliding paths");
   end Case_Collision_Detected;

   procedure Case_Collision_Skipped_When_Case_Sensitive
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths : Version.Path_Safety.Path_Vector;
   begin
      Paths.Append ("Readme.md");
      Paths.Append ("README.md");

      Version.Path_Safety.Check_Case_Collisions
        (Paths            => Paths,
         Case_Insensitive => False);
   end Case_Collision_Skipped_When_Case_Sensitive;

   procedure Duplicate_Path_Detected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths  : Version.Path_Safety.Path_Vector;
      Raised : Boolean := False;
   begin
      Paths.Append ("docs/readme.md");
      Paths.Append ("docs/readme.md");

      begin
         Version.Path_Safety.Check_Case_Collisions
           (Paths            => Paths,
            Case_Insensitive => True);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "checkout policy must detect duplicate tree paths before writing");
   end Duplicate_Path_Detected;

   procedure Relative_Path_Normalizes_Backslashes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Path_Safety.Normalize_Relative_Path ("src\nested\file.txt") =
           "src/nested/file.txt",
         "repository-relative path normalization should accept backslash input and store slash paths");
   end Relative_Path_Normalizes_Backslashes;

   procedure With_Directory_Restores_CWD_On_Exception
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old  : constant String := Version.Files.Current_Directory;
      Raised : Boolean := False;

      procedure Fail is
      begin
         raise Ada.IO_Exceptions.Data_Error with "intentional failure";
      end Fail;
   begin
      begin
         Version.Files.With_Directory
           (Path   => Root,
            Action => Fail'Access);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "test action should raise the expected exception");
      Assert
        (Version.Files.Current_Directory = Old,
         "With_Directory must restore the previous current directory when the action fails");
   end With_Directory_Restores_CWD_On_Exception;

   procedure Binary_Bytes_Round_Trip
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Path : constant String := Version.Files.Join (Root, "bytes.bin");
      Data : constant String :=
        "A" & Character'Val (0) & Character'Val (13) & Character'Val (10) &
        Character'Val (255);
   begin
      Version.Files.Write_Binary_File
        (Path    => Path,
         Content => Data);

      Assert
        (Version.Files.Read_Binary_File (Path) = Data,
         "binary IO must preserve NUL, CRLF, LF, and high bytes exactly");
   end Binary_Bytes_Round_Trip;

   procedure Atomic_Replace_Overwrites_Existing_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target : constant String := Version.Files.Join (Root, "target.txt");
      Temp   : constant String := Target & ".lock";
   begin
      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => "old");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");

      Version.Files.Atomic_Replace
        (Source_Temp => Temp,
         Target      => Target);

      Assert
        (Version.Files.Read_Binary_File (Target) = "new",
         "atomic replace must overwrite an existing ordinary file");
      Assert
        (not Ada.Directories.Exists (Temp),
         "atomic replace must consume the temporary file");
   end Atomic_Replace_Overwrites_Existing_File;

   procedure Atomic_Replace_Rejects_Directory_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target : constant String := Version.Files.Join (Root, "target-from-dir.txt");
      Temp   : constant String := Version.Files.Join (Root, "temp-source-dir");
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Path (Temp);

      begin
         Version.Files.Atomic_Replace
           (Source_Temp => Temp,
            Target      => Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "atomic replace must reject directory temp sources");
      Assert
        (not Ada.Directories.Exists (Target),
         "failed atomic replace with directory source must not create target");
   end Atomic_Replace_Rejects_Directory_Source;

   procedure Atomic_Replace_Rejects_Directory_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target   : constant String := Version.Files.Join (Root, "target-dir");
      Sentinel : constant String := Version.Files.Join (Target, "sentinel.txt");
      Temp     : constant String := Version.Files.Join (Root, "target-dir.lock");
      Raised   : Boolean := False;
   begin
      Ada.Directories.Create_Path (Target);
      Version.Files.Write_Binary_File
        (Path    => Sentinel,
         Content => "keep");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");

      begin
         Version.Files.Atomic_Replace
           (Source_Temp => Temp,
            Target      => Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "atomic replace must reject directory targets");
      Assert
        (Ada.Directories.Exists (Sentinel),
         "failed atomic replace must preserve directory target contents");
      Assert
        (Version.Files.Read_Binary_File (Sentinel) = "keep",
         "failed atomic replace must not mutate directory target contents");
      Assert
        (not Ada.Directories.Exists (Temp),
         "failed atomic replace must clean up temporary source file");
   end Atomic_Replace_Rejects_Directory_Target;

   procedure Atomic_Replace_Rollback_Shares_Validation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source_Dir_Target : constant String :=
        Version.Files.Join (Root, "rollback-source-dir-target.txt");
      Source_Dir : constant String :=
        Version.Files.Join (Root, "rollback-source-dir");
      Target_Dir : constant String :=
        Version.Files.Join (Root, "rollback-target-dir");
      Target_Dir_Temp : constant String :=
        Version.Files.Join (Root, "rollback-target-dir.lock");
      Sentinel : constant String := Version.Files.Join (Target_Dir, "sentinel.txt");
      Source_Raised : Boolean := False;
      Target_Raised : Boolean := False;
   begin
      Ada.Directories.Create_Path (Source_Dir);

      begin
         Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
           (Source_Temp => Source_Dir,
            Target      => Source_Dir_Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Source_Raised := True;
      end;

      Assert (Source_Raised, "rollback replace must reject directory sources");
      Assert
        (not Ada.Directories.Exists (Source_Dir_Target),
         "failed rollback replace with directory source must not create target");

      Ada.Directories.Create_Path (Target_Dir);
      Version.Files.Write_Binary_File
        (Path    => Sentinel,
         Content => "keep");
      Version.Files.Write_Binary_File
        (Path    => Target_Dir_Temp,
         Content => "new");

      begin
         Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
           (Source_Temp => Target_Dir_Temp,
            Target      => Target_Dir);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Target_Raised := True;
      end;

      Assert (Target_Raised, "rollback replace must reject directory targets");
      Assert
        (Version.Files.Read_Binary_File (Sentinel) = "keep",
         "failed rollback replace must preserve directory target contents");
      Assert
        (not Ada.Directories.Exists (Target_Dir_Temp),
         "failed rollback replace must clean ordinary temporary source");
   end Atomic_Replace_Rollback_Shares_Validation;

   procedure Atomic_Replace_POSIX_Uses_Direct_Strategy
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target    : constant String := Version.Files.Join (Root, "direct-route.txt");
      Temp      : constant String := Target & ".lock";
      Sidecar   : constant String :=
        Version.Files.Rollback.Rollback_Backup_Path (Target, 1);
      Collision : constant String :=
        Version.Files.Rollback.Rollback_Backup_Path (Target, 2);
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => "old");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");
      Version.Files.Write_Binary_File
        (Path    => Sidecar,
         Content => "user data");

      Version.Files.Atomic_Replace
        (Source_Temp => Temp,
         Target      => Target);

      Assert
        (Version.Files.Read_Binary_File (Target) = "new",
         "POSIX atomic replace must update target through direct strategy");
      --  Direct replacement must not treat pre-existing rollback-looking
      --  sidecars as owned cleanup artifacts.
      Assert
        (Version.Files.Read_Binary_File (Sidecar) = "user data",
         "POSIX direct strategy must preserve unrelated rollback sidecar");
      Assert
        (not Ada.Directories.Exists (Collision),
         "POSIX direct strategy must not allocate rollback collision artifact");
      Assert
        (not Ada.Directories.Exists (Temp),
         "POSIX direct strategy must consume temporary source");
   end Atomic_Replace_POSIX_Uses_Direct_Strategy;

   procedure Atomic_Replace_Preserves_Rollback_Sidecar
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target  : constant String := Version.Files.Join (Root, "target.txt");
      Temp    : constant String := Target & ".lock";
      Sidecar : constant String :=
        Version.Files.Rollback.Rollback_Backup_Path (Target, 1);
   begin
      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => "old");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");
      Version.Files.Write_Binary_File
        (Path    => Sidecar,
         Content => "user data");

      Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
        (Source_Temp => Temp,
         Target      => Target);

      Assert
        (Version.Files.Read_Binary_File (Target) = "new",
         "rollback replace must update target with existing rollback sidecar");
      Assert
        (Version.Files.Read_Binary_File (Sidecar) = "user data",
         "atomic replace must not clobber existing rollback sidecars");
   end Atomic_Replace_Preserves_Rollback_Sidecar;

   procedure Atomic_Replace_Cleans_Collision_Rollback
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target    : constant String := Version.Files.Join (Root, "target-clean.txt");
      Temp      : constant String := Target & ".lock";
      Sidecar   : constant String :=
        Version.Files.Rollback.Rollback_Backup_Path (Target, 1);
      Collision : constant String :=
        Version.Files.Rollback.Rollback_Backup_Path (Target, 2);
   begin
      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => "old");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");
      Version.Files.Write_Binary_File
        (Path    => Sidecar,
         Content => "user data");

      Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
        (Source_Temp => Temp,
         Target      => Target);

      Assert
        (Version.Files.Read_Binary_File (Target) = "new",
         "rollback replace must update target after rollback collision");
      Assert
        (Version.Files.Read_Binary_File (Sidecar) = "user data",
         "atomic replace must preserve pre-existing rollback sidecar");
      Assert
        (not Ada.Directories.Exists (Collision),
         "successful atomic replace must clean collision rollback artifact");
      Assert
        (not Ada.Directories.Exists (Temp),
         "successful atomic replace must consume temporary source");
   end Atomic_Replace_Cleans_Collision_Rollback;

   procedure Atomic_Replace_Rollback_Exhaustion_Preserves_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target : constant String := Version.Files.Join (Root, "target-full.txt");
      Temp   : constant String := Target & ".lock";
      Raised : Boolean := False;
   begin
      Version.Files.Write_Binary_File
        (Path    => Target,
         Content => "old");
      Version.Files.Write_Binary_File
        (Path    => Temp,
         Content => "new");

      for Attempt in 1 .. 1_000 loop
         Version.Files.Write_Binary_File
           (Path    =>
              Version.Files.Rollback.Rollback_Backup_Path (Target, Attempt),
            Content => "occupied" & Natural'Image (Attempt));
      end loop;

      begin
         Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
           (Source_Temp => Temp,
            Target      => Target);
      exception
         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Assert (Raised, "atomic replace must fail when rollback paths are exhausted");
      Assert
        (Version.Files.Read_Binary_File (Target) = "old",
         "rollback exhaustion must preserve existing target");
      Assert
        (not Ada.Directories.Exists (Temp),
         "rollback exhaustion must clean temporary source");

      for Attempt in 1 .. 1_000 loop
         Assert
           (Version.Files.Read_Binary_File
              (Version.Files.Rollback.Rollback_Backup_Path (Target, Attempt))
            = "occupied" & Natural'Image (Attempt),
            "rollback exhaustion must preserve occupied rollback sidecars");
      end loop;
   end Atomic_Replace_Rollback_Exhaustion_Preserves_Target;

   procedure POSIX_Symlink_Parent_Write_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Outside : constant String := Version.Files.Join (Root, "outside");
      Raised  : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Ada.Directories.Create_Path (Outside);
      Version.Git_Fixtures.Run
        (Root,
         "ln -s outside link-dir");

      begin
         Version.Filesystem_Guard.Require_Safe_Write_Target
           (Repo_Root     => Root,
            Relative_Path => "link-dir/escaped.txt");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "POSIX symlink parent must block write preflight");
      Assert
        (not Ada.Directories.Exists
           (Version.Files.Join (Outside, "escaped.txt")),
         "rejected symlink-parent write must not create outside target");
   end POSIX_Symlink_Parent_Write_Rejected;

   procedure POSIX_Symlink_Delete_Removes_Link_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Outside : constant String := Version.Files.Join (Root, "outside.txt");
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Version.Files.Write_Binary_File (Outside, "outside");
      Version.Git_Fixtures.Run
        (Root,
         "ln -s outside.txt link.txt");

      --  Git replaces a tracked symlink by unlinking it: the unlink removes
      --  the link itself and never follows it to the target.
      Version.Files.Remove_File_If_Safe
        (Repo_Root     => Root,
         Relative_Path => "link.txt");

      Assert
        (not Ada.Directories.Exists (Version.Files.Join (Root, "link.txt")),
         "symlink delete must remove the link");
      Assert
        (Ada.Directories.Exists (Outside),
         "symlink delete must not remove the link target");
      Assert
        (Version.Files.Read_Binary_File (Outside) = "outside",
         "symlink delete must preserve target content");
   end POSIX_Symlink_Delete_Removes_Link_Only;

   procedure POSIX_Preflight_Rejects_Symlink_Directory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Ada.Strings.Unbounded;

      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Outside : constant String := Version.Files.Join (Root, "outside");
      Paths   : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Ada.Directories.Create_Path (Outside);
      Version.Git_Fixtures.Run
        (Root,
         "ln -s outside link-dir");
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("link-dir/file.txt"),
            Is_Directory => False,
            Is_Symlink   => False));

      begin
         Version.Filesystem_Guard.Preflight_Checkout
           (Repo_Root => Root,
            Paths     => Paths);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Raises_Data_Error
        (Raised,
         "POSIX checkout preflight must reject symlink directory components");
      Assert
        (not Ada.Directories.Exists
           (Version.Files.Join (Outside, "file.txt")),
         "failed preflight must not materialize a path through the symlink");
   end POSIX_Preflight_Rejects_Symlink_Directory;

   procedure POSIX_Permission_Denied_Atomic_Write_No_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Locked  : constant String := Version.Files.Join (Root, "locked");
      Target  : constant String := Version.Files.Join (Locked, "target.txt");
      Raised  : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Ada.Directories.Create_Path (Locked);
      Version.Files.Write_Binary_File (Target, "old");
      Version.Git_Fixtures.Run (Root, "chmod 0555 locked");

      declare
         Writable : Boolean := False;
      begin
         begin
            Version.Files.Write_Binary_File
              (Version.Files.Join (Locked, ".version-permission-probe"),
               "probe");
            Writable := True;
            Version.Files.Delete_File_If_Exists
              (Version.Files.Join (Locked, ".version-permission-probe"));
         exception
            when others =>
               Writable := False;
         end;

         if Writable then
            Version.Git_Fixtures.Run (Root, "chmod 0755 locked");
            Assert
              (Version.Files.Read_Binary_File (Target) = "old",
               "permission fixture that remains writable must still preserve the original file");
            return;
         end if;
      end;

      begin
         Version.Files.Write_Binary_File_Atomic
           (Path    => Target,
            Content => "new");
      exception
         when others =>
            Raised := True;
      end;

      Version.Git_Fixtures.Run (Root, "chmod 0755 locked");

      Assert
        (Raised,
         "POSIX permission-denied atomic write should fail");
      Assert
        (Version.Files.Read_Binary_File (Target) = "old",
         "failed permission-denied atomic write must preserve original content");
      Assert
        (not Ada.Directories.Exists (Target & ".version-tmp"),
         "failed permission-denied atomic write must not leave temp file");
   exception
      when others =>
         begin
            Version.Git_Fixtures.Run (Root, "chmod 0755 locked");
         exception
            when others =>
               null;
         end;
         raise;
   end POSIX_Permission_Denied_Atomic_Write_No_Mutation;

   procedure Platform_API_Returns_Deterministic_Values
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Kind : constant Version.Platform.Platform_Kind := Version.Platform.Current;
   begin
      Assert
        (Kind in Version.Platform.POSIX_Platform |
                 Version.Platform.Windows_Platform |
                 Version.Platform.Unknown_Platform,
         "platform kind must be a known enumeration value");
      Assert
        (Version.Platform.Native_Path_Separator = '/'
         or else Version.Platform.Native_Path_Separator = '\',
         "native path separator must be slash or backslash");
   end Platform_API_Returns_Deterministic_Values;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Join_Normalizes_Separators'Access,
                        "Platform: join normalizes separators");
      Register_Routine (T, Windows_Reserved_Names_Rejected'Access,
                        "Platform: reject Windows reserved names");
      Register_Routine (T, Windows_Invalid_Characters_Rejected'Access,
                        "Platform: reject Windows invalid chars");
      Register_Routine (T, Windows_Trailing_Dot_Rejected'Access,
                        "Platform: reject Windows trailing dots");
      Register_Routine (T, Windows_Drive_And_UNC_Escapes_Rejected'Access,
                        "Platform: reject Windows drive and UNC escapes");
      Register_Routine (T, Windows_Device_Names_Comprehensive_Rejected'Access,
                        "Platform: reject Windows reserved device variants");
      Register_Routine (T, Windows_Backslash_Traversal_Rejected'Access,
                        "Platform: reject Windows backslash traversal");
      Register_Routine (T, Case_Collision_Detected'Access,
                        "Platform: detect case collision in simulated mode");
      Register_Routine (T, Case_Collision_Skipped_When_Case_Sensitive'Access,
                        "Platform: skip case collision on case-sensitive policy");
      Register_Routine (T, Duplicate_Path_Detected'Access,
                        "Platform: detect duplicate checkout paths");
      Register_Routine (T, Relative_Path_Normalizes_Backslashes'Access,
                        "Platform: normalize relative backslash paths");
      Register_Routine (T, With_Directory_Restores_CWD_On_Exception'Access,
                        "Platform: With_Directory restores cwd on failure");
      Register_Routine (T, Binary_Bytes_Round_Trip'Access,
                        "Platform: CRLF and binary bytes preserved");
      Register_Routine (T, Atomic_Replace_Overwrites_Existing_File'Access,
                        "Platform: atomic replace overwrites existing file");
      Register_Routine (T, Atomic_Replace_Rejects_Directory_Source'Access,
                        "Platform: atomic replace rejects directory source");
      Register_Routine (T, Atomic_Replace_Rejects_Directory_Target'Access,
                        "Platform: atomic replace preserves directory target");
      Register_Routine (T, Atomic_Replace_Rollback_Shares_Validation'Access,
                        "Platform: rollback replace shares validation");
      Register_Routine (T, Atomic_Replace_POSIX_Uses_Direct_Strategy'Access,
                        "Platform: POSIX atomic replace uses direct strategy");
      Register_Routine (T, Atomic_Replace_Preserves_Rollback_Sidecar'Access,
                        "Platform: atomic replace preserves rollback sidecar");
      Register_Routine (T, Atomic_Replace_Cleans_Collision_Rollback'Access,
                        "Platform: atomic replace cleans collision rollback");
      Register_Routine
        (T, Atomic_Replace_Rollback_Exhaustion_Preserves_Target'Access,
         "Platform: atomic replace rollback exhaustion preserves target");
      Register_Routine (T, POSIX_Symlink_Parent_Write_Rejected'Access,
                        "Platform: POSIX symlink parent blocks write");
      Register_Routine (T, POSIX_Symlink_Delete_Removes_Link_Only'Access,
                        "Platform: POSIX symlink delete removes link only");
      Register_Routine (T, POSIX_Preflight_Rejects_Symlink_Directory'Access,
                        "Platform: POSIX preflight rejects symlink directory");
      Register_Routine (T, POSIX_Permission_Denied_Atomic_Write_No_Mutation'Access,
                        "Platform: POSIX permission-denied atomic write preserves file");
      Register_Routine (T, Platform_API_Returns_Deterministic_Values'Access,
                        "Platform: API returns deterministic values");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Platform");
   end Name;

end Version.Platform.Tests;
