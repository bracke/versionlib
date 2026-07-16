with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Objects;
with Version.Pathspec;
with Version.Repository;
with Version.Revisions;
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
           (Contains (Text, "diff --git a/a.txt b/a.txt"),
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

   procedure Raw_Diff_Plumbing_Shape
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
      HT : constant Character := Character'Val (9);
      Zeros : constant String (1 .. 40) := [others => '0'];
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);  --  a.txt=hello\n
      Ada.Directories.Set_Directory (Root);

      --  Unstaged modification: diff-files raw line, working id zeroed.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "changed" & LF);
      Assert
        (Version.Diff.Raw_Diff_Files (Version.Repository.Open)
         = ":100644 100644 ce013625030ba8dba906f756967f9e9ca394464a "
           & Zeros & " M" & HT & "a.txt" & LF,
         "diff-files raw line for an unstaged modification");

      --  Staged addition: diff-index --cached shows an A line with the blob id.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "b.txt"), "new" & LF);
      Version.Git_Fixtures.Run (Root, "git add b.txt");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Tree : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Tree (Repo, "HEAD");
      begin
         Assert
           (Contains
              (Version.Diff.Raw_Diff_Index (Repo, Tree, Cached => True),
               ":000000 100644 " & Zeros
               & " 3e757656cf36eca53338e520d134963a44f793f8 A" & HT
               & "b.txt"),
            "diff-index --cached raw line for a staged addition");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Raw_Diff_Plumbing_Shape;

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
           (Contains (Text, "diff --git a/b.txt b/b.txt"),
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
           (Contains (Text, "diff --git a/a.txt b/a.txt"),
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

   procedure Diff_Minimal_Hunk_Keeps_Context
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF      : constant Character := Character'Val (10);
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "m.txt"),
         "L1" & LF & "L2" & LF & "L3" & LF & "L4" & LF & "L5" & LF);
      Version.Git_Fixtures.Run (Root, "git add m.txt");
      Version.Git_Fixtures.Run (Root, "git commit -q -m multi");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "m.txt"),
         "L1" & LF & "L2" & LF & "X3" & LF & "L4" & LF & "L5" & LF);

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open);
      begin
         Assert (Contains (Text, "index "), "index line missing");
         Assert (Contains (Text, "@@ "), "hunk header missing");
         Assert (Contains (Text, "-L3"), "changed old line missing");
         Assert (Contains (Text, "+X3"), "changed new line missing");
         Assert (Contains (Text, " L2"), "context line missing");
         --  Minimality: unchanged lines are context, never re-emitted as -/+.
         Assert (not Contains (Text, "-L1"), "L1 must not be deleted");
         Assert (not Contains (Text, "+L5"), "L5 must not be inserted");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Minimal_Hunk_Keeps_Context;

   procedure Diff_Stat_Summary (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Opts    : constant Version.Diff.Diff_Options :=
        (Stat => True, others => <>);
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      declare
         Text : constant String :=
           Version.Diff.Diff_Working_Tree (Version.Repository.Open, Opts);
      begin
         Assert (Contains (Text, "a.txt | "), "stat per-file line missing");
         Assert (Contains (Text, "1 file changed"), "stat footer missing");
         --  A one-line replacement is 1 insertion + 1 deletion.
         Assert (Contains (Text, "insertion"), "stat insertion missing");
         Assert (Contains (Text, "deletion"), "stat deletion missing");
         Assert
           (not Contains (Text, "@@ "),
            "stat output must not include a patch hunk");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Diff_Stat_Summary;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Diff_Unstaged_Modification'Access, "Diff: unstaged modification");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Raw_Diff_Plumbing_Shape'Access,
         "Diff: raw plumbing (diff-files/diff-index) line shape");
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
      AUnit.Test_Cases.Registration.Register_Routine
        (T,
         Diff_Minimal_Hunk_Keeps_Context'Access,
         "Diff: minimal hunk keeps unchanged lines as context");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Diff_Stat_Summary'Access, "Diff: --stat summary output");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Diff");
   end Name;

end Version.Diff.Tests;
