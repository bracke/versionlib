with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Objects;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Refs;
with Version.Repository;
with Version.Staging;
with Version.Test_Support;
with Version.Write;
with Version.Init;
with Version.Platform;
with Version.Sparse;
with Version.Stage;

package body Version.Restore.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Version.Platform.Platform_Kind;

   LF : constant Character := Character'Val (10);

   function LFS_Pointer return String is
     ("version https://git-lfs.github.com/spec/v1" & LF
      & "oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      & LF
      & "size 123456");

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

   procedure Stage_Gitlink (Root : String; Path : String; Id : String) is
   begin
      Version.Git_Fixtures.Run
        (Root, "git update-index --add --cacheinfo 160000," & Id & "," & Path);
   end Stage_Gitlink;

   procedure Stage_Symlink (Root : String; Path : String; Target : String) is
   begin
      Version.Git_Fixtures.Run
        (Root,
         "Target=$(printf '" & Target & "' | git hash-object -w --stdin) && "
         & "git update-index --add --cacheinfo 120000,$Target," & Path);
   end Stage_Symlink;

   procedure Assert_POSIX_Symlink
     (Root : String; Path : String; Target : String)
   is
      Output : constant String :=
        Version.Test_Support.Join (Root, "readlink.out");
   begin
      Version.Git_Fixtures.Run (Root, "test -L " & Path);
      Version.Git_Fixtures.Run (Root, "readlink " & Path & " > readlink.out");
      Assert
        (Version.Test_Support.Read_Text_File (Output) = Target,
         "materialized symlink has wrong target");
   end Assert_POSIX_Symlink;

   function Index_Entry_Mode
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos     : constant Natural := Version.Staging.Find_Entry (Entries, Path);
   begin
      if Pos = Natural'Last then
         return "";
      end if;

      return To_String (Entries.Element (Pos).Mode);
   end Index_Entry_Mode;

   function Index_Entry_Id
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos     : constant Natural := Version.Staging.Find_Entry (Entries, Path);
   begin
      if Pos = Natural'Last then
         return "";
      end if;

      return To_String (Entries.Element (Pos).Id);
   end Index_Entry_Id;

   procedure Restore_Preserves_LFS_Pointer_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "asset.bin");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "asset.bin", LFS_Pointer, "store LFS pointer");
      Version.Test_Support.Write_Text_File (File_Path, "dirty ordinary bytes" & LF);
      Version.Restore.Restore_Path ("asset.bin");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = LFS_Pointer,
         "restore must materialize LFS pointer text, not LFS content");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Preserves_LFS_Pointer_Text;


   procedure Restore_Smudges_LFS_Filtered_Pointer_To_Media
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Version.Test_Support.Join (Root, "asset.bin");
      Media : constant String := "large media" & LF;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.bin filter=lfs" & LF);
      Version.Files.Write_Binary_File (File_Path, Media);
      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("asset.bin");
      Version.Write.Save ("store cleaned LFS media");

      Version.Files.Write_Binary_File (File_Path, "dirty ordinary bytes" & LF);
      Version.Restore.Restore_Path ("asset.bin");

      Assert
        (Version.Files.Read_Binary_File (File_Path) = Media,
         "restore must smudge LFS pointer to cached media for filter=lfs paths");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Smudges_LFS_Filtered_Pointer_To_Media;

   procedure Restore_Recreates_Modified_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      File_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "original" & LF, "initial");

      Version.Test_Support.Write_Text_File (File_Path, "modified" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Restore.Restore_Working_Tree (Repo);
      end;

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "original",
         "restore must recreate committed file content");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Recreates_Modified_File;

   procedure Restore_Single_Path (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");

      B_Path : constant String := Version.Test_Support.Join (Root, "b.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "a original" & LF, "a");
      Save_File (Root, "b.txt", "b original" & LF, "b");

      Version.Test_Support.Write_Text_File (A_Path, "a modified" & LF);

      Version.Test_Support.Write_Text_File (B_Path, "b modified" & LF);

      Version.Restore.Restore_Path ("a.txt");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "a original",
         "restore path must restore selected file");

      Assert
        (Version.Test_Support.Read_Text_File (B_Path) = "b modified",
         "restore path must not touch other files");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Single_Path;

   procedure Restore_Deleted_Path_From_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      Ada.Directories.Delete_File (A_Path);
      Version.Restore.Restore_Path ("a.txt");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "one",
         "restore path must recreate deleted tracked file");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Deleted_Path_From_HEAD;

   procedure Restore_Nested_Path_From_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      Dir_Path  : constant String := Version.Test_Support.Join (Root, "dir");
      File_Path : constant String :=
        Version.Test_Support.Join (Dir_Path, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory (Dir_Path);
      Save_File (Root, "dir/a.txt", "nested" & LF, "nested");

      Version.Test_Support.Write_Text_File (File_Path, "changed" & LF);

      declare
         Raised : Boolean := False;
      begin
         begin
            Version.Restore.Restore_Path ("dir//a.txt");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "restore path must reject duplicate slashes");
      end;

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "changed",
         "failed restore path validation must not mutate working tree");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Nested_Path_From_HEAD;

   procedure Restore_Working_Tree_From_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      Version.Test_Support.Write_Text_File (A_Path, "two" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Test_Support.Write_Text_File (A_Path, "three" & LF);

      Version.Restore.Restore_Path_From_Index
        (Version.Repository.Open, "a.txt");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "two",
         "restore from index must use staged blob content");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Working_Tree_From_Index;

   procedure Restore_Staged_Path_From_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      Version.Test_Support.Write_Text_File (A_Path, "two" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Version.Restore.Restore_Staged_Path ("a.txt");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "two",
         "restore --staged must not touch the working tree");
      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Staged_Path_From_HEAD;

   procedure Restore_File_From_Older_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      declare
         First : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Save_File (Root, "a.txt", "two" & LF, "two");
         Version.Restore.Restore_Path_From_Source (First, "a.txt");
      end;

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "one",
         "restore --source must restore file content from explicit commit");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_File_From_Older_Commit;

   procedure Restore_Staged_Path_From_Explicit_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      declare
         First : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Save_File (Root, "a.txt", "two" & LF, "two");
         Version.Restore.Restore_Staged_Path_From_Source (First, "a.txt");
      end;

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "two",
         "restore --source --staged must not touch the working tree");

      Version.Restore.Restore_Path_From_Index
        (Version.Repository.Open, "a.txt");
      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "one",
         "restore --source --staged must stage the selected source blob");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Staged_Path_From_Explicit_Source;

   procedure Restore_Source_Missing_Deletes_Working_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");
      Version.Git_Fixtures.Run (Root, "git rm a.txt");
      Version.Write.Save ("remove");

      Version.Test_Support.Write_Text_File (A_Path, "untracked" & LF);
      Version.Restore.Restore_Path ("a.txt");

      Assert
        (not Ada.Directories.Exists (A_Path),
         "missing source path must delete working-tree file");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Source_Missing_Deletes_Working_File;

   procedure Restore_Source_Missing_Removes_Index_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");
      Version.Git_Fixtures.Run (Root, "git rm a.txt");
      Version.Write.Save ("remove");

      Version.Test_Support.Write_Text_File (A_Path, "staged" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Restore.Restore_Staged_Path ("a.txt");

      Version.Git_Fixtures.Run (Root, "git diff --cached --quiet");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Source_Missing_Removes_Index_Entry;

   procedure Restore_Binary_Path_Preserves_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir  : constant String := Ada.Directories.Current_Directory;
      A_Path   : constant String :=
        Version.Test_Support.Join (Root, "bin.dat");
      Original : constant String :=
        Character'Val (0) & "A" & Character'Val (255) & "Z";
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Files.Write_Binary_File (A_Path, Original);
      Version.Git_Fixtures.Run (Root, "git add bin.dat");
      Version.Write.Save ("binary");

      Version.Files.Write_Binary_File (A_Path, "changed");
      Version.Restore.Restore_Path ("bin.dat");

      Assert
        (Version.Files.Read_Binary_File (A_Path) = Original,
         "restore path must preserve binary blob bytes exactly");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Binary_Path_Preserves_Bytes;

   procedure Restore_Symlink_Path_From_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      Link_Path : constant String :=
        Version.Test_Support.Join (Root, "link-to-readme");
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Stage_Symlink (Root, "link-to-readme", "README.md");
      Version.Git_Fixtures.Run (Root, "git commit -m symlink-head");

      Version.Test_Support.Write_Text_File
        (Link_Path, "ordinary file blocks symlink" & LF);
      Version.Restore.Restore_Path ("link-to-readme");

      Assert_POSIX_Symlink (Root, "link-to-readme", "README.md");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Symlink_Path_From_HEAD;

   procedure Restore_Symlink_Path_From_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      Link_Path : constant String :=
        Version.Test_Support.Join (Root, "link-to-readme");
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "README.md", "readme" & LF, "base");
      Stage_Symlink (Root, "link-to-readme", "README.md");

      Version.Test_Support.Write_Text_File
        (Link_Path, "ordinary file blocks index symlink" & LF);
      Version.Restore.Restore_Path_From_Index
        (Version.Repository.Open, "link-to-readme");

      Assert_POSIX_Symlink (Root, "link-to-readme", "README.md");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Symlink_Path_From_Index;

   procedure Restore_Index_Missing_Deletes_Working_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      Version.Git_Fixtures.Run (Root, "git rm --cached a.txt");
      Version.Restore.Restore_Path_From_Index
        (Version.Repository.Open, "a.txt");

      Assert
        (not Ada.Directories.Exists (A_Path),
         "restore from index must delete the working file when the index path is missing");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Index_Missing_Deletes_Working_File;

   procedure Restore_Index_Directory_Path_Expands
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Dir_Path       : constant String :=
        Version.Test_Support.Join (Root, "dir");
      File_Path      : constant String :=
        Version.Test_Support.Join (Dir_Path, "a.txt");
      Untracked_Path : constant String :=
        Version.Test_Support.Join (Dir_Path, "untracked.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory (Dir_Path);
      Save_File (Root, "dir/a.txt", "nested" & LF, "nested");

      Version.Test_Support.Write_Text_File (File_Path, "changed" & LF);
      Version.Test_Support.Write_Text_File (Untracked_Path, "keep" & LF);

      Version.Restore.Restore_Path_From_Index (Version.Repository.Open, "dir");

      Assert
        (Version.Test_Support.Read_Text_File (File_Path) = "nested",
         "restore from index must expand directory prefixes to tracked paths");
      Assert
        (Version.Test_Support.Read_Text_File (Untracked_Path) = "keep",
         "directory restore must leave untracked files untouched");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Index_Directory_Path_Expands;

   procedure Restore_Commit_Deletes_Index_Only_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
      B_Path  : constant String := Version.Test_Support.Join (Root, "b.txt");
      First   : Version.Objects.Object_Id_Storage;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "a first" & LF, "first");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         First :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
      end;

      Save_File (Root, "b.txt", "b second" & LF, "second");

      Version.Test_Support.Write_Text_File (A_Path, "a dirty" & LF);
      Version.Test_Support.Write_Text_File (B_Path, "b dirty" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Restore.Restore_Working_Tree_For_Commit (Repo, First);
      end;

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "a first",
         "restore to earlier commit must write selected tree content");
      Assert
        (not Ada.Directories.Exists (B_Path),
         "restore to earlier commit must remove paths present only in current index");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Commit_Deletes_Index_Only_Paths;

   procedure Restore_Commit_Reuses_Command_Local_Caches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      Version.Test_Support.Write_Text_File (A_Path, "changed" & LF);

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
         Objects   : Version.Object_Cache.Object_Cache;
         Trees     : Version.Tree_Cache.Tree_Cache;
      begin
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Objects   => Objects,
            Trees     => Trees);
         Version.Restore.Write_Index_For_Commit
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Objects   => Objects,
            Trees     => Trees);

         Assert
           (Version.Tree_Cache.Cached_Tree_Count (Trees) = 1,
            "restore and index write should reuse the same flattened tree cache");
         Assert
           (Version.Object_Cache.Cached_Object_Count (Objects) >= 2,
            "restore cache should contain the commit and restored blob");
      end;

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "one",
         "cached restore should preserve restore semantics");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Commit_Reuses_Command_Local_Caches;

   procedure Restore_Directory_From_HEAD_Expands_Tracked_Files
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Dir_Path       : constant String :=
        Version.Test_Support.Join (Root, "dir");
      A_Path         : constant String :=
        Version.Test_Support.Join (Dir_Path, "a.txt");
      B_Path         : constant String :=
        Version.Test_Support.Join (Dir_Path, "b.bin");
      Untracked_Path : constant String :=
        Version.Test_Support.Join (Dir_Path, "untracked.txt");
      Binary         : constant String :=
        Character'Val (0) & "B" & Character'Val (255);
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory (Dir_Path);
      Version.Test_Support.Write_Text_File (A_Path, "a original" & LF);
      Version.Files.Write_Binary_File (B_Path, Binary);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt dir/b.bin");
      Version.Write.Save ("dir");

      Version.Test_Support.Write_Text_File (A_Path, "changed" & LF);
      Version.Files.Write_Binary_File (B_Path, "changed");
      Version.Test_Support.Write_Text_File (Untracked_Path, "keep" & LF);

      Version.Restore.Restore_Path ("dir");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "a original",
         "directory restore must restore tracked text file");
      Assert
        (Version.Files.Read_Binary_File (B_Path) = Binary,
         "directory restore must preserve binary blob bytes");
      Assert
        (Version.Test_Support.Read_Text_File (Untracked_Path) = "keep",
         "directory restore must leave untracked files untouched");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Directory_From_HEAD_Expands_Tracked_Files;

   procedure Restore_Directory_From_Explicit_Source_Removes_Source_Missing_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir  : constant String := Ada.Directories.Current_Directory;
      Dir_Path : constant String := Version.Test_Support.Join (Root, "dir");
      A_Path   : constant String :=
        Version.Test_Support.Join (Dir_Path, "a.txt");
      B_Path   : constant String :=
        Version.Test_Support.Join (Dir_Path, "b.txt");
      First    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory (Dir_Path);

      Version.Test_Support.Write_Text_File (A_Path, "a one" & LF);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt");
      Version.Write.Save ("first dir");
      First :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Test_Support.Write_Text_File (A_Path, "a two" & LF);
      Version.Test_Support.Write_Text_File (B_Path, "b two" & LF);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt dir/b.txt");
      Version.Write.Save ("second dir");

      Version.Test_Support.Write_Text_File (A_Path, "a dirty" & LF);
      Version.Test_Support.Write_Text_File (B_Path, "b dirty" & LF);

      Version.Restore.Restore_Path_From_Source (To_String (First), "dir");

      Assert
        (Version.Test_Support.Read_Text_File (A_Path) = "a one",
         "directory --source restore must restore files from the selected commit");
      Assert
        (not Ada.Directories.Exists (B_Path),
         "directory --source restore must remove tracked paths absent from the selected commit");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Directory_From_Explicit_Source_Removes_Source_Missing_File;

   procedure Restore_Staged_Directory_From_Explicit_Source_Removes_Source_Missing_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir  : constant String := Ada.Directories.Current_Directory;
      Dir_Path : constant String := Version.Test_Support.Join (Root, "dir");
      A_Path   : constant String :=
        Version.Test_Support.Join (Dir_Path, "a.txt");
      B_Path   : constant String :=
        Version.Test_Support.Join (Dir_Path, "b.txt");
      First    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory (Dir_Path);

      Version.Test_Support.Write_Text_File (A_Path, "a one" & LF);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt");
      Version.Write.Save ("first staged dir");
      First :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Test_Support.Write_Text_File (A_Path, "a two" & LF);
      Version.Test_Support.Write_Text_File (B_Path, "b two" & LF);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt dir/b.txt");
      Version.Write.Save ("second staged dir");

      Version.Test_Support.Write_Text_File (A_Path, "a staged" & LF);
      Version.Test_Support.Write_Text_File (B_Path, "b staged" & LF);
      Version.Git_Fixtures.Run (Root, "git add dir/a.txt dir/b.txt");

      Version.Restore.Restore_Staged_Path_From_Source (To_String (First), "dir");

      Version.Git_Fixtures.Run
        (Root,
         "git diff --cached --name-status | grep -qx 'M[[:space:]]dir/a.txt'");
      Version.Git_Fixtures.Run
        (Root,
         "git diff --cached --name-status | grep -qx 'D[[:space:]]dir/b.txt'");
      Version.Git_Fixtures.Run
        (Root,
         "test ""$(git diff --cached --name-only | grep -c '^dir/')"" = ""2""");
      Assert
        (Version.Test_Support.Read_Text_File (B_Path) = "b staged",
         "staged directory restore must not delete the working-tree file");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Staged_Directory_From_Explicit_Source_Removes_Source_Missing_Entry;

   procedure Restore_Directory_Rejects_Sparse_Excluded_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Items   : Version.Sparse.String_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Directory
        (Version.Test_Support.Join (Root, "src"));
      Ada.Directories.Create_Directory
        (Version.Test_Support.Join (Root, "docs"));
      Save_File (Root, "src/main.adb", "src" & LF, "src");
      Save_File (Root, "docs/manual.md", "docs" & LF, "docs");

      Items.Append ("src/");
      Version.Sparse.Set_From_Strings (Version.Repository.Open, Items);

      begin
         Version.Restore.Restore_Path ("docs");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "directory restore must reject sparse-excluded paths instead of materializing them");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Directory_Rejects_Sparse_Excluded_Path;

   procedure Restore_Submodule_Gitlink_Directory_Preserves_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Dirty_Path    : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "dirty.txt");
      Gitlink_Id    : constant String :=
        "1111111111111111111111111111111111111111";
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "dirty submodule content" & LF);
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m gitlink");

      Version.Test_Support.Write_Text_File (Dirty_Path, "still dirty" & LF);
      Version.Restore.Restore_Path ("deps");

      Assert
        (Ada.Directories.Exists (Submodule_Dir),
         "directory restore must preserve existing submodule worktree directory");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path) = "still dirty",
         "directory restore must not recurse into or overwrite submodule worktree files");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "directory restore must preserve gitlink index mode");
      Assert
        (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
         "directory restore must preserve gitlink object id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Submodule_Gitlink_Directory_Preserves_Worktree;

   procedure Restore_Submodule_Parent_Restores_Files_But_Not_Submodule
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Regular_Path  : constant String :=
        Version.Test_Support.Join (Root, "deps/readme.txt");
      Dirty_Path    : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "payload.txt");
      Gitlink_Id    : constant String :=
        "2222222222222222222222222222222222222222";
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Regular_Path, "tracked one" & LF);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "submodule dirty one" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m deps-with-submodule");

      Version.Test_Support.Write_Text_File
        (Regular_Path, "tracked changed" & LF);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "submodule dirty two" & LF);
      Version.Restore.Restore_Path ("deps");

      Assert
        (Version.Test_Support.Read_Text_File (Regular_Path) = "tracked one",
         "parent directory restore must restore ordinary tracked files");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path)
         = "submodule dirty two",
         "parent directory restore must not recurse into submodule worktree contents");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "parent directory restore must leave gitlink tracked as a gitlink");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Submodule_Parent_Restores_Files_But_Not_Submodule;

   procedure Restore_Staged_Submodule_Directory_Preserves_Gitlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Dirty_Path    : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "dirty.txt");
      First_Id      : constant String :=
        "3333333333333333333333333333333333333333";
      Second_Id     : constant String :=
        "4444444444444444444444444444444444444444";
      First_Commit  : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Dirty_Path, "dirty before" & LF);
      Stage_Gitlink (Root, "deps/libfoo", First_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m gitlink-one");
      First_Commit :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Stage_Gitlink (Root, "deps/libfoo", Second_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m gitlink-two");
      Version.Test_Support.Write_Text_File (Dirty_Path, "dirty after" & LF);

      Version.Restore.Restore_Staged_Path_From_Source
        (To_String (First_Commit), "deps");

      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "staged directory restore must preserve gitlink mode");
      Assert
        (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = First_Id,
         "staged directory restore must restore gitlink object id from source");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path) = "dirty after",
         "staged directory restore must not touch submodule working tree files");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Staged_Submodule_Directory_Preserves_Gitlink;

   procedure Restore_Submodule_Dirty_Worktree_Is_Not_Overwritten
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Regular_Path  : constant String :=
        Version.Test_Support.Join (Root, "deps/readme.txt");
      Dirty_Path    : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "dirty.txt");
      First_Id      : constant String :=
        "5555555555555555555555555555555555555555";
      Second_Id     : constant String :=
        "6666666666666666666666666666666666666666";
      First_Commit  : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File (Regular_Path, "first readme" & LF);
      Version.Test_Support.Write_Text_File (Dirty_Path, "dirty first" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Stage_Gitlink (Root, "deps/libfoo", First_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m first-submodule-parent");
      First_Commit :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Test_Support.Write_Text_File
        (Regular_Path, "second readme" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Stage_Gitlink (Root, "deps/libfoo", Second_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m second-submodule-parent");
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "dirty local submodule" & LF);

      Version.Restore.Restore_Path_From_Source (To_String (First_Commit), "deps");

      Assert
        (Version.Test_Support.Read_Text_File (Regular_Path) = "first readme",
         "restore from source must restore ordinary parent files");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path)
         = "dirty local submodule",
         "restore from source must not overwrite dirty submodule worktree content");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "working-tree restore must not remove the superproject gitlink entry");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Submodule_Dirty_Worktree_Is_Not_Overwritten;

   procedure Restore_Source_Missing_Submodule_Preserves_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root                   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir                : constant String :=
        Ada.Directories.Current_Directory;
      Submodule_Dir          : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Dirty_Path             : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "local.txt");
      Readme_Path            : constant String :=
        Version.Test_Support.Join (Root, "deps/readme.txt");
      Gitlink_Id             : constant String :=
        "7777777777777777777777777777777777777777";
      Source_Without_Gitlink : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Version.Test_Support.Join (Root, "deps"));
      Version.Test_Support.Write_Text_File (Readme_Path, "source readme" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Version.Git_Fixtures.Run (Root, "git commit -m source-without-gitlink");
      Source_Without_Gitlink :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "local submodule data" & LF);
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m add-gitlink");
      Version.Test_Support.Write_Text_File
        (Readme_Path, "changed readme" & LF);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "local submodule changed" & LF);

      Version.Restore.Restore_Path_From_Source
        (To_String (Source_Without_Gitlink), "deps");

      Assert
        (Version.Test_Support.Read_Text_File (Readme_Path) = "source readme",
         "source restore must restore ordinary files from selected source");
      Assert
        (Ada.Directories.Exists (Submodule_Dir),
         "source restore must preserve submodule worktree when source lacks gitlink");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path)
         = "local submodule changed",
         "source restore must not delete or recurse into source-missing submodule worktree");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "working-tree-only source restore must not remove existing gitlink index entry");
      Assert
        (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
         "working-tree-only source restore must preserve existing gitlink object id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Source_Missing_Submodule_Preserves_Worktree;

   procedure Restore_Staged_Source_Missing_Submodule_Removes_Gitlink_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root                   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir                : constant String :=
        Ada.Directories.Current_Directory;
      Submodule_Dir          : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Dirty_Path             : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "local.txt");
      Readme_Path            : constant String :=
        Version.Test_Support.Join (Root, "deps/readme.txt");
      Gitlink_Id             : constant String :=
        "8888888888888888888888888888888888888888";
      Source_Without_Gitlink : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Version.Test_Support.Join (Root, "deps"));
      Version.Test_Support.Write_Text_File (Readme_Path, "source readme" & LF);
      Version.Git_Fixtures.Run (Root, "git add deps/readme.txt");
      Version.Git_Fixtures.Run
        (Root, "git commit -m staged-source-without-gitlink");
      Source_Without_Gitlink :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "dirty submodule" & LF);
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m staged-add-gitlink");
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "dirty submodule kept" & LF);

      Version.Restore.Restore_Staged_Path_From_Source
        (To_String (Source_Without_Gitlink), "deps");

      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "",
         "staged source restore must remove a gitlink absent from the selected source");
      Assert
        (Ada.Directories.Exists (Submodule_Dir),
         "staged restore must not delete the submodule worktree directory");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path)
         = "dirty submodule kept",
         "staged restore must not touch source-missing submodule worktree files");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Staged_Source_Missing_Submodule_Removes_Gitlink_Only;

   procedure Restore_Gitlink_Rejects_File_At_Submodule_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Submodule_Path : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Gitlink_Id     : constant String :=
        "9999999999999999999999999999999999999999";
      Gitlink_Commit : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Raised         : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Version.Test_Support.Join (Root, "deps"));
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m gitlink-source");
      Gitlink_Commit :=
        Version.Objects.To_Object_Id
          (Version.Refs.Current_Commit_Id (Version.Repository.Open));

      Version.Test_Support.Write_Text_File
        (Submodule_Path, "ordinary file blocks submodule" & LF);

      begin
         Version.Restore.Restore_Path_From_Source
           (To_String (Gitlink_Commit), "deps");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "restore must reject an ordinary file that blocks a gitlink/submodule path");
      Assert
        (Version.Test_Support.Read_Text_File (Submodule_Path)
         = "ordinary file blocks submodule",
         "failed gitlink restore must leave blocking ordinary file unchanged");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "failed gitlink restore must not mutate the index entry");
      Assert
        (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
         "failed gitlink restore must preserve the gitlink object id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Gitlink_Rejects_File_At_Submodule_Path;

   procedure Restore_Direct_Gitlink_Path_Preserves_Submodule_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root          : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir       : constant String := Ada.Directories.Current_Directory;
      Submodule_Dir : constant String :=
        Version.Test_Support.Join (Root, "deps/libfoo");
      Dirty_Path    : constant String :=
        Version.Test_Support.Join (Submodule_Dir, "dirty.txt");
      Gitlink_Id    : constant String :=
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Ada.Directories.Create_Path (Submodule_Dir);
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "submodule local" & LF);
      Stage_Gitlink (Root, "deps/libfoo", Gitlink_Id);
      Version.Git_Fixtures.Run (Root, "git commit -m direct-gitlink");
      Version.Test_Support.Write_Text_File
        (Dirty_Path, "submodule local changed" & LF);

      Version.Restore.Restore_Path ("deps/libfoo");

      Assert
        (Ada.Directories.Exists (Submodule_Dir),
         "direct gitlink restore must preserve submodule worktree directory");
      Assert
        (Version.Test_Support.Read_Text_File (Dirty_Path)
         = "submodule local changed",
         "direct gitlink restore must not recurse into submodule worktree contents");
      Assert
        (Index_Entry_Mode (Version.Repository.Open, "deps/libfoo") = "160000",
         "direct gitlink restore must preserve gitlink index mode");
      Assert
        (Index_Entry_Id (Version.Repository.Open, "deps/libfoo") = Gitlink_Id,
         "direct gitlink restore must preserve gitlink object id");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Direct_Gitlink_Path_Preserves_Submodule_Worktree;

   procedure Restore_Rejects_Unsafe_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "one" & LF, "one");

      begin
         Version.Restore.Restore_Path ("../a.txt");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "restore must reject path traversal");

      Raised := False;
      begin
         Version.Restore.Restore_Path (".git/config");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "restore must reject paths inside .git");

      Raised := False;
      begin
         Version.Restore.Restore_Path ("");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "restore must reject empty paths");

      Raised := False;
      begin
         Version.Restore.Restore_Path ("/tmp/a.txt");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "restore must reject absolute paths");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Rejects_Unsafe_Paths;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Restore_Recreates_Modified_File'Access,
         "Restore: committed file replaces modified working tree file");

      Register_Routine
        (T,
         Restore_Preserves_LFS_Pointer_Text'Access,
         "Restore: LFS pointer restored as ordinary text");

      Register_Routine
        (T,
         Restore_Smudges_LFS_Filtered_Pointer_To_Media'Access,
         "Restore: LFS filter smudges pointer to media");

      Register_Routine
        (T, Restore_Single_Path'Access, "Restore: single path only");

      Register_Routine
        (T,
         Restore_Deleted_Path_From_HEAD'Access,
         "Restore: deleted tracked path from HEAD");
      Register_Routine
        (T,
         Restore_Nested_Path_From_HEAD'Access,
         "Restore: nested path from HEAD");
      Register_Routine
        (T,
         Restore_Working_Tree_From_Index'Access,
         "Restore: working tree path from index");
      Register_Routine
        (T,
         Restore_Staged_Path_From_HEAD'Access,
         "Restore: staged path from HEAD");
      Register_Routine
        (T,
         Restore_File_From_Older_Commit'Access,
         "Restore: file from older commit");
      Register_Routine
        (T,
         Restore_Staged_Path_From_Explicit_Source'Access,
         "Restore: staged file from explicit source");
      Register_Routine
        (T,
         Restore_Source_Missing_Deletes_Working_File'Access,
         "Restore: source missing deletes working file");
      Register_Routine
        (T,
         Restore_Source_Missing_Removes_Index_Entry'Access,
         "Restore: source missing removes staged entry");
      Register_Routine
        (T,
         Restore_Binary_Path_Preserves_Bytes'Access,
         "Restore: binary path preserves bytes");
      Register_Routine
        (T,
         Restore_Symlink_Path_From_HEAD'Access,
         "Restore: symlink path from HEAD materializes link");
      Register_Routine
        (T,
         Restore_Symlink_Path_From_Index'Access,
         "Restore: symlink path from index materializes link");
      Register_Routine
        (T,
         Restore_Index_Missing_Deletes_Working_File'Access,
         "Restore: index missing deletes working file");
      Register_Routine
        (T,
         Restore_Index_Directory_Path_Expands'Access,
         "Restore: index directory path expands");
      Register_Routine
        (T,
         Restore_Commit_Deletes_Index_Only_Paths'Access,
         "Restore: commit restore removes index-only paths");
      Register_Routine
        (T,
         Restore_Commit_Reuses_Command_Local_Caches'Access,
         "Restore: command-local caches reused across checkout restore");
      Register_Routine
        (T,
         Restore_Directory_From_HEAD_Expands_Tracked_Files'Access,
         "Restore: directory path expands tracked files");
      Register_Routine
        (T,
         Restore_Directory_From_Explicit_Source_Removes_Source_Missing_File'Access,
         "Restore: source directory removes missing tracked files");
      Register_Routine
        (T,
         Restore_Staged_Directory_From_Explicit_Source_Removes_Source_Missing_Entry'Access,
         "Restore: staged source directory removes missing entries");
      Register_Routine
        (T,
         Restore_Directory_Rejects_Sparse_Excluded_Path'Access,
         "Restore: directory restore rejects sparse-excluded path");
      Register_Routine
        (T,
         Restore_Submodule_Gitlink_Directory_Preserves_Worktree'Access,
         "Restore: submodule gitlink directory preserves worktree");
      Register_Routine
        (T,
         Restore_Submodule_Parent_Restores_Files_But_Not_Submodule'Access,
         "Restore: parent directory restores files but not submodule contents");
      Register_Routine
        (T,
         Restore_Staged_Submodule_Directory_Preserves_Gitlink'Access,
         "Restore: staged submodule directory preserves gitlink");
      Register_Routine
        (T,
         Restore_Submodule_Dirty_Worktree_Is_Not_Overwritten'Access,
         "Restore: dirty submodule worktree is not overwritten");
      Register_Routine
        (T,
         Restore_Source_Missing_Submodule_Preserves_Worktree'Access,
         "Restore: source-missing submodule preserves worktree");
      Register_Routine
        (T,
         Restore_Staged_Source_Missing_Submodule_Removes_Gitlink_Only'Access,
         "Restore: staged source-missing submodule removes gitlink only");
      Register_Routine
        (T,
         Restore_Gitlink_Rejects_File_At_Submodule_Path'Access,
         "Restore: gitlink rejects ordinary file conflict");
      Register_Routine
        (T,
         Restore_Direct_Gitlink_Path_Preserves_Submodule_Worktree'Access,
         "Restore: direct gitlink path preserves submodule worktree");
      Register_Routine
        (T,
         Restore_Rejects_Unsafe_Paths'Access,
         "Restore: rejects unsafe paths");

   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Restore");
   end Name;

end Version.Restore.Tests;
