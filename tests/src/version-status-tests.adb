with AUnit.Assertions;
with AUnit.Test_Cases;

with GNAT.OS_Lib;

with Version.Test_Support;
with Version.Git_Fixtures;
with Version.Objects;
with Version.Staging;
with Version.Stage;
with Version.Pathspec;
with Version.Platform;
with Version.Repository;
with Version.Write;

with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Version.Status.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use type Version.Platform.Platform_Kind;

   LF : constant Character := Character'Val (10);

   function LFS_Pointer return String is
     ("version https://git-lfs.github.com/spec/v1" & LF
      & "oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      & LF
      & "size 123456");

   function Has_Change
   (List : Version.Status.File_Change_Vectors.Vector;
      Path : String;
      Kind : Version.Status.Change_Kind)
      return Boolean
   is
   begin
      if List.Is_Empty then
         return False;
      end if;

      for I in List.First_Index .. List.Last_Index loop
         if To_String (List.Element (I).Path) = Path
         and then List.Element (I).Kind = Kind
         then
            return True;
         end if;
      end loop;

      return False;
   end Has_Change;

   function Index_Mode_For_Path
     (Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Path    : String)
      return String
   is
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            if To_String (Entries.Element (I).Path) = Path then
               return To_String (Entries.Element (I).Mode);
            end if;
         end loop;
      end if;

      Assert (False, "missing index entry: " & Path);
      return "";
   end Index_Mode_For_Path;

   procedure LFS_Pointer_Status_Is_Ordinary_Modified_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "asset.bin"), LFS_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("store LFS pointer");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "asset.bin"),
         LFS_Pointer & "ordinary local edit" & LF);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (Has_Change
              (Result.Changes, "asset.bin", Version.Status.Modified_File),
            "modified LFS pointer must be reported as ordinary modified file");
         Assert (Result.Staged.Is_Empty,
                 "modified LFS pointer must not create staged LFS behavior");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end LFS_Pointer_Status_Is_Ordinary_Modified_File;

   procedure Empty_Repo_Status_Does_Not_Raise
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
  (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Refs    : constant String := Version.Test_Support.Join (Dot_Git, "refs");
      Heads   : constant String := Version.Test_Support.Join (Refs, "heads");
   begin
      Version.Test_Support.Make_Directory (Dot_Git);
      Version.Test_Support.Make_Directory (Refs);
      Version.Test_Support.Make_Directory (Heads);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Dot_Git, "HEAD"),
         "ref: refs/heads/main");

      Ada.Directories.Set_Directory (Root);
      Version.Status.Print_Status;
      Assert (True, "empty repo status should not raise");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Empty_Repo_Status_Does_Not_Raise;

   procedure Clean_Committed_Repo
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert (Result.Changes.Is_Empty, "clean repo must have no unstaged changes");
         Assert (Result.Staged.Is_Empty, "clean repo must have no staged changes");
         Assert (Result.Untracked.Is_Empty, "clean repo must have no untracked files");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clean_Committed_Repo;

   procedure Modified_Unstaged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Changes,
               "a.txt",
               Version.Status.Modified_File),
            "modified file must appear in Changes");

         Assert (Result.Staged.Is_Empty, "modified unstaged file must not be staged");
         Assert (Result.Untracked.Is_Empty, "modified tracked file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Modified_Unstaged_File;

   procedure Modified_Staged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Staged,
               "a.txt",
               Version.Status.Modified_File),
            "staged modified file must appear in Staged");

         Assert (Result.Changes.Is_Empty, "staged file with no extra edits must have no Changes");
         Assert (Result.Untracked.Is_Empty, "tracked file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Modified_Staged_File;

   procedure Mixed_Staged_And_Unstaged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "a.txt"),
         "staged" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "a.txt"),
         "unstaged" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Staged,
               "a.txt",
               Version.Status.Modified_File),
            "mixed file must appear as staged modified");

         Assert
         (Has_Change
            (Result.Changes,
               "a.txt",
               Version.Status.Modified_File),
            "mixed file must appear as unstaged modified");

         Assert
         (Result.Untracked.Is_Empty,
            "mixed tracked file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Mixed_Staged_And_Unstaged_File;

   procedure Untracked_File
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "b.txt"),
         "new" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Untracked,
               "b.txt",
               Version.Status.New_File),
            "new file must appear as untracked");

         Assert
         (Result.Changes.Is_Empty,
            "untracked file must not appear in Changes");

         Assert
         (Result.Staged.Is_Empty,
            "untracked file must not appear in Staged");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Untracked_File;

   procedure Deleted_Unstaged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Delete_File
      (Version.Test_Support.Join (Root, "a.txt"));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Changes,
               "a.txt",
               Version.Status.Deleted_File),
            "deleted tracked file must appear in Changes");

         Assert
         (Result.Staged.Is_Empty,
            "unstaged deletion must not appear in Staged");

         Assert
         (Result.Untracked.Is_Empty,
            "deleted tracked file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Deleted_Unstaged_File;

   procedure Deleted_Staged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Delete_File
      (Version.Test_Support.Join (Root, "a.txt"));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Staged,
               "a.txt",
               Version.Status.Deleted_File),
            "staged deletion must appear in Staged");

         Assert
         (Result.Changes.Is_Empty,
            "staged deletion must not appear in Changes");

         Assert
         (Result.Untracked.Is_Empty,
            "deleted tracked file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Deleted_Staged_File;

   procedure New_Staged_File
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "b.txt"),
         "new" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add b.txt");

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
         Version.Status.Current_Status;
      begin
         Assert
         (Has_Change
            (Result.Staged,
               "b.txt",
               Version.Status.New_File),
            "new staged file must appear in Staged");

         Assert
         (Result.Changes.Is_Empty,
            "new staged file with no further edits must not appear in Changes");

         Assert
         (Result.Untracked.Is_Empty,
            "new staged file must not be untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end New_Staged_File;

   procedure Stage_Path_Uses_Platform_File_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Normal  : constant String := Version.Test_Support.Join (Root, "normal.sh");
      Exec    : constant String := Version.Test_Support.Join (Root, "exec.sh");
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Normal, "echo normal" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Exec, "echo exec" & Character'Val (10));
      GNAT.OS_Lib.Set_Executable (Exec);

      if Version.Platform.Current /= Version.Platform.Windows_Platform then
         Version.Git_Fixtures.Run (Root, "ln -s missing-target link.txt");
      end if;

      Ada.Directories.Set_Directory (Root);
      Version.Stage.Stage_Path ("normal.sh");
      Version.Stage.Stage_Path ("exec.sh");
      if Version.Platform.Current /= Version.Platform.Windows_Platform then
         Version.Stage.Stage_Path ("link.txt");
      end if;

      declare
         Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Version.Repository.Open);
         Expected_Exec_Mode : constant String :=
           (if Version.Platform.Supports_Executable_Bit
            then "100755"
            else "100644");
      begin
         Assert
           (Index_Mode_For_Path (Entries, "normal.sh") = "100644",
            "non-executable staged file must use regular mode");
         Assert
           (Index_Mode_For_Path (Entries, "exec.sh") = Expected_Exec_Mode,
            "executable staged file must follow platform filemode support");

         if Version.Platform.Current /= Version.Platform.Windows_Platform then
            Assert
              (Index_Mode_For_Path (Entries, "link.txt") = "120000",
               "staged symlink must use Git symlink mode");
         end if;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stage_Path_Uses_Platform_File_Mode;

   procedure Staging_Replace_Keeps_Deterministic_Order
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Entries : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Version.Staging.Replace_Entry
        (Entries,
         Version.Staging.Index_Entry'
           (Path => To_Unbounded_String ("z.txt"),
            Id   => Version.Objects.To_Object_Id ([1 .. 40 => '1']),
            Mode => To_Unbounded_String ("100644"),
            Stage => 0, Skip_Worktree => False));

      Version.Staging.Replace_Entry
        (Entries,
         Version.Staging.Index_Entry'
           (Path => To_Unbounded_String ("a.txt"),
            Id   => Version.Objects.To_Object_Id ([1 .. 40 => '2']),
            Mode => To_Unbounded_String ("100644"),
            Stage => 0, Skip_Worktree => False));

      Version.Staging.Replace_Entry
        (Entries,
         Version.Staging.Index_Entry'
           (Path => To_Unbounded_String ("m.txt"),
            Id   => Version.Objects.To_Object_Id ([1 .. 40 => '3']),
            Mode => To_Unbounded_String ("100644"),
            Stage => 0, Skip_Worktree => False));

      Version.Staging.Replace_Entry
        (Entries,
         Version.Staging.Index_Entry'
           (Path => To_Unbounded_String ("a.txt"),
            Id   => Version.Objects.To_Object_Id ([1 .. 40 => '4']),
            Mode => To_Unbounded_String ("100755"),
            Stage => 0, Skip_Worktree => False));

      Assert (Natural (Entries.Length) = 3, "replace must not duplicate an existing path");
      Assert
        (To_String (Entries.Element (Entries.First_Index).Path) = "a.txt",
         "replace should keep deterministic path ordering after insertion");
      declare
         Expected_Id : constant Version.Objects.Object_Id_Storage := Version.Objects.To_Object_Id ([1 .. 40 => '4']);
      begin
         Assert
           (Entries.Element (Entries.First_Index).Id = Expected_Id,
            "replace should update the existing path entry");
      end;
   end Staging_Replace_Keeps_Deterministic_Order;

   procedure Ignored_Directory_Is_Not_Reported
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Build_Dir : constant String := Version.Test_Support.Join (Root, "build");
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "build/" & Character'Val (10));
      Version.Test_Support.Make_Directory (Build_Dir);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Build_Dir, "generated.o"),
         "ignored" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Assert
           (not Has_Change
              (Result.Untracked,
               "build/generated.o",
               Version.Status.New_File),
            "ignored directory contents must not be reported as untracked");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ignored_Directory_Is_Not_Reported;

   procedure Ignored_Status_Reports_Ignored_Separately
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Build_Dir : constant String := Version.Test_Support.Join (Root, "build");
      Specs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitignore"),
         "*.log" & Character'Val (10)
         & "build/" & Character'Val (10));
      Version.Test_Support.Make_Directory (Build_Dir);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "ignored.log"),
         "ignored" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Build_Dir, "generated.o"),
         "ignored" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "visible.txt"),
         "visible" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Plain : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
         With_Ignored : constant Version.Status.Status_Result :=
           Version.Status.Current_Status_With_Ignored;
      begin
         Assert
           (Plain.Ignored.Is_Empty,
            "ordinary status should not populate ignored output");
         Assert
           (Has_Change
              (With_Ignored.Ignored,
               "ignored.log",
               Version.Status.Ignored_File),
            "ignored status should report ignored files separately");
         Assert
           (Has_Change
              (With_Ignored.Ignored,
               "build/generated.o",
               Version.Status.Ignored_File),
            "ignored status should report ignored directory contents separately");
         Assert
           (not Has_Change
              (With_Ignored.Untracked,
               "ignored.log",
               Version.Status.New_File),
            "ignored files must not move into untracked output");
         Assert
           (Has_Change
              (With_Ignored.Untracked,
               "visible.txt",
               Version.Status.New_File),
            "ordinary untracked files should remain visible with ignored status");
      end;

      Version.Pathspec.Append_Parse (Specs, "ignored.log");
      declare
         Filtered : constant Version.Status.Status_Result :=
           Version.Status.Current_Status_With_Ignored (Specs);
      begin
         Assert
           (Has_Change
              (Filtered.Ignored, "ignored.log", Version.Status.Ignored_File),
            "ignored status pathspec should keep matching ignored files");
         Assert
           (not Has_Change
              (Filtered.Ignored,
               "build/generated.o",
               Version.Status.Ignored_File),
            "ignored status pathspec should filter nonmatching ignored files");
         Assert
           (Filtered.Untracked.Is_Empty,
            "ignored status pathspec should filter nonmatching untracked files");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ignored_Status_Reports_Ignored_Separately;

   procedure Status_Pathspec_Filters_Untracked
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Make_Directory
        (Version.Test_Support.Join (Root, "docs"));
      --  docs/ must hold something tracked, or git (and now version) collapses
      --  a wholly-untracked directory to `docs/`, which no `docs/**/*.md`
      --  pathspec can match -- verified against `git status --porcelain`.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "docs/kept.txt"), "kept" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add docs/kept.txt");
      Version.Git_Fixtures.Run
        (Root, "git -c user.name=T -c user.email=t@t commit -q -m docs");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "docs/readme.md"), "doc" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "other.txt"), "other" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      Version.Pathspec.Append_Parse (Specs, "docs/**/*.md");

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Untracked, "docs/readme.md", Version.Status.New_File),
            "status pathspec must keep matching untracked file");
         Assert
           (not Has_Change
              (Result.Untracked, "other.txt", Version.Status.New_File),
            "status pathspec must remove non-matching untracked file");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Pathspec_Filters_Untracked;

   procedure Status_Pathspec_Keeps_Matching_Tracked_Modification
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "changed" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "unrelated.txt"),
         "unrelated" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);
      Version.Pathspec.Append_Parse (Specs, "a.txt");

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Changes, "a.txt", Version.Status.Modified_File),
            "status pathspec must keep matching tracked modifications");
         Assert
           (not Has_Change
              (Result.Untracked, "unrelated.txt", Version.Status.New_File),
            "status pathspec must not report non-matching untracked files");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Pathspec_Keeps_Matching_Tracked_Modification;

   procedure Status_Attr_Pathspec_Filters_By_Attributes
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.gen generated" & Character'Val (10)
         & "*.unset -generated" & Character'Val (10)
         & "*.val kind=special" & Character'Val (10)
         & "*.override generated" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".git/info/attributes"),
         "*.info generated" & Character'Val (10)
         & "*.override -generated" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "generated.gen"),
         "generated" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "plain.txt"),
         "plain" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "reset.unset"),
         "reset" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "valued.val"),
         "valued" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "info.info"),
         "info" & Character'Val (10));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "override.override"),
         "override" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      Version.Pathspec.Append_Parse (Specs, ":(attr:generated)*");
      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Untracked, "generated.gen", Version.Status.New_File),
            "attr:set pathspec must keep files with a set attribute");
         Assert
           (not Has_Change
              (Result.Untracked, "plain.txt", Version.Status.New_File),
            "attr:set pathspec must reject files without the attribute");
         Assert
           (Has_Change
              (Result.Untracked, "info.info", Version.Status.New_File),
            "attr:set pathspec must honor .git/info/attributes rules");
         Assert
           (not Has_Change
              (Result.Untracked, "override.override", Version.Status.New_File),
            "attr:set pathspec must honor .git/info/attributes overrides");
      end;

      Specs.Clear;
      Version.Pathspec.Append_Parse (Specs, ":(attr:-generated)*");
      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Untracked, "reset.unset", Version.Status.New_File),
            "attr:unset pathspec must keep files with an unset attribute");
         Assert
           (not Has_Change
              (Result.Untracked, "generated.gen", Version.Status.New_File),
            "attr:unset pathspec must reject files with a set attribute");
         Assert
           (Has_Change
              (Result.Untracked, "override.override", Version.Status.New_File),
            "attr:unset pathspec must keep files unset by .git/info/attributes");
      end;

      Specs.Clear;
      Version.Pathspec.Append_Parse (Specs, ":(attr:!generated)*");
      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Untracked, "plain.txt", Version.Status.New_File),
            "attr:unspecified pathspec must keep files without an attribute rule");
         Assert
           (not Has_Change
              (Result.Untracked, "generated.gen", Version.Status.New_File),
            "attr:unspecified pathspec must reject files with a set attribute");
         Assert
           (not Has_Change
              (Result.Untracked, "reset.unset", Version.Status.New_File),
            "attr:unspecified pathspec must reject files with an unset attribute");
      end;

      Specs.Clear;
      Version.Pathspec.Append_Parse (Specs, ":(attr:kind=special)*");
      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status (Specs);
      begin
         Assert
           (Has_Change
              (Result.Untracked, "valued.val", Version.Status.New_File),
            "attr:value pathspec must keep files with the requested attribute value");
         Assert
           (not Has_Change
              (Result.Untracked, "plain.txt", Version.Status.New_File),
            "attr:value pathspec must reject files without the value");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Attr_Pathspec_Filters_By_Attributes;

   procedure Branch_Status_Text_Prints_Branch_Header
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
         Text   : constant String := Version.Status.Branch_Status_Text (Result);
      begin
         Assert
           (Text'Length >= 4 and then Text (Text'First .. Text'First + 2) = "## ",
            "status --branch text must start with a stable branch header");
         Assert
           (Ada.Strings.Fixed.Index (Text, Character'Val (10) & "S ") = 0,
            "clean branch status must not invent staged entries");
         Assert
           (Ada.Strings.Fixed.Index (Text, Character'Val (10) & "W ") = 0,
            "clean branch status must not invent working-tree entries");
         Assert
           (Ada.Strings.Fixed.Index (Text, Character'Val (10) & "? ") = 0,
            "clean branch status must not invent untracked entries");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Status_Text_Prints_Branch_Header;

   procedure Branch_Status_Text_Appends_Short_Status_Entries
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "new.txt"),
         "new" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Result : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
         Text   : constant String := Version.Status.Branch_Status_Text (Result);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Text, "?? new.txt") /= 0,
            "status --branch must append the same short untracked entries");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Status_Text_Appends_Short_Status_Entries;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine (T, Empty_Repo_Status_Does_Not_Raise'Access,
                        "Empty repository status smoke test");

      AUnit.Test_Cases.Registration.Register_Routine (T, Clean_Committed_Repo'Access,
                        "Status: clean committed repo");

      AUnit.Test_Cases.Registration.Register_Routine (T, Modified_Unstaged_File'Access,
                        "Status: modified unstaged file");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, LFS_Pointer_Status_Is_Ordinary_Modified_File'Access,
         "Status: LFS pointer treated as ordinary modified file");

      AUnit.Test_Cases.Registration.Register_Routine (T, Modified_Staged_File'Access,
                        "Status: modified staged file");

      AUnit.Test_Cases.Registration.Register_Routine (T, Mixed_Staged_And_Unstaged_File'Access,
                        "Status: mixed staged and unstaged file");

      AUnit.Test_Cases.Registration.Register_Routine (T, Untracked_File'Access,
                        "Status: untracked file");

      AUnit.Test_Cases.Registration.Register_Routine (T, Deleted_Unstaged_File'Access,
                        "Status: deleted unstaged file");

      AUnit.Test_Cases.Registration.Register_Routine (T, Deleted_Staged_File'Access,
                        "Status: deleted staged file");

      AUnit.Test_Cases.Registration.Register_Routine (T, New_Staged_File'Access,
                        "Status: new staged file");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Stage_Path_Uses_Platform_File_Mode'Access,
         "Stage: file mode follows executable bit support");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Staging_Replace_Keeps_Deterministic_Order'Access,
         "Staging: replace keeps deterministic path order");

      AUnit.Test_Cases.Registration.Register_Routine (T, Ignored_Directory_Is_Not_Reported'Access,
                        "Status: ignored directory contents are pruned");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Ignored_Status_Reports_Ignored_Separately'Access,
         "Status: ignored output reports ignored files separately");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Status_Pathspec_Filters_Untracked'Access,
         "Status: pathspec filters untracked output");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Status_Pathspec_Keeps_Matching_Tracked_Modification'Access,
         "Status: pathspec keeps matching tracked modifications");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Status_Attr_Pathspec_Filters_By_Attributes'Access,
         "Status: attr pathspec filters by attributes");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Branch_Status_Text_Prints_Branch_Header'Access,
         "Status: branch status prints branch header");

      AUnit.Test_Cases.Registration.Register_Routine
        (T, Branch_Status_Text_Appends_Short_Status_Entries'Access,
         "Status: branch status appends short entries");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Status");
   end Name;

end Version.Status.Tests;
