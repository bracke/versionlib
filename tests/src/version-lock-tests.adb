with Ada.Directories;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Write;
with Version.Init;

package body Version.Lock.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Init_One_Commit
     (Root      : String;
      File_Path : String)
   is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Version.Write.Save ("one");
   end Init_One_Commit;

   procedure Save_Rejects_Current_Branch_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "refs/heads"),
           "main.lock");

      Raised : Boolean := False;
   begin
      Ada.Directories.Set_Directory (Root);
      Init_One_Commit (Root, File_Path);

      Version.Test_Support.Write_Text_File (Lock_Path, "stale");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      begin
         Version.Write.Save ("two");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "save must reject stale current-branch lock file");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Rejects_Current_Branch_Lock;

   procedure Branch_Create_Rejects_Target_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "refs/heads"),
           "feature.lock");

      Raised : Boolean := False;
   begin
      Ada.Directories.Set_Directory (Root);
      Init_One_Commit (Root, File_Path);

      Version.Test_Support.Write_Text_File (Lock_Path, "stale");

      begin
         Version.Branch.Create_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch create must reject stale target lock file");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Create_Rejects_Target_Lock;

   procedure Branch_Switch_Rejects_HEAD_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Root, ".git"), "HEAD.lock");

      Raised : Boolean := False;
   begin
      Ada.Directories.Set_Directory (Root);
      Init_One_Commit (Root, File_Path);

      Version.Branch.Create_Branch ("feature");
      Version.Test_Support.Write_Text_File (Lock_Path, "stale");

      begin
         Version.Branch.Switch_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch switch must reject stale HEAD lock file");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Switch_Rejects_HEAD_Lock;

   procedure Branch_Update_Rejects_Current_Branch_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "refs/heads"),
           "main.lock");

      Raised : Boolean := False;
   begin
      Ada.Directories.Set_Directory (Root);
      Init_One_Commit (Root, File_Path);

      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("two");

      Version.Branch.Switch_Branch ("main");
      Version.Test_Support.Write_Text_File (Lock_Path, "stale");

      begin
         Version.Branch.Update_Current_Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "branch update must reject stale current-branch lock file");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Update_Rejects_Current_Branch_Lock;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Save_Rejects_Current_Branch_Lock'Access,
         "Lock: save rejects current branch lock");

      Register_Routine
        (T,
         Branch_Create_Rejects_Target_Lock'Access,
         "Lock: branch create rejects target lock");

      Register_Routine
        (T,
         Branch_Switch_Rejects_HEAD_Lock'Access,
         "Lock: branch switch rejects HEAD lock");

      Register_Routine
        (T,
         Branch_Update_Rejects_Current_Branch_Lock'Access,
         "Lock: branch update rejects current branch lock");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Lock");
   end Name;

end Version.Lock.Tests;