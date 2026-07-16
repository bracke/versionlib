with Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with GNAT.OS_Lib;
with GNAT.SHA256;

with Version.Git_Fixtures;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Test_Support;
with Version.Init;
with Version.Platform;
with Version.Stage;
with Version.Files;
with Version.Checkout;

package body Version.Write.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use type Version.Platform.Platform_Kind;
   use AUnit.Test_Cases.Registration;

   function LFS_Pointer return String is
     ("version https://git-lfs.github.com/spec/v1" & Character'Val (10)
      & "oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      & Character'Val (10)
      & "size 123456");

   --  Build a tree from explicit, unsorted entries and confirm the id equals
   --  the known `git mktree` value (entries a=hello, b=world). This pins both
   --  git tree-order sorting and the object serialisation/hash.
   procedure Write_Tree_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Hello : constant Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "hello" & LF);
         World : constant Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "world" & LF);
         Entries : Tree_Entry_Vectors.Vector;
      begin
         --  Deliberately out of order: Write_Tree must sort b after a.
         Entries.Append
           (Tree_Entry'
              (Path => Ada.Strings.Unbounded.To_Unbounded_String ("b"),
               Id   => World, Kind => Tree_Blob,
               Mode => Ada.Strings.Unbounded.To_Unbounded_String ("100644")));
         Entries.Append
           (Tree_Entry'
              (Path => Ada.Strings.Unbounded.To_Unbounded_String ("a"),
               Id   => Hello, Kind => Tree_Blob,
               Mode => Ada.Strings.Unbounded.To_Unbounded_String ("100644")));

         Assert
           (To_String (Version.Write.Write_Tree (Repo, Entries))
            = "87c9da4bbac768329fcff3d3fc80964f5f574e02",
            "Write_Tree matches git mktree oid");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Write_Tree_Matches_Git;

   procedure Save_Root_File_As_Git_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "hello" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("initial");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String :=
           Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "save must update current branch to a valid commit id");

         Version.Git_Fixtures.Run (Root, "git fsck --strict");
         Version.Git_Fixtures.Run (Root, "git log --oneline -1");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Root_File_As_Git_Commit;

   procedure Save_Stores_LFS_Pointer_As_Ordinary_Blob
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Ada.Strings.Unbounded;

      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Files.Write_Binary_File
        (Version.Test_Support.Join (Root, "asset.bin"), LFS_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("store LFS pointer");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id
                (Version.Refs.Current_Commit_Id (Repo)));
         Tree : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree
             (Repo, Version.Objects.Commit_Tree_Id (Commit));
         Zero_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id ("0000000000000000000000000000000000000000");
         Blob_Id : Version.Objects.Hex_Object_Id := Zero_Id;
      begin
         for I in Tree.First_Index .. Tree.Last_Index loop
            if To_String (Tree.Element (I).Path) = "asset.bin" then
               Blob_Id := Tree.Element (I).Id;
            end if;
         end loop;

         Assert (Blob_Id /= Zero_Id,
                 "committed tree must contain LFS pointer path");

         declare
            Blob : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Blob_Id);
         begin
            Assert (Version.Objects.Kind (Blob) = Version.Objects.Blob_Object,
                    "LFS pointer must be stored as an ordinary blob");
            Assert (Version.Objects.Content (Blob) = LFS_Pointer,
                    "committed LFS pointer blob bytes must be preserved");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Stores_LFS_Pointer_As_Ordinary_Blob;

   procedure Save_Cleans_LFS_Tracked_File_To_Pointer
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Ada.Strings.Unbounded;

      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Media   : constant String := "large media" & Character'Val (10);
      Oid     : constant String := GNAT.SHA256.Digest (Media);
      Pointer : constant String :=
        "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:" & Oid & Character'Val (10)
        & "size" & Natural'Image (Media'Length) & Character'Val (10);
      LFS_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Root, ".git"), "lfs"),
                 "objects"),
              Oid (Oid'First .. Oid'First + 1)),
           Version.Test_Support.Join
             (Oid (Oid'First + 2 .. Oid'First + 3), Oid));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, ".gitattributes"),
         "*.bin filter=lfs" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Version.Test_Support.Join (Root, "asset.bin"), Media);

      Ada.Directories.Set_Directory (Root);
      Version.Stage.Stage_Path (".gitattributes");
      Version.Stage.Stage_Path ("asset.bin");
      Version.Write.Save ("clean LFS media");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id
                (Version.Refs.Current_Commit_Id (Repo)));
         Tree : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree
             (Repo, Version.Objects.Commit_Tree_Id (Commit));
         Zero_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id ("0000000000000000000000000000000000000000");
         Blob_Id : Version.Objects.Hex_Object_Id := Zero_Id;
      begin
         for I in Tree.First_Index .. Tree.Last_Index loop
            if To_String (Tree.Element (I).Path) = "asset.bin" then
               Blob_Id := Tree.Element (I).Id;
            end if;
         end loop;

         Assert (Blob_Id /= Zero_Id,
                 "committed tree must contain LFS-cleaned path");

         declare
            Blob : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Blob_Id);
         begin
            Assert (Version.Objects.Kind (Blob) = Version.Objects.Blob_Object,
                    "LFS-cleaned path must still be a blob");
            Assert (Version.Objects.Content (Blob) = Pointer,
                    "LFS-cleaned blob must contain pointer bytes");
         end;
      end;

      Assert
        (Version.Files.Read_Binary_File (LFS_Path) = Media,
         "LFS clean must cache media in local lfs storage");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Cleans_LFS_Tracked_File_To_Pointer;

   procedure Save_Preserves_Staged_Executable_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Exec_Path : constant String := Version.Test_Support.Join (Root, "exec.sh");
      Tree_Line_Path : constant String :=
        Version.Test_Support.Join (Root, "tree-line.txt");
      Expected_Mode : constant String :=
        (if Version.Platform.Supports_Executable_Bit
         then "100755"
         else "100644");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Exec_Path, "echo exec" & Character'Val (10));
      GNAT.OS_Lib.Set_Executable (Exec_Path);

      Ada.Directories.Set_Directory (Root);
      Version.Stage.Stage_Path ("exec.sh");
      Version.Write.Save ("executable mode");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD exec.sh > tree-line.txt");

      declare
         Tree_Line : constant String :=
           Version.Test_Support.Read_Text_File (Tree_Line_Path);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Tree_Line, Expected_Mode & " blob ") /= 0,
            "committed executable mode must match platform staging mode");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Preserves_Staged_Executable_Mode;

   procedure Save_Preserves_Staged_Symlink_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Tree_Line_Path : constant String :=
        Version.Test_Support.Join (Root, "symlink-tree-line.txt");
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return;
      end if;

      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Git_Fixtures.Run (Root, "ln -s missing-target link.txt");

      Ada.Directories.Set_Directory (Root);
      Version.Stage.Stage_Path ("link.txt");
      Version.Write.Save ("symlink mode");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "git ls-tree HEAD link.txt > symlink-tree-line.txt");

      declare
         Tree_Line : constant String :=
           Version.Test_Support.Read_Text_File (Tree_Line_Path);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tree_Line, "120000 blob ") /= 0,
            "committed symlink must use Git symlink mode");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Preserves_Staged_Symlink_Mode;

   procedure Save_Nested_File_As_Git_Commit
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Make_Directory
      (Version.Test_Support.Join (Root, "src"));

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Root, "src/main.adb"),
         "procedure Main is begin null; end Main;"
         & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add src/main.adb");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("nested");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
         Version.Repository.Open;

         Commit : constant String :=
         Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
         (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "save must update current branch to a valid commit id");

         Version.Git_Fixtures.Run (Root, "git fsck --strict");

         Version.Git_Fixtures.Run
         (Root,
            "git ls-tree -r --name-only HEAD | grep '^src/main.adb$'");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Nested_File_As_Git_Commit;

   procedure Save_Amend_Replaces_Current_Commit
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
      (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("first");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
         Version.Repository.Open;

         First_Commit : constant String :=
         Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Test_Support.Write_Text_File
         (File_Path,
            "two" & Character'Val (10));

         Version.Git_Fixtures.Run (Root, "git add a.txt");

         Version.Write.Save_Amend ("amended");

         declare
            Second_Commit : constant String :=
            Version.Refs.Current_Commit_Id (Repo);
         begin
            Assert
            (Version.Objects.Is_Valid_Hex_Object_Id (Second_Commit),
               "amended commit id must be valid");

            Assert
            (Second_Commit /= First_Commit,
               "amend must replace current commit with a new commit id");

            Version.Git_Fixtures.Run
            (Root,
               "test ""$(git log --format=%s -1)"" = ""amended""");

            Version.Git_Fixtures.Run
            (Root,
               "test ""$(git rev-list --count HEAD)"" = ""1""");

            Version.Git_Fixtures.Run
            (Root,
               "git fsck --strict");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Amend_Replaces_Current_Commit;

   procedure Save_Uses_Git_Config_Identity
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email bent@example.test");
      Version.Git_Fixtures.Run (Root, "git config user.name Bent");

      Version.Test_Support.Write_Text_File
      (File_Path,
         "identity" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("identity");

      Version.Git_Fixtures.Run
      (Root,
         "test ""$(git log -1 --format=%an)"" = ""Bent""");

      Version.Git_Fixtures.Run
      (Root,
         "test ""$(git log -1 --format=%ae)"" = ""bent@example.test""");

      Version.Git_Fixtures.Run
      (Root,
         "test ""$(git log -1 --format=%cn)"" = ""Bent""");

      Version.Git_Fixtures.Run
      (Root,
         "test ""$(git log -1 --format=%ce)"" = ""bent@example.test""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Uses_Git_Config_Identity;

   procedure Write_Commit_With_Two_Parents
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      File_Path : constant String :=
      Version.Test_Support.Join (Root, "a.txt");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
      (File_Path,
         "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("base");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
         Version.Repository.Open;

         Parent_A : constant Version.Objects.Hex_Object_Id :=
         Version.Objects.To_Object_Id
            (Version.Refs.Current_Commit_Id (Repo));

         Tree_Id : constant Version.Objects.Hex_Object_Id :=
         Version.Objects.Commit_Tree_Id
            (Version.Objects.Read_Object (Repo, Parent_A));

         Parents : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Parents.Append (Parent_A);
         Parents.Append (Parent_A);

         declare
            Merge_Commit : constant Version.Objects.Hex_Object_Id :=
            Version.Write.Write_Commit_With_Parents
               (Repo    => Repo,
               Tree_Id => Tree_Id,
               Parents => Parents,
               Message => "merge-like");

            Obj : constant Version.Objects.Git_Object :=
            Version.Objects.Read_Object
               (Repo,
               Merge_Commit);

            Read_Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
            Version.Objects.Commit_Parent_Ids (Obj);
         begin
            Assert
            (Natural (Read_Parents.Length) = 2,
               "commit writer must preserve two parent lines");

            Version.Git_Fixtures.Run
            (Root,
               "git fsck --strict");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Write_Commit_With_Two_Parents;

   function Test_Repo (Root : String) return Version.Repository.Repository_Handle is
   begin
      return Version.Repository.Open_Git_Dir
        (Version.Test_Support.Join (Root, ".git"));
   end Test_Repo;

   function Head_Reflog_Path (Root : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "HEAD");
   end Head_Reflog_Path;

   function Branch_Reflog_Path (Root, Name : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "refs/heads/" & Name);
   end Branch_Reflog_Path;

   procedure Save_Creates_HEAD_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Log_Path : constant String := Head_Reflog_Path (Root);
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "head reflog" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("initial reflog");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String :=
           Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Ada.Directories.Exists (Log_Path),
            "save must create .git/logs/HEAD");

         declare
            Text : constant String :=
              Version.Test_Support.Read_Text_File (Log_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Text,
                  "0000000000000000000000000000000000000000 "
                  & Commit) /= 0,
               "HEAD reflog must contain old zero id and new commit id");

            Assert
              (Ada.Strings.Fixed.Index (Text, "Test <test@example.com>") /= 0,
               "HEAD reflog must contain configured identity");

            Assert
              (Ada.Strings.Fixed.Index (Text, "save: initial reflog") /= 0,
               "HEAD reflog must contain save message");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Creates_HEAD_Reflog;

   procedure Save_Creates_Current_Branch_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Log_Path : constant String := Branch_Reflog_Path (Root, "main");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Version.Test_Support.Write_Text_File
        (File_Path,
         "branch reflog" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);

      Version.Write.Save ("branch reflog");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String :=
           Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Ada.Directories.Exists (Log_Path),
            "save must create .git/logs/refs/heads/main");

         declare
            Text : constant String :=
              Version.Test_Support.Read_Text_File (Log_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Text,
                  "0000000000000000000000000000000000000000 "
                  & Commit) /= 0,
               "branch reflog must contain old zero id and new commit id");

            Assert
              (Ada.Strings.Fixed.Index (Text, "Test <test@example.com>") /= 0,
               "branch reflog must contain configured identity");

            Assert
              (Ada.Strings.Fixed.Index (Text, "save: branch reflog") /= 0,
               "branch reflog must contain save message");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Creates_Current_Branch_Reflog;

   function Head_Reflog_Lock_Path (Root : String) return String is
   begin
      return Head_Reflog_Path (Root) & ".lock";
   end Head_Reflog_Lock_Path;

   function Branch_Reflog_Lock_Path (Root, Name : String) return String is
   begin
      return Branch_Reflog_Path (Root, Name) & ".lock";
   end Branch_Reflog_Lock_Path;

   function Index_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join (Root, ".git/index");
   end Index_Path;

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Save_HEAD_Reflog_Lock_Preserves_Attached_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String := Head_Reflog_Lock_Path (Root);
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (A_Path, "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Old_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Test_Support.Write_Text_File (A_Path, "two" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");

         declare
            Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
         begin
            Version.Test_Support.Write_Text_File (Lock_Path, "locked" & Character'Val (10));

            begin
               Version.Write.Save ("two");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "stale HEAD reflog lock must fail save");
            Assert
              (Version.Refs.Current_Commit_Id (Repo) = Old_Id,
               "failed save must preserve attached branch tip");
            Assert
              (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
               "failed save must preserve index bytes");
            Assert
              (Version.Test_Support.Read_Text_File (A_Path) = "two",
               "failed save must preserve working-tree content");
            Assert
              (Ada.Directories.Exists (Lock_Path),
               "failed save must preserve stale HEAD reflog lock");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_HEAD_Reflog_Lock_Preserves_Attached_State;

   procedure Save_Branch_Reflog_Lock_Preserves_Attached_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String := Branch_Reflog_Lock_Path (Root, "main");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (A_Path, "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Old_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Test_Support.Write_Text_File (A_Path, "two" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");

         declare
            Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
         begin
            Version.Test_Support.Write_Text_File (Lock_Path, "locked" & Character'Val (10));

            begin
               Version.Write.Save ("two");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "stale branch reflog lock must fail save");
            Assert
              (Version.Refs.Current_Commit_Id (Repo) = Old_Id,
               "failed branch-reflog save must preserve branch tip");
            Assert
              (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
               "failed branch-reflog save must preserve index bytes");
            Assert
              (Version.Test_Support.Read_Text_File (A_Path) = "two",
               "failed branch-reflog save must preserve working-tree content");
            Assert
              (Ada.Directories.Exists (Lock_Path),
               "failed save must preserve stale branch reflog lock");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Branch_Reflog_Lock_Preserves_Attached_State;

   procedure Save_HEAD_Reflog_Lock_Preserves_Detached_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Lock_Path : constant String := Head_Reflog_Lock_Path (Root);
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (A_Path, "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("one");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Checkout.Checkout_Commit (Version.Objects.To_Object_Id (First));
         Version.Test_Support.Write_Text_File (A_Path, "two" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");

         declare
            Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
         begin
            Version.Test_Support.Write_Text_File (Lock_Path, "locked" & Character'Val (10));

            begin
               Version.Write.Save ("two");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "stale detached HEAD reflog lock must fail save");
            Assert
              (Version.Refs.Is_Detached (Repo),
               "failed detached save must preserve detached state");
            Assert
              (Version.Refs.Current_Commit_Id (Repo) = First,
               "failed detached save must preserve detached HEAD id");
            Assert
              (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
               "failed detached save must preserve index bytes");
            Assert
              (Version.Test_Support.Read_Text_File (A_Path) = "two",
               "failed detached save must preserve working-tree content");
            Assert
              (Ada.Directories.Exists (Lock_Path),
               "failed detached save must preserve stale HEAD reflog lock");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_HEAD_Reflog_Lock_Preserves_Detached_State;

   procedure Save_Amend_Appends_Reflog_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      File_Path : constant String :=
        Version.Test_Support.Join (Root, "a.txt");

      Head_Log : constant String := Head_Reflog_Path (Root);

      Branch_Log : constant String := Branch_Reflog_Path (Root, "main");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (File_Path,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("first");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Test_Support.Write_Text_File
           (File_Path,
            "two" & Character'Val (10));

         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Write.Save_Amend ("amended reflog");

         declare
            Second_Commit : constant String :=
              Version.Refs.Current_Commit_Id (Repo);

            Head_Text : constant String :=
              Version.Test_Support.Read_Text_File (Head_Log);

            Branch_Text : constant String :=
              Version.Test_Support.Read_Text_File (Branch_Log);

            Expected_Ids : constant String :=
              First_Commit & " " & Second_Commit;
         begin
            Assert
              (Ada.Strings.Fixed.Index (Head_Text, Expected_Ids) /= 0,
               "amend HEAD reflog must contain old and amended commit ids");

            Assert
              (Ada.Strings.Fixed.Index (Head_Text, "save --amend: amended reflog") /= 0,
               "amend HEAD reflog must contain amend message");

            Assert
              (Ada.Strings.Fixed.Index (Branch_Text, Expected_Ids) /= 0,
               "amend branch reflog must contain old and amended commit ids");

            Assert
              (Ada.Strings.Fixed.Index (Branch_Text, "save --amend: amended reflog") /= 0,
               "amend branch reflog must contain amend message");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Amend_Appends_Reflog_Entry;

   --  Regression: Save must honour commit.gpgSign (so a plain `save` produces a
   --  signed commit when configured), Sign_Force must sign regardless, and
   --  Sign_Disable must override the config. A fake gpg on PATH stands in for a
   --  real key so the suite stays self-contained.
   procedure Save_Honours_Commit_Signing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      LF : constant Character := Character'Val (10);
      Had_Path : constant Boolean := Ada.Environment_Variables.Exists ("PATH");
      Old_Path : constant String :=
        (if Had_Path then Ada.Environment_Variables.Value ("PATH") else "");
      Bin_Dir : constant String := Version.Test_Support.Join (Root, "fake-bin");

      function HEAD_Is_Signed return Boolean is
      begin
         --  git cat-file exits 0 and grep finds the header only when signed.
         Version.Git_Fixtures.Run
           (Root,
            "git cat-file commit HEAD"
            & " | grep -q '^gpgsig -----BEGIN PGP SIGNATURE-----'");
         return True;
      exception
         when others =>
            return False;
      end HEAD_Is_Signed;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      if not Ada.Directories.Exists (Bin_Dir) then
         Ada.Directories.Create_Directory (Bin_Dir);
      end if;
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Bin_Dir, "gpg"),
         "#!/bin/sh" & LF
         & "out=" & LF
         & "while [ $# -gt 0 ]; do" & LF
         & "  if [ ""$1"" = ""--output"" ]; then shift; out=$1; fi" & LF
         & "  shift" & LF
         & "done" & LF
         & "cat > ""$out"" <<'EOF'" & LF
         & "-----BEGIN PGP SIGNATURE-----" & LF & LF
         & "fake-signature" & LF
         & "-----END PGP SIGNATURE-----" & LF
         & "EOF" & LF);
      Version.Git_Fixtures.Run (Root, "chmod +x fake-bin/gpg");
      Ada.Environment_Variables.Set ("PATH", Bin_Dir & ":" & Old_Path);

      --  (1) commit.gpgSign=true -> a plain Save signs.
      Version.Git_Fixtures.Run (Root, "git config commit.gpgSign true");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "a" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("configured signing");
      Assert (HEAD_Is_Signed,
              "commit.gpgSign=true must make a plain save sign the commit");

      --  (2) Sign_Disable overrides the config.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "b" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("disabled override", Sign => Version.Write.Sign_Disable);
      Assert (not HEAD_Is_Signed,
              "--no-gpg-sign (Sign_Disable) must override commit.gpgSign");

      --  (3) Sign_Force signs even with the config off.
      Version.Git_Fixtures.Run (Root, "git config commit.gpgSign false");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "c" & LF);
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("forced signing", Sign => Version.Write.Sign_Force);
      Assert (HEAD_Is_Signed, "-S (Sign_Force) must sign regardless of config");

      Ada.Environment_Variables.Set ("PATH", Old_Path);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Had_Path then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         end if;
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Honours_Commit_Signing;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Save_Root_File_As_Git_Commit'Access,
         "Save: root-level staged file creates Git-readable commit");

      Register_Routine
        (T,
         Save_Honours_Commit_Signing'Access,
         "Save: honours commit.gpgSign / -S / --no-gpg-sign");

      Register_Routine
        (T,
         Save_Stores_LFS_Pointer_As_Ordinary_Blob'Access,
         "Save: LFS pointer stored as ordinary blob");

      Register_Routine
        (T,
         Save_Cleans_LFS_Tracked_File_To_Pointer'Access,
         "Save: LFS filter cleans tracked media to pointer");

      Register_Routine
         (T,
            Save_Nested_File_As_Git_Commit'Access,
            "Save: nested staged file creates Git-readable tree");

      Register_Routine
        (T,
         Save_Preserves_Staged_Executable_Mode'Access,
         "Save: preserves staged executable mode");

      Register_Routine
        (T,
         Save_Preserves_Staged_Symlink_Mode'Access,
         "Save: preserves staged symlink mode");

      Register_Routine
         (T,
            Save_Amend_Replaces_Current_Commit'Access,
            "Save: amend replaces current commit");

      Register_Routine
        (T,
         Save_Amend_Appends_Reflog_Entry'Access,
         "Save: amend appends reflog entry");

      Register_Routine
         (T,
            Save_Uses_Git_Config_Identity'Access,
            "Save: uses Git config identity");

      Register_Routine
         (T,
            Write_Commit_With_Two_Parents'Access,
            "Save: write commit with multiple parents");

      Register_Routine
        (T,
         Save_Creates_HEAD_Reflog'Access,
         "Save: creates HEAD reflog");

      Register_Routine
        (T,
         Save_Creates_Current_Branch_Reflog'Access,
         "Save: creates current branch reflog");

      Register_Routine
        (T,
         Save_HEAD_Reflog_Lock_Preserves_Attached_State'Access,
         "Save: HEAD reflog lock preserves attached state");

      Register_Routine
        (T,
         Save_Branch_Reflog_Lock_Preserves_Attached_State'Access,
         "Save: branch reflog lock preserves attached state");

      Register_Routine
        (T,
         Save_HEAD_Reflog_Lock_Preserves_Detached_State'Access,
         "Save: HEAD reflog lock preserves detached state");

      Register_Routine
        (T, Write_Tree_Matches_Git'Access,
         "Write_Tree: explicit tree matches git mktree oid");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Write");
   end Name;

end Version.Write.Tests;