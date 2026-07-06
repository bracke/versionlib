with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Text;
with Project_Tools.Release_Checks;

--  Guard versionlib's functionality test scope: the release-critical AUnit
--  suites must remain present and registered, and the registered-routine count
--  must stay above a closure floor. Scans versionlib's own tests/.
procedure Check_Test_Scope_Completeness is
   Suite_File : constant String := "tests/src/version_suite.adb";
   Floor      : constant Natural := 1000;

   procedure Require_Suite (Suite : String) is
   begin
      Project_Tools.Files.Require_Contains
        (Suite_File, "with " & Suite & ";",
         "versionlib suite missing with-clause for " & Suite);
      Project_Tools.Files.Require_Contains
        (Suite_File, "new " & Suite & ".Test_Case",
         "versionlib suite does not register " & Suite);
   end Require_Suite;

   procedure Count_In_Tree (Directory : String; Count : in out Natural) is
      Search : Ada.Directories.Search_Type;
   begin
      Ada.Directories.Start_Search
        (Search, Directory, "",
         [Ada.Directories.Ordinary_File => True,
          Ada.Directories.Directory     => True,
          others                        => False]);
      while Ada.Directories.More_Entries (Search) loop
         declare
            Item : Ada.Directories.Directory_Entry_Type;
         begin
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Simple : constant String := Ada.Directories.Simple_Name (Item);
               Full   : constant String :=
                 Project_Tools.Files.Join (Directory, Simple);
            begin
               if Simple /= "." and then Simple /= ".." then
                  case Ada.Directories.Kind (Item) is
                     when Ada.Directories.Ordinary_File =>
                        Count := Count + Project_Tools.Text.Count
                          (Project_Tools.Files.Read_Raw_File (Full),
                           "Register_Routine");
                     when Ada.Directories.Directory =>
                        Count_In_Tree (Full, Count);
                     when others =>
                        null;
                  end case;
               end if;
            end;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Count_In_Tree;

   Routines : Natural := 0;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_test_scope_completeness");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Project_Tools.Files.Require_File
     (Suite_File, "versionlib test suite registry missing: " & Suite_File);

   --  Release-critical functionality suites.
   Require_Suite ("Version.Objects.Tests");
   Require_Suite ("Version.Refs.Tests");
   Require_Suite ("Version.Ref_Transaction.Tests");
   Require_Suite ("Version.Repository_Format.Tests");
   Require_Suite ("Version.Merge.Tests");
   Require_Suite ("Version.Diff.Tests");
   Require_Suite ("Version.Pack_Write.Tests");
   Require_Suite ("Version.Packed_Refs.Tests");
   Require_Suite ("Version.Transport.Http.Tests");
   Require_Suite ("Version.Transport.Ssh.Tests");
   Require_Suite ("Version.Archive.Tests");
   Require_Suite ("Version.Submodules.Tests");
   Require_Suite ("Version.Worktrees.Tests");
   Require_Suite ("Version.Status.Tests");
   Require_Suite ("Version.Restore.Tests");

   Count_In_Tree ("tests/src", Routines);
   if Routines < Floor then
      Project_Tools.Release_Checks.Fail
        ("registered AUnit routine count below closure floor:"
         & Natural'Image (Routines));
   end if;

   Ada.Text_IO.Put_Line
     ("test-scope completeness checks passed (" & Natural'Image (Routines)
      & " routines)");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;  -- a Require_* / Fail already set the failure exit status
end Check_Test_Scope_Completeness;
