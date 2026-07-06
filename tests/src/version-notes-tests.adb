with Version.Objects;
with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Notes.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Add_Then_Show_And_Git_Reads
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "1" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c1");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Assert (Version.Notes.Show (Repo, Head) = "",
                 "no note before adding one");
         Version.Notes.Add (Repo, Head, "remember this");
         Assert (Version.Notes.Show (Repo, Head) = "remember this",
                 "show returns the note that was added");
         --  git reads the note we wrote (flat layout).
         Version.Git_Fixtures.Run (Root, "git notes show HEAD");
      end;
   end Add_Then_Show_And_Git_Reads;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Add_Then_Show_And_Git_Reads'Access,
         "Notes: add/show round-trips and git reads the note");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Notes");
   end Name;

end Version.Notes.Tests;
