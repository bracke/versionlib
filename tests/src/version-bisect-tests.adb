with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Repository;
with Version.Revisions;

package body Version.Bisect.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   --  git's estimate is a pure function of the candidate-set size; the
   --  expected values are read straight off `git rev-list --bisect-vars`.
   procedure Steps_Estimate_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      type Pair is record
         N, Steps : Natural;
      end record;
      Cases : constant array (Positive range <>) of Pair :=
        [(1, 0), (2, 0), (3, 1), (4, 1), (5, 1), (6, 2), (9, 2),
         (10, 2), (11, 3), (21, 3), (22, 4), (85, 5), (86, 6)];
   begin
      for C of Cases loop
         Assert
           (Version.Bisect.Estimate_Steps (C.N) = C.Steps,
            "Estimate_Steps (" & C.N'Image & " ) =>"
            & Version.Bisect.Estimate_Steps (C.N)'Image & ", expected"
            & C.Steps'Image);
      end loop;
   end Steps_Estimate_Matches_Git;

   --  On a 10-commit linear history with good=commit1, bad=commit10, git
   --  bisects to commit5 reporting "4 revisions left ... roughly 2 steps"
   --  over a 9-commit candidate set.
   procedure Linear_Selection_Matches_Git
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
      --  Fixed, increasing commit dates keep the selection unambiguous.
      Version.Git_Fixtures.Run
        (Root,
         "t=1000000000; for i in $(seq 1 10); do echo l$i >> f; "
         & "git add f; GIT_AUTHOR_DATE=""$t +0000"" "
         & "GIT_COMMITTER_DATE=""$t +0000"" git commit -q -m ""c$i""; "
         & "t=$((t+60)); done");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
         Good : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~9");
         Mid  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~5");  --  commit 5
      begin
         Version.Bisect.Start (Repo, "main", "bad", "good");
         Version.Bisect.Mark_Bad (Repo, Bad);
         Version.Bisect.Mark_Good (Repo, Good);
         declare
            B : constant Version.Bisect.Bisection := Version.Bisect.Compute (Repo);
         begin
            Assert (B.Kind = Version.Bisect.Continue, "expected Continue");
            Assert (Version.Objects.To_String (B.Rev)
                    = Version.Objects.To_String (Mid),
                    "must bisect to commit 5");
            Assert (B.All_N = 9, "candidate set size must be 9");
            Assert (B.Left = 4, "revisions left must be 4, got" & B.Left'Image);
            Assert (B.Steps = 2, "steps must be 2, got" & B.Steps'Image);
         end;

         --  Narrowing to good=commit1, bad=commit3 leaves a 3-candidate
         --  range where git tests the middle (commit2) with 0 left.
         Version.Bisect.Mark_Bad
           (Repo, Version.Revisions.Resolve_Commit (Repo, "HEAD~7")); --  c3
         declare
            B  : constant Version.Bisect.Bisection := Version.Bisect.Compute (Repo);
            C2 : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, "HEAD~8");
         begin
            Assert (B.Kind = Version.Bisect.Continue, "3-range expects Continue");
            Assert (B.All_N = 2, "candidate set now 2");
            Assert (Version.Objects.To_String (B.Rev)
                    = Version.Objects.To_String (C2),
                    "must bisect to commit 2");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Linear_Selection_Matches_Git;

   --  Before both endpoints are known, Compute reports the waiting states.
   procedure Waiting_States
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
        (Root, "for i in 1 2 3; do echo l$i >> f; git add f; "
               & "git commit -q -m c$i; done");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
      begin
         Version.Bisect.Start (Repo, "main", "bad", "good");
         Assert (Version.Bisect.Compute (Repo).Kind = Version.Bisect.Need_Both,
                 "fresh session waits for both");
         Version.Bisect.Mark_Bad (Repo, Head);
         Assert (Version.Bisect.Compute (Repo).Kind = Version.Bisect.Need_Good,
                 "bad known waits for good");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Waiting_States;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Steps_Estimate_Matches_Git'Access,
         "Bisect: step estimate matches git across sizes");
      Register_Routine
        (T, Linear_Selection_Matches_Git'Access,
         "Bisect: linear commit selection/left/steps match git");
      Register_Routine
        (T, Waiting_States'Access,
         "Bisect: waiting-for-good/both states");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Bisect");
   end Name;

end Version.Bisect.Tests;
