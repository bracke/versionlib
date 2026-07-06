with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Pathspec;
with Version.Repository;
with Version.Test_Support;

package body Version.Diff.Tests is

   use AUnit.Assertions;

   function Contains (Text : String; Fragment : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Text, Fragment) /= 0;
   end Contains;

   procedure Diff_Unstaged_Modification
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open);
      begin
         Assert
           (Contains (Text, "diff --version a/a.txt b/a.txt"),
            "diff header missing");
         Assert (Contains (Text, "-hello"), "old line missing");
         Assert (Contains (Text, "+changed"), "new line missing");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Unstaged_Modification;

   procedure Diff_Staged_Addition (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"),
         "new" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add b.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Staged (Version.Repository.Open);
      begin
         Assert
           (Contains (Text, "diff --version a/b.txt b/b.txt"),
            "staged diff header missing");
         Assert
           (Contains (Text, "--- /dev/null"), "added file old side missing");
         Assert (Contains (Text, "+new"), "added file content missing");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Staged_Addition;

   procedure Diff_Untracked_File_Is_Omitted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "untracked.txt"),
         "new" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open);
      begin
         Assert
           (not Contains (Text, "untracked.txt"),
            "plain working-tree diff must omit untracked files");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Untracked_File_Is_Omitted;

   procedure Diff_Staged_Deletion (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Delete_File (Version.Test_Support.Join (Root, "a.txt"));
      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Staged (Version.Repository.Open);
      begin
         Assert
           (Contains (Text, "diff --version a/a.txt b/a.txt"),
            "deletion diff header missing");
         Assert
           (Contains (Text, "+++ /dev/null"), "deleted file new side missing");
         Assert (Contains (Text, "-hello"), "deleted file content missing");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Staged_Deletion;

   procedure Diff_Pathspec_Filters_Working_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"),
         "changed" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add b.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m add-b");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"),
         "changed-again" & Character'Val (10));

      Version.Pathspec.Append_Parse (Specs, "a.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open, Specs);
      begin
         Assert
           (Contains (Text, "a/a.txt"),
            "working diff pathspec must keep selected path");
         Assert
           (not Contains (Text, "b/b.txt"),
            "working diff pathspec must remove unselected path");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Pathspec_Filters_Working_Tree;

   procedure Diff_Pathspec_Filters_Staged
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.adb"),
         "new" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "skip.txt"),
         "new" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add keep.adb skip.txt");

      Version.Pathspec.Append_Parse (Specs, "*.adb");

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Staged (Version.Repository.Open, Specs);
      begin
         Assert
           (Contains (Text, "keep.adb"),
            "staged diff pathspec must keep selected path");
         Assert
           (not Contains (Text, "skip.txt"),
            "staged diff pathspec must remove unselected path");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Pathspec_Filters_Staged;

   procedure Diff_Pathspec_Ignores_Nonmatching_Tracked_Deletion
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.txt"),
         "keep" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "skip.txt"),
         "skip" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add keep.txt skip.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m add-two");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.txt"),
         "changed" & Character'Val (10));
      Ada.Directories.Delete_File
        (Version.Test_Support.Join (Root, "skip.txt"));

      Version.Pathspec.Append_Parse (Specs, "keep.txt");

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open, Specs);
      begin
         Assert
           (Contains (Text, "keep.txt"),
            "working diff pathspec must keep matching tracked change");
         Assert
           (not Contains (Text, "skip.txt"),
            "working diff pathspec must ignore nonmatching tracked deletion");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Pathspec_Ignores_Nonmatching_Tracked_Deletion;

   procedure Diff_Cached_Alias_Matches_Staged
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "keep.adb"),
         "new" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "skip.txt"),
         "new" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add keep.adb skip.txt");

      Version.Pathspec.Append_Parse (Specs, "*.adb");

      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Diff.Diff_Cached (Repo) = Version.Diff.Diff_Staged (Repo),
            "cached diff alias must match staged diff exactly");
         Assert
           (Version.Diff.Diff_Cached (Repo, Specs)
            = Version.Diff.Diff_Staged (Repo, Specs),
            "cached diff alias with pathspecs must match staged diff exactly");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Cached_Alias_Matches_Staged;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Diff_Unstaged_Modification'Access, "Diff: unstaged modification");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Diff_Staged_Addition'Access, "Diff: staged addition");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Untracked_File_Is_Omitted'Access,
         "Diff: untracked file omitted");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Diff_Staged_Deletion'Access, "Diff: staged deletion");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Pathspec_Filters_Working_Tree'Access,
         "Diff: pathspec filters working tree output");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Pathspec_Ignores_Nonmatching_Tracked_Deletion'Access,
         "Diff: pathspec ignores nonmatching tracked deletion");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Pathspec_Filters_Staged'Access,
         "Diff: pathspec filters staged output");
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Cached_Alias_Matches_Staged'Access,
         "Diff: cached alias matches staged output");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Diff");
   end Name;

end Version.Diff.Tests;
