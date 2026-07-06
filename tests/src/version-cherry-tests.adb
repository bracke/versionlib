with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;
with Version.Write;

package body Version.Cherry.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Configure (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure;

   procedure Marks_Head_Only_Commits
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"), "base" & LF);
      Version.Git_Fixtures.Run (Root, "git add b.txt");
      Version.Write.Save ("c1");

      Version.Git_Fixtures.Run (Root, "git checkout -q -b feature");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("add a");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "c.txt"), "c" & LF);
      Version.Git_Fixtures.Run (Root, "git add c.txt");
      Version.Write.Save ("add c");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Upstream : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "main");
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         St : constant Version.Cherry.Cherry_Vectors.Vector :=
           Version.Cherry.Status (Repo, Upstream, Head);
      begin
         Assert (Natural (St.Length) = 2,
                 "cherry must list the two feature-only commits");
         Assert (not St.Element (1).Equivalent_Upstream
                 and then not St.Element (2).Equivalent_Upstream,
                 "feature-only commits have no upstream equivalent (+)");
      end;
   end Marks_Head_Only_Commits;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Marks_Head_Only_Commits'Access,
         "Cherry: marks head-only commits as not in upstream");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Cherry");
   end Name;

end Version.Cherry.Tests;
