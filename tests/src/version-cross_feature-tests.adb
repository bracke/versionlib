with Version.Objects;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Archive;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Platform; use Version.Platform;
with Version.Repository;
with Version.Restore;
with Version.Sparse;
with Version.Staging;
with Version.Test_Support;
with Version.Worktrees;
with Version.Write;

package body Version.Cross_Feature.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Stage_Gitlink
     (Root : String;
      Path : String;
      Id   : String)
   is
   begin
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000," & Id & "," & Path);
   end Stage_Gitlink;

   function Index_Entry_Mode
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return String
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos : constant Natural := Version.Staging.Find_Entry (Entries, Path);
   begin
      if Pos = Natural'Last then
         return "";
      end if;

      return Ada.Strings.Unbounded.To_String (Entries.Element (Pos).Mode);
   end Index_Entry_Mode;

   function Index_Entry_Id
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return String
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos : constant Natural := Version.Staging.Find_Entry (Entries, Path);
   begin
      if Pos = Natural'Last then
         return "";
      end if;

      return To_String (Entries.Element (Pos).Id);
   end Index_Entry_Id;

   procedure Save_All (Root : String; Message : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git add .");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save (Message);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_All;

   procedure Add_File
     (Root    : String;
      Path    : String;
      Content : String)
   is
      Full : constant String := Join (Root, Path);
   begin
      Version.Files.Create_Parent_Directories (Full);
      Version.Test_Support.Write_Text_File (Full, Content);
   end Add_File;

   procedure Skip_Unless_POSIX is
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         raise AUnit.Assertions.Assertion_Error with
           "POSIX cross-feature hook test skipped on non-POSIX platform";
      end if;
   end Skip_Unless_POSIX;

   procedure Restore_Sparse_Submodule_Parent_Preserves_Boundary
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String := Join (Root, "deps/libfoo");
      Dirty_Path : constant String := Join (Submodule_Dir, "dirty.txt");
      Readme_Path : constant String := Join (Root, "deps/readme.txt");
      Gitlink_Id : constant String := "1234512345123451234512345123451234512345";
      Items : Version.Sparse.String_Vectors.Vector;
   begin
      Configure_Repo (Root);
      Add_File (Root, "deps/readme.txt", "tracked one" & LF);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Dirty_Path, "submodule local one" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m sparse-submodule");

      Ada.Directories.Set_Directory (Root);
      Items.Append ("deps/");
      Version.Sparse.Set_From_Strings (Version.Repository.Open, Items);
      Version.Test_Support.Write_Text_File (Readme_Path, "tracked dirty" & LF);
      Version.Test_Support.Write_Text_File (Dirty_Path, "submodule local two" & LF);

      Version.Restore.Restore_Path ("deps");

      Assert (Version.Test_Support.Read_Text_File (Readme_Path) = "tracked one",
              "sparse parent restore must restore ordinary tracked files");
      Assert (Version.Test_Support.Read_Text_File (Dirty_Path) = "submodule local two",
              "sparse parent restore must not recurse into submodule worktree");
      Assert (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
              "sparse parent restore must preserve gitlink mode");
      Assert (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
              "sparse parent restore must preserve gitlink object id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Sparse_Submodule_Parent_Preserves_Boundary;

   procedure Restore_Sparse_Excluded_Submodule_Is_Rejected_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String := Join (Root, "deps/libfoo");
      Dirty_Path : constant String := Join (Submodule_Dir, "dirty.txt");
      Gitlink_Id : constant String := "2345623456234562345623456234562345623456";
      Items : Version.Sparse.String_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Add_File (Root, "src/main.adb", "procedure Main is begin null; end Main;" & LF);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Dirty_Path, "submodule local" & LF);
      Version.Git_Fixtures.Run (Root, "git add src/main.adb");
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m sparse-excluded-submodule");

      Ada.Directories.Set_Directory (Root);
      Items.Append ("src/");
      Version.Sparse.Set_From_Strings (Version.Repository.Open, Items);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Dirty_Path, "submodule local dirty" & LF);

      begin
         Version.Restore.Restore_Path ("deps");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised,
              "sparse-excluded submodule parent restore must be rejected");
      Assert (Version.Test_Support.Read_Text_File (Dirty_Path) = "submodule local dirty",
              "rejected sparse/submodule restore must not touch submodule files");
      Assert (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
              "rejected sparse/submodule restore must preserve gitlink mode");
      Assert (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
              "rejected sparse/submodule restore must preserve gitlink id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Sparse_Excluded_Submodule_Is_Rejected_Without_Mutation;

   procedure Linked_Worktree_Submodule_Restore_Isolates_Primary_Gitlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Gitlink_Id : constant String := "3456734567345673456734567345673456734567";
      Primary_Submodule_Dir : constant String := Join (Root, "deps/libfoo");
      Primary_Dirty : constant String := Join (Primary_Submodule_Dir, "dirty.txt");

      procedure Restore_Linked is
      begin
         Ada.Directories.Create_Path (Join (Work, "deps/libfoo"));
         Version.Test_Support.Write_Text_File
           (Join (Work, "deps/libfoo/dirty.txt"), "linked dirty" & LF);
         Version.Restore.Restore_Path ("deps");
      end Restore_Linked;
   begin
      Configure_Repo (Root);
      Ada.Directories.Create_Path (Primary_Submodule_Dir);
      Version.Test_Support.Write_Text_File (Primary_Dirty, "primary dirty" & LF);
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m linked-submodule-base");
      Version.Git_Fixtures.Run (Root, "git branch feature");

      Ada.Directories.Set_Directory (Root);
      Version.Worktrees.Add (Path => Work, Branch => "feature");
      Version.Files.With_Directory (Work, Restore_Linked'Access);

      Ada.Directories.Set_Directory (Root);
      Assert (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
              "linked restore must not alter primary gitlink mode");
      Assert (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
              "linked restore must not alter primary gitlink id");
      Assert (Version.Test_Support.Read_Text_File (Primary_Dirty) = "primary dirty",
              "linked restore must not touch primary submodule worktree");
      Version.Files.With_Directory (Work, Restore_Linked'Access);
      Version.Git_Fixtures.Run (Root, "git worktree remove --force '" & Work & "'");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Linked_Worktree_Submodule_Restore_Isolates_Primary_Gitlink;

   procedure Post_Commit_In_Linked_Worktree_Uses_Linked_Root
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Hook_Path : constant String := Join (Join (Join (Root, ".git"), "hooks"), "post-commit");
   begin
      Skip_Unless_POSIX;
      Configure_Repo (Root);
      Add_File (Root, "a.txt", "one" & LF);
      Save_All (Root, "base");
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Ada.Directories.Set_Directory (Root);
      Version.Worktrees.Add (Path => Work, Branch => "feature");

      Version.Test_Support.Write_Text_File
        (Hook_Path,
         "#!/bin/sh" & LF
         & "pwd > ""$GIT_WORK_TREE/post-commit-pwd.txt""" & LF
         & "printf '%s\n' ""$GIT_WORK_TREE"" > ""$GIT_WORK_TREE/post-commit-work-tree.txt""" & LF
         & "exit 0" & LF);
      Version.Git_Fixtures.Run (Root, "chmod +x .git/hooks/post-commit");

      Version.Test_Support.Write_Text_File (Join (Work, "a.txt"), "two" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Ada.Directories.Set_Directory (Work);
      Version.Write.Save ("linked worktree hook");
      Ada.Directories.Set_Directory (Root);

      Assert (Ada.Directories.Exists (Join (Work, "post-commit-pwd.txt")),
              "linked worktree post-commit marker must be written in linked worktree");
      Assert (not Ada.Directories.Exists (Join (Root, "post-commit-pwd.txt")),
              "linked worktree post-commit must not write marker in primary root");
      Assert (Ada.Strings.Fixed.Index
                (Version.Test_Support.Read_Text_File (Join (Work, "post-commit-pwd.txt")), Work) /= 0,
              "linked worktree hook cwd must be the linked worktree root");
      Assert (Ada.Strings.Fixed.Index
                (Version.Test_Support.Read_Text_File (Join (Work, "post-commit-work-tree.txt")), Work) /= 0,
              "linked worktree hook GIT_WORK_TREE must be the linked root");
      Version.Files.Delete_File_If_Exists (Join (Work, "post-commit-pwd.txt"));
      Version.Files.Delete_File_If_Exists (Join (Work, "post-commit-work-tree.txt"));

      Version.Worktrees.Remove (Work);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Post_Commit_In_Linked_Worktree_Uses_Linked_Root;

   procedure Archive_Sparse_Submodule_Is_Object_Based
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output : constant String := Join (Root, "sparse-submodule.tar");
      Gitlink_Id : constant String := "4567845678456784567845678456784567845678";
      Items : Version.Sparse.String_Vectors.Vector;
   begin
      Configure_Repo (Root);
      Add_File (Root, "src/main.adb", "procedure Main is begin null; end Main;" & LF);
      Version.Git_Fixtures.Run (Root, "git add src/main.adb");
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m archive-sparse-submodule");

      Ada.Directories.Set_Directory (Root);
      Items.Append ("src/");
      Version.Sparse.Set_From_Strings (Version.Repository.Open, Items);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Version.Files.Read_Binary_File (Output);
      begin
         Assert (Ada.Strings.Fixed.Index (Data, "src/main.adb") > 0,
                 "archive must include sparse-included ordinary file");
         Assert (Ada.Strings.Fixed.Index (Data, "deps/libfoo") > 0,
                 "archive must include committed gitlink even when sparse checkout omits it");
         Assert (Ada.Strings.Fixed.Index (Data, "Submodule: " & Gitlink_Id) > 0,
                 "archive must emit deterministic gitlink placeholder under sparse checkout");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Sparse_Submodule_Is_Object_Based;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Restore_Sparse_Submodule_Parent_Preserves_Boundary'Access,
         "Cross-feature: sparse parent restore preserves submodule boundary");
      Register_Routine
        (T, Restore_Sparse_Excluded_Submodule_Is_Rejected_Without_Mutation'Access,
         "Cross-feature: sparse-excluded submodule restore rejected without mutation");
      Register_Routine
        (T, Linked_Worktree_Submodule_Restore_Isolates_Primary_Gitlink'Access,
         "Cross-feature: linked worktree submodule restore isolates primary gitlink");
      Register_Routine
        (T, Post_Commit_In_Linked_Worktree_Uses_Linked_Root'Access,
         "Cross-feature: linked worktree post-commit uses linked root");
      Register_Routine
        (T, Archive_Sparse_Submodule_Is_Object_Based'Access,
         "Cross-feature: archive ignores sparse state but preserves gitlink placeholder");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Cross_Feature.Tests");
   end Name;

end Version.Cross_Feature.Tests;
