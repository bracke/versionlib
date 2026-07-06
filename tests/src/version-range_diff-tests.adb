with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;
with Version.Write;

package body Version.Range_Diff.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Commit (Root, Name, Content, Message : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Name), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Name);
      Version.Write.Save (Message);
   end Commit;

   procedure Pairs_Unchanged_And_Added
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

      Commit (Root, "b.txt", "base" & LF, "c1");

      Version.Git_Fixtures.Run (Root, "git checkout -q -b old");
      Commit (Root, "x", "1" & LF, "add x");
      Commit (Root, "y", "2" & LF, "add y");

      Version.Git_Fixtures.Run (Root, "git checkout -q -b new main");
      Commit (Root, "x", "1" & LF, "add x");
      Commit (Root, "y", "2" & LF, "add y");
      Commit (Root, "z", "3" & LF, "add z");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         function R (Rev : String) return Version.Objects.Hex_Object_Id is
           (Version.Revisions.Resolve_Commit (Repo, Rev));
         Pairs : constant Version.Range_Diff.Pairing_Vectors.Vector :=
           Version.Range_Diff.Compare
             (Repo, R ("main"), R ("old"), R ("main"), R ("new"));
      begin
         Assert (Natural (Pairs.Length) = 3,
                 "range-diff must report three pairings");
         Assert (Pairs.Element (1).Status = Version.Range_Diff.Unchanged,
                 "first commit is unchanged between ranges");
         Assert (Pairs.Element (2).Status = Version.Range_Diff.Unchanged,
                 "second commit is unchanged between ranges");
         Assert (Pairs.Element (3).Status = Version.Range_Diff.Added,
                 "third commit is added in the new range");
      end;
   end Pairs_Unchanged_And_Added;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Pairs_Unchanged_And_Added'Access,
         "Range_Diff: pairs unchanged commits and flags an added one");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Range_Diff");
   end Name;

end Version.Range_Diff.Tests;
