with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Multi_Pack_Index;
with Version.Repository;

package body Version.Commit_Graph.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   --  The commit-graph version writes must be the one git writes, byte for
   --  byte -- octopus merge (and so the EDGE chunk) included.
   procedure Graph_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Dates : constant String :=
        "export GIT_AUTHOR_DATE=""1000000000 +0000"" "
        & "GIT_COMMITTER_DATE=""1000000000 +0000""; ";

      Graph : constant String :=
        Version.Files.Join (Root, ".git/objects/info/commit-graph");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@t");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run
        (Root,
         Dates
         & "echo base > f && git add -A && git commit -q -m base "
         & "&& for b in x y z; do git checkout -q -b $b main; "
         & "echo $b > $b.txt; git add -A; git commit -q -m $b; done "
         & "&& git checkout -q main && echo m > m.txt && git add -A "
         & "&& git commit -q -m main2 "
         & "&& git merge -q --no-ff -m octopus x y z > /dev/null 2>&1; "
         & "git commit-graph write --reachable");

      Ada.Directories.Set_Directory (Root);

      declare
         Expected : constant String :=
           Version.Files.Read_Binary_File (Graph);
      begin
         --  git leaves it read-only; version replaces the file.
         Version.Commit_Graph.Write (Version.Repository.Open);

         declare
            Written : constant String :=
              Version.Files.Read_Binary_File (Graph);
         begin
            Assert (Written = Expected,
                    "the commit-graph must be byte-identical to git's ("
                    & Written'Length'Image & " bytes vs"
                    & Expected'Length'Image & ")");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Graph_Matches_Git;

   --  Same for the multi-pack-index over two packs.
   procedure Midx_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Dates : constant String :=
        "export GIT_AUTHOR_DATE=""1000000000 +0000"" "
        & "GIT_COMMITTER_DATE=""1000000000 +0000""; ";

      Midx : constant String :=
        Version.Files.Join (Root, ".git/objects/pack/multi-pack-index");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@t");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      --  Two packs, written a second apart so their mtimes order the way
      --  git's sub-second comparison would.
      Version.Git_Fixtures.Run
        (Root,
         Dates
         & "echo a > a && git add -A && git commit -q -m a && git gc -q "
         & "&& sleep 1 "
         & "&& echo b > b && git add -A && git commit -q -m b "
         & "&& git repack -q -d && git multi-pack-index write");

      Ada.Directories.Set_Directory (Root);

      declare
         Expected : constant String := Version.Files.Read_Binary_File (Midx);
      begin
         Version.Multi_Pack_Index.Write (Version.Repository.Open);

         declare
            Written : constant String := Version.Files.Read_Binary_File (Midx);
         begin
            Assert (Written = Expected,
                    "the multi-pack-index must be byte-identical to git's ("
                    & Written'Length'Image & " bytes vs"
                    & Expected'Length'Image & ")");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Midx_Matches_Git;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Graph_Matches_Git'Access,
         "Commit_Graph: the file is byte-identical to git's (EDGE included)");
      Register_Routine
        (T, Midx_Matches_Git'Access,
         "Multi_Pack_Index: the file is byte-identical to git's");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Commit_Graph");
   end Name;

end Version.Commit_Graph.Tests;
