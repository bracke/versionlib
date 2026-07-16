with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;

package body Version.Fmt_Merge_Msg.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   HT : constant Character := Character'Val (9);
   LF : constant Character := Character'Val (10);

   procedure Groups_Like_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sha : constant String := (1 .. 40 => 'a');
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         function Line (Desc : String) return String is
           (Sha & HT & HT & Desc & LF);
      begin
         Assert
           (Format (Repo, Line ("branch 'feature' of ../repo"), "main")
            = "Merge branch 'feature' of ../repo" & LF,
            "single branch with source");
         Assert
           (Format
              (Repo,
               Line ("branch 'feature' of ../repo")
               & Line ("branch 'topic' of ../repo"),
               "main")
            = "Merge branches 'feature' and 'topic' of ../repo" & LF,
            "two branches, same source, grouped with 'and'");
         Assert
           (Format
              (Repo, Line ("branch 'feature'") & Line ("branch 'topic'"),
               "main")
            = "Merge branch 'feature'; branch 'topic'" & LF,
            "two local branches form separate groups");
         Assert
           (Format (Repo, Line ("branch 'topic'"), "develop")
            = "Merge branch 'topic' into develop" & LF,
            "'into <branch>' appended off the default branch");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Groups_Like_Git;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Groups_Like_Git'Access,
         "Format groups merge heads like git fmt-merge-msg");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Fmt_Merge_Msg");
   end Name;

end Version.Fmt_Merge_Msg.Tests;
