with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Staging;
with Version.Test_Support;
with Version.Write;

package body Version.Move.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Commit_File (Root, Path, Content : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Path), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Path);
      Version.Write.Save ("c");
   end Commit_File;

   function Indexed (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      return Version.Staging.Find_Path (Entries, Path) /= Natural'Last;
   end Indexed;

   procedure Renames_Tracked_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "hello" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Move.Move_Path (Repo, "a.txt", "b.txt");

         Assert (not Indexed (Repo, "a.txt"),
                 "move must drop the source from the index");
         Assert (Indexed (Repo, "b.txt"),
                 "move must add the destination to the index");
         Version.Git_Fixtures.Run (Root, "test ! -e a.txt");
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "b.txt")) = "hello",
            "move must carry the file content to the destination");
      end;
   end Renames_Tracked_File;

   procedure Untracked_Source_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "hello" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "u.txt"), "u" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         begin
            Version.Move.Move_Path (Repo, "u.txt", "x.txt");
         exception
            when others =>
               Raised := True;
         end;
         Assert (Raised, "moving an untracked source must fail");
         Version.Git_Fixtures.Run (Root, "test -e u.txt");
         Assert (not Indexed (Repo, "x.txt"),
                 "failed move must not add the destination");
      end;
   end Untracked_Source_Fails;

   procedure Existing_Destination_Requires_Force
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "a" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"), "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt b.txt");
      Version.Write.Save ("c");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         begin
            Version.Move.Move_Path (Repo, "a.txt", "b.txt");
         exception
            when others =>
               Raised := True;
         end;
         Assert (Raised, "move onto an existing destination must fail");

         --  With Force it succeeds and overwrites.
         Version.Move.Move_Path (Repo, "a.txt", "b.txt", Force => True);
         Assert (not Indexed (Repo, "a.txt"),
                 "forced move must drop the source");
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "b.txt")) = "a",
            "forced move must overwrite the destination content");
      end;
   end Existing_Destination_Requires_Force;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Renames_Tracked_File'Access,
         "Move: renames a tracked file and restages it");
      Register_Routine
        (T, Untracked_Source_Fails'Access,
         "Move: untracked source fails without mutation");
      Register_Routine
        (T, Existing_Destination_Requires_Force'Access,
         "Move: existing destination requires force");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Move");
   end Name;

end Version.Move.Tests;
