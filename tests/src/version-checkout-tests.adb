with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Platform;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Test_Support;
with Version.Write;
with Version.Files;

package body Version.Checkout.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Version.Platform.Platform_Kind;

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

   procedure Checkout_Detaches_Head_And_Restores_Working_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");

         Version.Checkout.Checkout_Commit
           (Version.Objects.To_Object_Id (First));

         Assert
           (Version.Refs.Is_Detached (Repo),
            "checkout by commit must detach HEAD");

         Assert
           (Version.Refs.Current_Commit_Id (Repo) = First,
            "detached HEAD must resolve to the checked out commit");

         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt"))
            = "one",
            "checkout must restore the target commit working tree");

         Version.Git_Fixtures.Run
           (Root,
            "git symbolic-ref -q HEAD >/dev/null 2>&1 && exit 1 || exit 0");
         Version.Git_Fixtures.Run (Root, "git fsck --strict");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Detaches_Head_And_Restores_Working_Tree;

   procedure Detached_Save_Does_Not_Move_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");

         declare
            Branch_Tip : constant String :=
              Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Checkout.Checkout_Commit
              (Version.Objects.To_Object_Id (First));

            Save_File (Root, "a.txt", "three" & Character'Val (10), "three");

            declare
               Detached_Tip : constant String :=
                 Version.Refs.Current_Commit_Id (Repo);
               Main_Tip     : constant Version.Objects.Hex_Object_Id :=
                 Version.Refs.Resolve_Ref (Repo, "refs/heads/main");
            begin
               Assert
                 (Detached_Tip /= Branch_Tip,
                  "detached save should create a new commit");

               Assert
                 (To_String (Main_Tip) = Branch_Tip,
                  "detached save must not advance refs/heads/main");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Detached_Save_Does_Not_Move_Branch;

   procedure Switch_Branch_From_Detached_Restores_Symbolic_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");

         Version.Checkout.Checkout_Commit
           (Version.Objects.To_Object_Id (First));

         Version.Branch.Switch_Branch ("main");

         Assert
           (not Version.Refs.Is_Detached (Repo),
            "branch switch must restore symbolic HEAD");

         Assert
           (Version.Refs.Current_Branch_Name (Repo) = "main",
            "branch switch from detached must attach to main");

         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt"))
            = "two",
            "branch switch from detached must restore branch tip content");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Switch_Branch_From_Detached_Restores_Symbolic_Head;

   procedure Current_Branch_Name_Rejects_Detached_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Checkout.Checkout_Commit
           (Version.Objects.To_Object_Id (First));

         begin
            declare
               Ignored : constant String :=
                 Version.Refs.Current_Branch_Name (Repo);
            begin
               pragma Unreferenced (Ignored);
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "Current_Branch_Name must reject detached HEAD");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Current_Branch_Name_Rejects_Detached_Head;

   function Contains (Haystack : String; Needle : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Haystack, Needle) /= 0;
   end Contains;

   procedure Detached_Checkout_Writes_Index_And_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");

         declare
            Main_Log_Path : constant String :=
              Version.Reflog.Path
                (Version.Repository.Open, "refs/heads/main");

            Main_Log_Before : constant String :=
              Version.Test_Support.Read_Text_File (Main_Log_Path);
         begin
            Version.Checkout.Checkout_Commit
              (Version.Objects.To_Object_Id (First));

            Version.Git_Fixtures.Run
              (Root, "test -z ""$(git status --porcelain)""");

            declare
               Head_Log : constant String :=
                 Version.Test_Support.Read_Text_File
                   (Version.Reflog.Path (Version.Repository.Open, "HEAD"));

               Main_Log_After : constant String :=
                 Version.Test_Support.Read_Text_File (Main_Log_Path);
            begin
               Assert
                 (Contains (Head_Log, "checkout: moving to "),
                  "detached checkout must append a HEAD reflog entry");

               Assert
                 (Main_Log_After = Main_Log_Before,
                  "detached checkout must not append a branch reflog entry");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Detached_Checkout_Writes_Index_And_Reflog;

   procedure Checkout_Rejects_Non_Commit_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo => Repo, Content => "not a commit");
      begin
         begin
            Version.Checkout.Checkout_Commit (Blob_Id);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "checkout must reject blob object ids");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Rejects_Non_Commit_Object;

   procedure Checkout_Path_From_Commit_Updates_Working_Tree_And_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
      B_Path  : constant String := Version.Test_Support.Join (Root, "b.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");
         Save_File (Root, "b.txt", "keep" & Character'Val (10), "b");

         Version.Checkout.Checkout_Path_From_Commit
           (Version.Objects.To_Object_Id (First), "a.txt");

         Assert
           (Version.Test_Support.Read_Text_File (A_Path) = "one",
            "checkout path must restore selected path content from source commit");

         Assert
           (Version.Test_Support.Read_Text_File (B_Path) = "keep",
            "checkout path must not touch unrelated files");

         Version.Git_Fixtures.Run
           (Root, "git diff --cached --quiet -- a.txt && exit 1 || exit 0");
         Version.Git_Fixtures.Run (Root, "git diff --quiet -- a.txt");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Path_From_Commit_Updates_Working_Tree_And_Index;

   procedure Checkout_Path_Missing_In_Source_Removes_Working_Tree_And_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path  : constant String := Version.Test_Support.Join (Root, "a.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");
      Version.Git_Fixtures.Run (Root, "git rm a.txt");
      Version.Write.Save ("remove a");

      declare
         Missing_Source : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "restore a");

         Version.Checkout.Checkout_Path_From_Commit
           (Version.Objects.To_Object_Id (Missing_Source), "a.txt");

         Assert
           (not Ada.Directories.Exists (A_Path),
            "checkout path must delete the working file when the source commit lacks the path");

         Version.Git_Fixtures.Run
           (Root, "git diff --cached --quiet -- a.txt && exit 1 || exit 0");
         Version.Git_Fixtures.Run (Root, "git diff --quiet -- a.txt");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Path_Missing_In_Source_Removes_Working_Tree_And_Index;

   procedure Checkout_Commit_Materializes_Symlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "README.md", "readme" & Character'Val (10), "base");
      Version.Git_Fixtures.Run (Root, "ln -s README.md link-to-readme");
      Version.Git_Fixtures.Run (Root, "git add link-to-readme");
      Version.Write.Save ("symlink");

      declare
         Symlink_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "rm link-to-readme");
         Save_File
           (Root,
            "link-to-readme",
            "ordinary" & Character'Val (10),
            "ordinary");

         Version.Checkout.Checkout_Commit
           (Version.Objects.To_Object_Id (Symlink_Commit));
         Assert_POSIX_Symlink (Root, "link-to-readme", "README.md");
         Version.Git_Fixtures.Run
           (Root, "git diff --cached --quiet -- link-to-readme");
         Version.Git_Fixtures.Run (Root, "git diff --quiet -- link-to-readme");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Commit_Materializes_Symlink;

   procedure Checkout_Path_Materializes_Symlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "README.md", "readme" & Character'Val (10), "base");
      Version.Git_Fixtures.Run (Root, "ln -s README.md link-to-readme");
      Version.Git_Fixtures.Run (Root, "git add link-to-readme");
      Version.Write.Save ("symlink");

      declare
         Symlink_Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "rm link-to-readme");
         Save_File
           (Root,
            "link-to-readme",
            "ordinary" & Character'Val (10),
            "ordinary");

         Version.Checkout.Checkout_Path_From_Commit
           (Version.Objects.To_Object_Id (Symlink_Commit), "link-to-readme");
         Assert_POSIX_Symlink (Root, "link-to-readme", "README.md");
         Version.Git_Fixtures.Run
           (Root, "git diff --cached --quiet -- link-to-readme && exit 1 || exit 0");
         Version.Git_Fixtures.Run (Root, "git diff --quiet -- link-to-readme");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Path_Materializes_Symlink;

   function Head_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join (Root, ".git/HEAD");
   end Head_Path;

   function Test_Repo (Root : String) return Version.Repository.Repository_Handle is
   begin
      return Version.Repository.Open_Git_Dir
        (Version.Test_Support.Join (Root, ".git"));
   end Test_Repo;

   function Head_Reflog_Lock_Path (Root : String) return String is
   begin
      return Version.Reflog.Path (Test_Repo (Root), "HEAD") & ".lock";
   end Head_Reflog_Lock_Path;

   function Index_Path (Root : String) return String is
   begin
      return Version.Test_Support.Join (Root, ".git/index");
   end Index_Path;

   procedure Checkout_Preflight_Failure_Preserves_Attached_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Blocking_Path : constant String := Version.Test_Support.Join (Root, "dir");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "dir", "file blocks directory" & Character'Val (10), "blocker");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blocking_Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Git_Fixtures.Run (Root, "git rm dir");
         Version.Test_Support.Make_Directory
           (Version.Test_Support.Join (Root, "dir"));
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Root, "dir/nested.txt"),
            "nested" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add dir/nested.txt");
         Version.Write.Save ("nested");

         declare
            Target_Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Git_Fixtures.Run (Root, "git reset --hard " & Blocking_Commit);

            declare
               Head_Before : constant String :=
                 Version.Files.Read_Binary_File (Head_Path (Root));
               Index_Before : constant String :=
                 Version.Files.Read_Binary_File (Index_Path (Root));
            begin
               begin
                  Version.Checkout.Checkout_Commit
                    (Version.Objects.To_Object_Id (Target_Commit));
               exception
                  when Ada.IO_Exceptions.Data_Error =>
                     Raised := True;
               end;

               Assert (Raised, "checkout preflight conflict must fail");
               Assert
                 (Version.Files.Read_Binary_File (Head_Path (Root)) = Head_Before,
                  "failed checkout preflight must preserve symbolic HEAD");
               Assert
                 (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
                  "failed checkout preflight must preserve index bytes");
            end;
            Assert
              (Version.Test_Support.Read_Text_File (Blocking_Path) = "file blocks directory",
               "failed checkout preflight must preserve blocking file content");
            Assert
              (not Version.Refs.Is_Detached (Repo),
               "failed checkout preflight must keep HEAD attached");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Preflight_Failure_Preserves_Attached_Head;

   procedure Checkout_Reflog_Lock_Preserves_Attached_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");

         declare
            Head_Before : constant String := Version.Files.Read_Binary_File (Head_Path (Root));
            Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
         begin
            Version.Test_Support.Write_Text_File
              (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

            begin
               Version.Checkout.Checkout_Commit
                 (Version.Objects.To_Object_Id (First));
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "stale HEAD reflog lock must fail checkout");
            Assert
              (Version.Files.Read_Binary_File (Head_Path (Root)) = Head_Before,
               "reflog-lock checkout failure must preserve symbolic HEAD");
            Assert
              (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
               "reflog-lock checkout failure must preserve index bytes");
            Assert
              (Version.Test_Support.Read_Text_File (A_Path) = "two",
               "reflog-lock checkout failure must preserve working tree");
            Assert
              (not Version.Refs.Is_Detached (Repo),
               "reflog-lock checkout failure must keep HEAD attached");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Reflog_Lock_Preserves_Attached_State;

   procedure Checkout_Reflog_Lock_Preserves_Detached_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      A_Path : constant String := Version.Test_Support.Join (Root, "a.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Save_File (Root, "a.txt", "two" & Character'Val (10), "two");
         declare
            Second : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Checkout.Checkout_Commit
              (Version.Objects.To_Object_Id (Second));

            declare
               Head_Before : constant String := Version.Files.Read_Binary_File (Head_Path (Root));
               Index_Before : constant String := Version.Files.Read_Binary_File (Index_Path (Root));
            begin
               Version.Test_Support.Write_Text_File
                 (Head_Reflog_Lock_Path (Root), "locked" & Character'Val (10));

               begin
                  Version.Checkout.Checkout_Commit
                    (Version.Objects.To_Object_Id (First));
               exception
                  when Ada.IO_Exceptions.Data_Error =>
                     Raised := True;
               end;

               Assert (Raised, "stale HEAD reflog lock must fail detached checkout");
               Assert
                 (Version.Files.Read_Binary_File (Head_Path (Root)) = Head_Before,
                  "reflog-lock failure must preserve detached HEAD file");
               Assert
                 (Version.Files.Read_Binary_File (Index_Path (Root)) = Index_Before,
                  "reflog-lock detached failure must preserve index bytes");
               Assert
                 (Version.Test_Support.Read_Text_File (A_Path) = "two",
                  "reflog-lock detached failure must preserve working tree");
               Assert
                 (Version.Refs.Is_Detached (Repo),
                  "reflog-lock failure must keep HEAD detached");
               Assert
                 (Version.Refs.Current_Commit_Id (Repo) = Second,
                  "reflog-lock failure must preserve detached commit id");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Reflog_Lock_Preserves_Detached_State;

   procedure Integrate_Rejects_Detached_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Save_File (Root, "a.txt", "one" & Character'Val (10), "one");
      Version.Branch.Create_Branch ("feature");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         First : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Version.Checkout.Checkout_Commit
           (Version.Objects.To_Object_Id (First));

         begin
            Version.Branch.Integrate_Branch ("feature");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "integrate must reject detached HEAD");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Integrate_Rejects_Detached_Head;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Checkout_Detaches_Head_And_Restores_Working_Tree'Access,
         "Checkout: detach to commit and restore working tree");

      Register_Routine
        (T,
         Detached_Save_Does_Not_Move_Branch'Access,
         "Checkout: detached save advances HEAD only");

      Register_Routine
        (T,
         Switch_Branch_From_Detached_Restores_Symbolic_Head'Access,
         "Checkout: switch branch from detached HEAD");

      Register_Routine
        (T,
         Current_Branch_Name_Rejects_Detached_Head'Access,
         "Checkout: current branch rejects detached HEAD");

      Register_Routine
        (T,
         Detached_Checkout_Writes_Index_And_Reflog'Access,
         "Checkout: detached checkout writes index and reflog");

      Register_Routine
        (T,
         Checkout_Rejects_Non_Commit_Object'Access,
         "Checkout: reject non-commit object");

      Register_Routine
        (T,
         Checkout_Path_From_Commit_Updates_Working_Tree_And_Index'Access,
         "Checkout: path checkout updates working tree and index");

      Register_Routine
        (T,
         Checkout_Path_Missing_In_Source_Removes_Working_Tree_And_Index'Access,
         "Checkout: path missing in source removes working tree and index");

      Register_Routine
        (T,
         Checkout_Commit_Materializes_Symlink'Access,
         "Checkout: commit materializes symlink entries");

      Register_Routine
        (T,
         Checkout_Path_Materializes_Symlink'Access,
         "Checkout: path materializes symlink entries");

      Register_Routine
        (T,
         Checkout_Preflight_Failure_Preserves_Attached_Head'Access,
         "Checkout: preflight failure preserves attached HEAD");

      Register_Routine
        (T,
         Checkout_Reflog_Lock_Preserves_Attached_State'Access,
         "Checkout: reflog lock preserves attached state");

      Register_Routine
        (T,
         Checkout_Reflog_Lock_Preserves_Detached_State'Access,
         "Checkout: reflog lock preserves detached state");

      Register_Routine
        (T,
         Integrate_Rejects_Detached_Head'Access,
         "Checkout: integrate rejects detached HEAD");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Checkout");
   end Name;

end Version.Checkout.Tests;
