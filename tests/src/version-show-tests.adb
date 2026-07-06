with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Repository;
with Version.Objects;
with Version.Refs;

package body Version.Show.Tests is

   use AUnit.Assertions;

   function Contains (Text : String; Fragment : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Text, Fragment) /= 0;
   end Contains;

   procedure Show_Head_Default
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Text : constant String := Version.Show.Show_Commit (Repo, Head);
      begin
         Assert (Contains (Text, "commit "), "show commit line missing");
         Assert (Contains (Text, "initial"), "show message missing");
         Assert (Contains (Text, "diff --version a/a.txt b/a.txt"), "root patch missing");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Show_Head_Default;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Show_Head_Default'Access, "Show: shows HEAD by default");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Show");
   end Name;

end Version.Show.Tests;
