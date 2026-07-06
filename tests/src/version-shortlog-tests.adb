with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Shortlog.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Groups_By_Author
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Git_Fixtures.Run (Root, "git config user.name Alice");
      Version.Git_Fixtures.Run (Root, "git config user.email a@x");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "1" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c1");

      Version.Git_Fixtures.Run (Root, "git config user.name Bob");
      Version.Git_Fixtures.Run (Root, "git config user.email b@x");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "2" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c2");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Groups : constant Version.Shortlog.Group_Vectors.Vector :=
           Version.Shortlog.Summarize
             (Repo, Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo)));
      begin
         Assert (Natural (Groups.Length) = 2,
                 "two authors must yield two groups");
         Assert (To_String (Groups.Element (1).Name) = "Alice",
                 "groups are sorted by author name");
         Assert (Natural (Groups.Element (1).Subjects.Length) = 1
                 and then Natural (Groups.Element (2).Subjects.Length) = 1,
                 "each author has one commit");
      end;
   end Groups_By_Author;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Groups_By_Author'Access,
         "Shortlog: groups commits by author");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Shortlog");
   end Name;

end Version.Shortlog.Tests;
