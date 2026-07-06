with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Grep.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Finds_Matches
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
        (Version.Test_Support.Join (Root, "f.txt"), "alpha" & LF & "beta" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "g.txt"), "gamma" & LF);
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Write.Save ("c1");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Hits : constant Version.Grep.Match_Vectors.Vector :=
           Version.Grep.Search (Repo, "beta");
         CI   : constant Version.Grep.Match_Vectors.Vector :=
           Version.Grep.Search (Repo, "BETA", Ignore_Case => True);
         None : constant Version.Grep.Match_Vectors.Vector :=
           Version.Grep.Search (Repo, "zzz");
      begin
         Assert (Natural (Hits.Length) = 1, "exactly one line matches 'beta'");
         Assert (To_String (Hits.Element (1).Path) = "f.txt"
                 and then Hits.Element (1).Line_No = 2
                 and then To_String (Hits.Element (1).Text) = "beta",
                 "match reports path, line number, and text");
         Assert (Natural (CI.Length) = 1, "case-insensitive search matches");
         Assert (None.Is_Empty, "no match for an absent pattern");
      end;
   end Finds_Matches;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Finds_Matches'Access, "Grep: finds matching lines in tracked files");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Grep");
   end Name;

end Version.Grep.Tests;
