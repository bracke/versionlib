with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Test_Support;

package body Version.Show_Branch.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := ASCII.LF;

   --  Raw bytes -- git's output keeps its trailing newline, which Format also
   --  emits, so the text reader's newline trimming must not intervene.
   function File_Text (Root, Name : String) return String is
     (Version.Files.Read_Binary_File
        (Version.Test_Support.Join (Root, Name)));

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

      --  Capture real git's output on this very fixture as the oracle -- the
      --  matrix order and the merge-base naming both depend on whether the
      --  commits share a committer date, so a hand-copied string would only
      --  match git by luck.
      Version.Git_Fixtures.Run
        (Root, "git show-branch main feature > sb.txt");
      Version.Git_Fixtures.Run
        (Root, "git show-branch --list main feature > sblist.txt");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Branches : Version.Show_Branch.Name_Vectors.Vector;
      begin
         Branches.Append ("main");
         Branches.Append ("feature");
         Assert
           (Version.Show_Branch.Format (Repo, Branches)
            = File_Text (Root, "sb.txt"),
            "show-branch matrix must match git" & LF & "got:" & LF
            & Version.Show_Branch.Format (Repo, Branches)
            & "want:" & LF & File_Text (Root, "sb.txt"));

         Assert
           (Version.Show_Branch.Format (Repo, Branches, List_Only => True)
            = File_Text (Root, "sblist.txt"),
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
