with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;

package body Version.Show_Branch.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := ASCII.LF;

   --  main and feature diverge two commits above a shared base; git names the
   --  merge base off the newest tip (feature) regardless of argument order.
   procedure Matrix_And_Naming_Match_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@t");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run
        (Root,
         "t=1000000000; "
         & "cm() { echo $1 >> f; git add f; "
         & "GIT_AUTHOR_DATE=""$t +0000"" GIT_COMMITTER_DATE=""$t +0000"" "
         & "git commit -q -m ""$1""; t=$((t+60)); }; "
         & "cm base1; cm base2; git checkout -q -b feature; cm feat3; "
         & "cm feat4; git checkout -q main; cm main3; cm main4");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Branches : Version.Show_Branch.Name_Vectors.Vector;
         --  main is the newest tip here, so it names the shared base (main~2).
         Expected : constant String :=
           "* [main] main4" & LF
           & " ! [feature] feat4" & LF
           & "--" & LF
           & "*  [main] main4" & LF
           & "*  [main^] main3" & LF
           & " + [feature] feat4" & LF
           & " + [feature^] feat3" & LF
           & "*+ [main~2] base2" & LF;
      begin
         Branches.Append ("main");
         Branches.Append ("feature");
         Assert
           (Version.Show_Branch.Format (Repo, Branches) = Expected,
            "show-branch matrix must match git" & LF & "got:" & LF
            & Version.Show_Branch.Format (Repo, Branches));

         --  --list is the head list with the current branch starred.
         Assert
           (Version.Show_Branch.Format (Repo, Branches, List_Only => True)
            = "* [main] main4" & LF & "  [feature] feat4" & LF,
            "show-branch --list must match git");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Matrix_And_Naming_Match_Git;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Matrix_And_Naming_Match_Git'Access,
         "Show_Branch: matrix, first-parent naming, and --list match git");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Show_Branch");
   end Name;

end Version.Show_Branch.Tests;
