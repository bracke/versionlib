with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Write;
with Version.Init;

package body Version.Remove.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Remove_Tracked_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "hello" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("initial");

      Version.Remove.Remove_Path ("a.txt");

      Assert
      (not Ada.Directories.Exists (File_Path),
         "remove must delete working tree file");

      Version.Git_Fixtures.Run
      (Root,
         "git diff --cached --quiet --exit-code -- a.txt; test $? -eq 1");

      Version.Git_Fixtures.Run
      (Root,
         "git diff --cached --name-only -- a.txt | test ""$(cat)"" = ""a.txt""");

      Version.Write.Save ("remove a.txt");

      Version.Git_Fixtures.Run
      (Root,
         "git fsck --strict");

      Version.Git_Fixtures.Run
      (Root,
         "test -z ""$(git ls-tree -r --name-only HEAD | grep '^a.txt$')""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remove_Tracked_File;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Remove_Tracked_File'Access,
         "Remove: tracked file removed from index and working tree");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Remove");
   end Name;

end Version.Remove.Tests;