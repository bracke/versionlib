with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Test_Support;

package body Version.Filesystem_Guard.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Join
     (Left  : String;
      Right : String)
      return String renames Version.Test_Support.Join;

   procedure Expect_Data_Error
     (Action_Name : String;
      Action      : not null access procedure;
      Contains    : String)
   is
   begin
      Action.all;
      Assert (False, "expected Data_Error from " & Action_Name);
   exception
      when E : Ada.IO_Exceptions.Data_Error =>
         Assert
           (Ada.Strings.Fixed.Index
              (Ada.Exceptions.Exception_Message (E), Contains) /= 0,
            "wrong Data_Error for " & Action_Name & ": "
            & Ada.Exceptions.Exception_Message (E));
   end Expect_Data_Error;

   procedure Detects_Exact_Duplicate_Planned_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_No_Collisions (Paths);
      end Run;
   begin
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("a.txt"),
            Is_Directory => False,
            Is_Symlink   => False));
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("a.txt"),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error ("duplicate planned paths", Run'Access, "path collision");
   end Detects_Exact_Duplicate_Planned_Paths;

   procedure Detects_Forced_Case_Insensitive_Collision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_No_Collisions (Paths);
      end Run;
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
      Expect_Data_Error ("case collision", Run'Access, "path case collision");
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         raise;
   end Detects_Forced_Case_Insensitive_Collision;

   function UTF8_Composed_E_Acute_Path return String is
   begin
      return "caf"
        & Character'Val (16#C3#)
        & Character'Val (16#A9#)
        & ".txt";
   end UTF8_Composed_E_Acute_Path;

   function UTF8_Decomposed_E_Acute_Path return String is
   begin
      return "cafe"
        & Character'Val (16#CC#)
        & Character'Val (16#81#)
        & ".txt";
   end UTF8_Decomposed_E_Acute_Path;

   procedure Detects_UTF8_Composed_Decomposed_Collision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_No_Collisions (Paths);
      end Run;
   begin
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (True);
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String (UTF8_Composed_E_Acute_Path),
            Is_Directory => False,
            Is_Symlink   => False));
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String (UTF8_Decomposed_E_Acute_Path),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error
        ("UTF-8 composed/decomposed collision",
         Run'Access,
         "path case collision");
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         raise;
   end Detects_UTF8_Composed_Decomposed_Collision;

   procedure Detects_Submodule_Directory_Case_Collision_With_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_No_Collisions (Paths);
      end Run;
   begin
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (True);
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("vendor/Lib"),
            Is_Directory => True,
            Is_Symlink   => False));
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("vendor/lib"),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error
        ("submodule directory/file case collision",
         Run'Access,
         "path case collision");
      Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
   exception
      when others =>
         Version.Filesystem_Guard.Set_Force_Case_Insensitive (False);
         raise;
   end Detects_Submodule_Directory_Case_Collision_With_File;

   procedure Detects_File_Blocks_Planned_Directory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Preflight_Checkout (Root, Paths);
      end Run;
   begin
      Version.Test_Support.Write_Text_File (Join (Root, "src"), "not a dir");
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("src/main.adb"),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error ("file blocks directory", Run'Access, "file blocks planned directory");
   end Detects_File_Blocks_Planned_Directory;

   procedure Detects_Directory_Blocks_Planned_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      procedure Run is
      begin
         Version.Filesystem_Guard.Preflight_Checkout (Root, Paths);
      end Run;
   begin
      Version.Test_Support.Make_Directory (Join (Root, "src"));
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("src"),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error ("directory blocks file", Run'Access, "directory blocks planned file");
   end Detects_Directory_Blocks_Planned_File;

   procedure Rejects_Delete_Inside_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_Safe_Delete_Target (Root, ".git/config");
      end Run;
   begin
      Expect_Data_Error ("delete inside git", Run'Access, "paths inside .git");
   end Rejects_Delete_Inside_Git;

   procedure Rejects_Delete_Of_Directory_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_Safe_Delete_Target (Root, "src");
      end Run;
   begin
      Version.Test_Support.Make_Directory (Join (Root, "src"));
      Expect_Data_Error ("delete directory", Run'Access, "unsafe delete target");
   end Rejects_Delete_Of_Directory_Target;

   procedure Rejects_Write_Inside_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      procedure Run is
      begin
         Version.Filesystem_Guard.Require_Safe_Write_Target (Root, ".git/config");
      end Run;
   begin
      Expect_Data_Error ("write inside git", Run'Access, "paths inside .git");
   end Rejects_Write_Inside_Git;

   procedure Preflight_Fails_Before_Writing_Any_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Paths : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      Planned_Output : constant String := Join (Join (Root, "src"), "main.adb");
      procedure Run is
      begin
         Version.Filesystem_Guard.Preflight_Checkout (Root, Paths);
      end Run;
   begin
      Version.Test_Support.Write_Text_File (Join (Root, "src"), "not a dir");
      Paths.Append
        (Planned_Path'
           (Path         => To_Unbounded_String ("src/main.adb"),
            Is_Directory => False,
            Is_Symlink   => False));
      Expect_Data_Error ("preflight before write", Run'Access, "file blocks planned directory");
      Assert (not Ada.Directories.Exists (Planned_Output),
              "preflight failure must not write target file");
   end Preflight_Fails_Before_Writing_Any_File;

   procedure Atomic_Write_Cleans_Temp_On_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target_Dir : constant String := Join (Root, "blocked");
      Target     : constant String := Join (Target_Dir, "out.txt");
      Temp       : constant String := Target & ".version-tmp";
      procedure Run is
      begin
         Version.Files.Write_Binary_File_Atomic (Target, "data");
      end Run;
   begin
      Version.Test_Support.Write_Text_File (Target_Dir, "not a dir");
      Expect_Data_Error ("atomic write failure", Run'Access, "path exists but is not a directory");
      Assert (not Ada.Directories.Exists (Temp),
              "failed atomic write must not leave temp file");
   end Atomic_Write_Cleans_Temp_On_Failure;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Detects_Exact_Duplicate_Planned_Paths'Access,
                        "FilesystemGuard: detects exact duplicate planned paths");
      Register_Routine (T, Detects_Forced_Case_Insensitive_Collision'Access,
                        "FilesystemGuard: detects forced case-insensitive collision");
      Register_Routine (T, Detects_UTF8_Composed_Decomposed_Collision'Access,
                        "FilesystemGuard: detects UTF-8 normalization collision");
      Register_Routine (T, Detects_Submodule_Directory_Case_Collision_With_File'Access,
                        "FilesystemGuard: detects submodule directory/file case collision");
      Register_Routine (T, Detects_File_Blocks_Planned_Directory'Access,
                        "FilesystemGuard: detects file blocks planned directory");
      Register_Routine (T, Detects_Directory_Blocks_Planned_File'Access,
                        "FilesystemGuard: detects directory blocks planned file");
      Register_Routine (T, Rejects_Delete_Inside_Git'Access,
                        "FilesystemGuard: rejects delete inside .git");
      Register_Routine (T, Rejects_Delete_Of_Directory_Target'Access,
                        "FilesystemGuard: rejects delete of directory target");
      Register_Routine (T, Rejects_Write_Inside_Git'Access,
                        "FilesystemGuard: rejects write inside .git");
      Register_Routine (T, Preflight_Fails_Before_Writing_Any_File'Access,
                        "FilesystemGuard: checkout preflight fails before writing any file");
      Register_Routine (T, Atomic_Write_Cleans_Temp_On_Failure'Access,
                        "FilesystemGuard: atomic write cleans temp on failure");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Filesystem_Guard");
   end Name;

end Version.Filesystem_Guard.Tests;
