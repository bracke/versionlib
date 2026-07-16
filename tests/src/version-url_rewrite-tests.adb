with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;

package body Version.Url_Rewrite.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Rewrites_By_InsteadOf
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);
      --  Two overlapping insteadOf prefixes: the longer must win. A separate
      --  pushInsteadOf takes precedence for push URLs.
      Version.Git_Fixtures.Run
        (Root, "git config ""url.https://host/.insteadof"" gh:");
      Version.Git_Fixtures.Run
        (Root, "git config ""url.https://host/team/.insteadof"" gh:team/");
      Version.Git_Fixtures.Run
        (Root, "git config ""url.git@host:.pushinsteadof"" gh:");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Url_Rewrite.Rewrite (Repo, "gh:team/repo")
              = "https://host/team/repo",
            "the longest matching insteadOf prefix wins");
         Assert
           (Version.Url_Rewrite.Rewrite (Repo, "gh:other")
              = "https://host/other",
            "a shorter insteadOf still rewrites");
         Assert
           (Version.Url_Rewrite.Rewrite (Repo, "gh:team/repo", For_Push => True)
              = "git@host:team/repo",
            "pushInsteadOf takes precedence for push URLs");
         Assert
           (Version.Url_Rewrite.Rewrite (Repo, "https://elsewhere/x")
              = "https://elsewhere/x",
            "an unmatched URL is returned unchanged");
      end;
   end Rewrites_By_InsteadOf;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Rewrites_By_InsteadOf'Access,
         "Url_Rewrite: insteadOf longest-prefix and pushInsteadOf precedence");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Url_Rewrite");
   end Name;

end Version.Url_Rewrite.Tests;
