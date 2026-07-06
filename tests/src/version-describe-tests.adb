with Version.Objects;
with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;
with Version.Write;

package body Version.Describe.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Names_Relative_To_Tag
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
      Version.Git_Fixtures.Run (Root, "git tag v1");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "2" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c2");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         At_Tag : constant String :=
           Version.Describe.Describe
             (Repo, Version.Revisions.Resolve_Commit (Repo, "v1"));
         At_Head : constant String :=
           Version.Describe.Describe
             (Repo, Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo)));
      begin
         Assert (At_Tag = "v1", "an exactly-tagged commit describes as the tag");
         Assert (At_Head'Length > 6
                 and then At_Head (At_Head'First .. At_Head'First + 4) = "v1-1-"
                 and then Ada.Strings.Fixed.Index (At_Head, "-g") /= 0,
                 "one commit past the tag describes as v1-1-g<short>");
      end;
   end Names_Relative_To_Tag;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Names_Relative_To_Tag'Access,
         "Describe: names a commit relative to the nearest tag");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Describe");
   end Name;

end Version.Describe.Tests;
