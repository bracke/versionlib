with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Staging;
with Version.Test_Support;
with Version.Write;

package body Version.Reset.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Save_File
     (Root : String; Path : String; Content : String; Message : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Path), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Path);
      Version.Write.Save (Message);
   end Save_File;

   --  Build a two-commit history: c1 has only f.txt; c2 adds g.txt and changes
   --  f.txt. Returns nothing; the caller opens the repo for assertions.
   procedure Two_Commits (Root : String) is
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "f.txt", "a" & LF, "c1");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "a" & LF & "b" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "g.txt"), "x" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt g.txt");
      Version.Write.Save ("c2");
   end Two_Commits;

   function Indexed (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      return Version.Staging.Find_Path (Entries, Path) /= Natural'Last;
   end Indexed;

   procedure Soft_Moves_Head_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Two_Commits (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         C1   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1");
      begin
         Version.Reset.Reset_To_Commit (Repo, Soft, "HEAD~1");
         Assert (Version.Refs.Current_Commit_Id (Repo) = To_String (C1),
                 "soft reset must move HEAD to the target");
         Assert (Indexed (Repo, "g.txt"),
                 "soft reset must leave the index unchanged (g.txt staged)");
      end;
   end Soft_Moves_Head_Only;

   procedure Mixed_Resets_Index_Keeps_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Two_Commits (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         C1   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1");
      begin
         Version.Reset.Reset_To_Commit (Repo, Mixed, "HEAD~1");
         Assert (Version.Refs.Current_Commit_Id (Repo) = To_String (C1),
                 "mixed reset must move HEAD to the target");
         Assert (not Indexed (Repo, "g.txt"),
                 "mixed reset must drop g.txt from the index");
         Version.Git_Fixtures.Run (Root, "test -f g.txt");
      end;
   end Mixed_Resets_Index_Keeps_Worktree;

   procedure Hard_Resets_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Two_Commits (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         C1   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1");
      begin
         Version.Reset.Reset_To_Commit (Repo, Hard, "HEAD~1");
         Assert (Version.Refs.Current_Commit_Id (Repo) = To_String (C1),
                 "hard reset must move HEAD to the target");
         Assert (not Indexed (Repo, "g.txt"),
                 "hard reset must drop g.txt from the index");
         Version.Git_Fixtures.Run (Root, "test ! -f g.txt");
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "f.txt")) = "a",
            "hard reset must revert the working-tree file to the target");
      end;
   end Hard_Resets_Worktree;

   procedure Invalid_Target_No_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Two_Commits (Root);
      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Raised : Boolean := False;
      begin
         begin
            Version.Reset.Reset_To_Commit
              (Repo, Hard, "0000000000000000000000000000000000000000");
         exception
            when others =>
               Raised := True;
         end;
         Assert (Raised, "reset to an unknown target must fail");
         Assert (Version.Refs.Current_Commit_Id (Repo) = Before,
                 "failed reset must not move HEAD");
         Assert (Indexed (Repo, "g.txt"),
                 "failed reset must not mutate the index");
      end;
   end Invalid_Target_No_Mutation;

   procedure Path_Reset_Unstages
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Two_Commits (Root);
      --  Stage a further change to f.txt, then unstage it via path reset.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "a" & LF & "b" & LF & "c" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Paths : Version.Reset.Path_Vectors.Vector;
      begin
         Paths.Append (Ada.Strings.Unbounded.To_Unbounded_String ("f.txt"));
         Version.Reset.Reset_Paths (Repo, "HEAD", Paths);
         Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                 "path reset must not move HEAD");
         --  Index f.txt is back to HEAD: git diff --cached is clean.
         Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
         --  Working tree keeps the staged-then-unstaged change.
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "f.txt")) = "a" & LF & "b" & LF & "c",
            "path reset must leave the working tree unchanged");
      end;
   end Path_Reset_Unstages;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Soft_Moves_Head_Only'Access,
         "Reset: --soft moves HEAD only");
      Register_Routine
        (T, Mixed_Resets_Index_Keeps_Worktree'Access,
         "Reset: --mixed resets index, keeps working tree");
      Register_Routine
        (T, Hard_Resets_Worktree'Access,
         "Reset: --hard resets index and working tree");
      Register_Routine
        (T, Invalid_Target_No_Mutation'Access,
         "Reset: invalid target fails without mutation");
      Register_Routine
        (T, Path_Reset_Unstages'Access,
         "Reset: path form unstages without touching HEAD/worktree");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Reset");
   end Name;

end Version.Reset.Tests;
