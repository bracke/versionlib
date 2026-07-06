with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Clean.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   function Has (V : Version.Clean.Path_Vectors.Vector; S : String)
      return Boolean is
   begin
      for E of V loop
         if To_String (E) = S then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   --  Build a repo with a tracked file plus an untracked file, an untracked
   --  directory, and an ignored file.
   procedure Build_Working_Tree (Root : String) is
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "tracked.txt"), "t" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"), "*.log" & LF);
      Version.Git_Fixtures.Run (Root, "git add tracked.txt .gitignore");
      Version.Write.Save ("c1");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "untrackedfile"), "u" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "untrackeddir/inner"), "x" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "ignored.log"), "i" & LF);
   end Build_Working_Tree;

   procedure Candidates_Honor_Options
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Build_Working_Tree (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Plain : constant Version.Clean.Path_Vectors.Vector :=
           Version.Clean.Candidates (Repo, (others => False));
         Dirs  : constant Version.Clean.Path_Vectors.Vector :=
           Version.Clean.Candidates
             (Repo, (Directories => True, Ignored => False));
         Dirs_Ignored : constant Version.Clean.Path_Vectors.Vector :=
           Version.Clean.Candidates
             (Repo, (Directories => True, Ignored => True));
      begin
         --  Default: only the top-level untracked file.
         Assert (Has (Plain, "untrackedfile"),
                 "clean must list the untracked file");
         Assert (not Has (Plain, "untrackeddir/"),
                 "clean without -d must omit untracked directories");
         Assert (not Has (Plain, "ignored.log"),
                 "clean without -x must omit ignored files");

         --  -d: collapse the untracked directory to a single "dir/" entry.
         Assert (Has (Dirs, "untrackeddir/"),
                 "clean -d must list the untracked directory collapsed");
         Assert (not Has (Dirs, "untrackeddir/inner"),
                 "clean -d must not list files inside the collapsed directory");
         Assert (not Has (Dirs, "ignored.log"),
                 "clean -d without -x must still omit ignored files");

         --  -dx: also the ignored file.
         Assert (Has (Dirs_Ignored, "ignored.log"),
                 "clean -x must list ignored files");
      end;
   end Candidates_Honor_Options;

   procedure Remove_Candidate_Deletes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Build_Working_Tree (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cands : constant Version.Clean.Path_Vectors.Vector :=
           Version.Clean.Candidates
             (Repo, (Directories => True, Ignored => False));
      begin
         for C of Cands loop
            Version.Clean.Remove_Candidate (Repo, To_String (C));
         end loop;

         Version.Git_Fixtures.Run (Root, "test ! -e untrackedfile");
         Version.Git_Fixtures.Run (Root, "test ! -e untrackeddir");
         --  Tracked and ignored content is left untouched.
         Version.Git_Fixtures.Run (Root, "test -e tracked.txt");
         Version.Git_Fixtures.Run (Root, "test -e ignored.log");
      end;
   end Remove_Candidate_Deletes;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Candidates_Honor_Options'Access,
         "Clean: candidates honor -d/-x and collapse untracked dirs");
      Register_Routine
        (T, Remove_Candidate_Deletes'Access,
         "Clean: remove deletes untracked, keeps tracked and ignored");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Clean");
   end Name;

end Version.Clean.Tests;
