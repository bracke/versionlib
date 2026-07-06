with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;


with Version.Git_Fixtures;
with Version.Test_Support;
with Version.Branch;
with Version.Fetch;
with Version.Objects;
with Version.Files;
with Version.Write;
with Version.Init;
with Version.Push;
with Version.Remotes;
with Version.Reflog;
with Version.Repository;

package body Version.Clone.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Clone_Local_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Target_File : constant String :=
        Version.Test_Support.Join (Target, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File,
         "hello clone" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("initial");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
        (Source => Source,
         Target => Target);

      Assert
        (Ada.Directories.Exists (Target_File),
         "clone must restore working tree");

      Assert
        (Version.Test_Support.Read_Text_File (Target_File)
         = "hello clone",
         "clone must restore committed file content");

      Version.Git_Fixtures.Run
        (Target,
         "git fsck --strict");

      Version.Git_Fixtures.Run
        (Target,
         "test ""$(git rev-parse origin/main)"" = ""$(git -C """ & Source & """ rev-parse main)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Local_Repository;

   procedure Clone_Filtered_Blob_None_Is_Partial
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "src-pc");
      Target : constant String := Version.Test_Support.Join (Root, "tgt-pc");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Blob_File : constant String := Version.Test_Support.Join (Root, "oldblob");

      function Loose_Object_Path (Id : String) return String is
        (Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join
                 (Version.Test_Support.Join (Target, ".git"), "objects"),
               Id (Id'First .. Id'First + 1)),
            Id (Id'First + 2 .. Id'First + 39)));
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Source, "old.txt"),
         "OLD CONTENT" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add old.txt");
      Version.Write.Save ("c1");
      --  Replace the file so the old blob is not in the latest tree.
      Version.Git_Fixtures.Run (Source, "git rm -q old.txt");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Source, "new.txt"),
         "NEW CONTENT" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add new.txt");
      Version.Write.Save ("c2");
      Version.Git_Fixtures.Run
        (Source, "git rev-parse HEAD~1:old.txt > " & Blob_File);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone_Filtered
        (Source => Source, Target => Target, Filter => "blob:none");

      declare
         Old_Blob : constant String :=
           Version.Test_Support.Read_Text_File (Blob_File)
             (1 .. 40);
      begin
         --  The checked-out working tree is correct.
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Target, "new.txt")) = "NEW CONTENT",
            "filtered clone must check out the current tree");

         --  The repository is marked as a partial clone.
         Version.Git_Fixtures.Run
           (Target,
            "test ""$(git config extensions.partialClone)"" = ""origin""");

         --  A blob absent from the current tree was omitted (still partial).
         Assert
           (not Ada.Directories.Exists (Loose_Object_Path (Old_Blob)),
            "blob:none clone must omit a blob not in the checked-out tree");

         --  Reading the omitted blob lazily fetches it from the promisor.
         Ada.Directories.Set_Directory (Target);
         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Old_Blob));
         begin
            Assert
              (Version.Objects.Content (Obj) = "OLD CONTENT" & Character'Val (10),
               "promisor lazy fetch must materialize the omitted blob");
         end;
         Ada.Directories.Set_Directory (Old_Dir);

         Assert
           (Ada.Directories.Exists (Loose_Object_Path (Old_Blob)),
            "lazily fetched blob must now be present locally");
      end;

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Filtered_Blob_None_Is_Partial;

   procedure Clone_Accepts_Relative_Local_Bare_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Bare_Path : constant String :=
        Version.Test_Support.Join (Root, "remote.git");

      Work_Path : constant String :=
        Version.Test_Support.Join (Root, "source");

      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone");

      Work_File : constant String :=
        Version.Test_Support.Join (Work_Path, "a.txt");

      Clone_File : constant String :=
        Version.Test_Support.Join (Clone_Path, "a.txt");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init_Bare (Bare_Path);
      Version.Init.Init (Work_Path);

      Ada.Directories.Set_Directory (Work_Path);

      Version.Test_Support.Write_Text_File
        (Work_File,
         "relative clone" & Character'Val (10));

      Version.Git_Fixtures.Run (Work_Path, "git add a.txt");
      Version.Write.Save ("relative clone");

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "../remote.git");

      Version.Push.Push
        (Remote_Name => "origin",
         Branch_Name => "main");

      Ada.Directories.Set_Directory (Root);

      Version.Clone.Clone
        (Source => "remote.git",
         Target => "clone");

      Assert
        (Version.Test_Support.Read_Text_File (Clone_File) = "relative clone",
         "relative local clone source must be resolved before entering target");

      Version.Git_Fixtures.Run
        (Clone_Path,
         "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Accepts_Relative_Local_Bare_Source;

   procedure Clone_Uses_Remote_Default_Branch
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Bare_Path : constant String :=
      Version.Test_Support.Join (Root, "trunk-source.git");

      Work_Path : constant String :=
      Version.Test_Support.Join (Root, "trunk-work");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "trunk-clone");

      Work_File : constant String :=
      Version.Test_Support.Join (Work_Path, "a.txt");

      Clone_File : constant String :=
      Version.Test_Support.Join (Clone_Path, "a.txt");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;
   begin
      Version.Init.Init_Bare (Bare_Path);
      Version.Init.Init (Work_Path);

      Version.Files.Write_Binary_File
      (Path    => Version.Test_Support.Join (Bare_Path, "HEAD"),
         Content => "ref: refs/heads/trunk" & Character'Val (10));

      Version.Git_Fixtures.Run (Work_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work_Path, "git config user.name Test");

      Ada.Directories.Set_Directory (Work_Path);

      Version.Test_Support.Write_Text_File
      (Work_File,
         "trunk content" & Character'Val (10));

      Version.Git_Fixtures.Run (Work_Path, "git add a.txt");
      Version.Write.Save ("trunk content");

      Version.Branch.Create_Branch ("trunk");
      Version.Branch.Switch_Branch ("trunk");

      Version.Remotes.Add_Remote
      (Name => "origin",
         Url  => Bare_Path);

      Version.Push.Push
      (Remote_Name => "origin",
         Branch_Name => "trunk");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Bare_Path,
         Target => Clone_Path);

      Assert
      (Version.Test_Support.Read_Text_File (Clone_File) = "trunk content",
         "clone must restore remote default branch content");

      Version.Git_Fixtures.Run
      (Clone_Path,
         "test ""$(git symbolic-ref --short HEAD)"" = ""trunk""");

      Version.Git_Fixtures.Run
      (Clone_Path,
         "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Uses_Remote_Default_Branch;




   procedure Clone_File_Url_Repository
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
      Version.Test_Support.Join (Root, "source file url with spaces");

      Target : constant String :=
      Version.Test_Support.Join (Root, "target-file-url");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Source_File : constant String :=
      Version.Test_Support.Join (Source, "a.txt");

      Target_File : constant String :=
      Version.Test_Support.Join (Target, "a.txt");

      Remote_Url : constant String := "file://" &
        Version.Test_Support.Join (Root, "source%20file%20url%20with%20spaces");
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Init.Init (Source);

      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "hello file clone" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("initial");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Remote_Url,
         Target => Target);

      Assert
      (Version.Test_Support.Read_Text_File (Target_File) = "hello file clone",
         "file URL clone must restore committed file content");

      Version.Git_Fixtures.Run
      (Target,
         "git fsck --strict");

      Version.Git_Fixtures.Run
      (Target,
         "test ""$(git config --get remote.origin.url)"" = """ & Remote_Url & """");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "hello file clone after fetch" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("after file clone");

      Ada.Directories.Set_Directory (Target);
      Version.Fetch.Fetch ("origin");

      Version.Git_Fixtures.Run
      (Target,
         "test ""$(git rev-parse origin/main)"" = ""$(git -C """ & Source & """ rev-parse main)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_File_Url_Repository;

   procedure Clone_File_Url_Localhost_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source-localhost-file-url");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target-localhost-file-url");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Target_File : constant String :=
        Version.Test_Support.Join (Target, "a.txt");

      Remote_Url : constant String := "file://localhost" & Source;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Init.Init (Source);

      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File,
         "hello localhost file clone" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("initial localhost file clone");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
        (Source => Remote_Url,
         Target => Target);

      Assert
        (Version.Test_Support.Read_Text_File (Target_File)
         = "hello localhost file clone",
         "file://localhost clone must restore committed file content");

      Version.Git_Fixtures.Run
        (Target,
         "git fsck --strict");

      Version.Git_Fixtures.Run
        (Target,
         "test ""$(git config --get remote.origin.url)"" = """ & Remote_Url & """");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_File_Url_Localhost_Repository;

   procedure Clone_Rejects_File_Url_Remote_Authority
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Target : constant String :=
        Version.Test_Support.Join (Root, "remote-authority-target");

      Raised : Boolean := False;
   begin
      begin
         Version.Clone.Clone
           (Source => "file://example.invalid/tmp/repo.git",
            Target => Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "clone must reject non-local file URL authorities");
      Assert
        (not Ada.Directories.Exists (Target),
         "non-local file URL authority clone must not create target");
   end Clone_Rejects_File_Url_Remote_Authority;

   procedure Clone_Rejects_Malformed_File_Url_Escapes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Bad_Hex_Target : constant String :=
        Version.Test_Support.Join (Root, "bad-hex-target");

      Truncated_Target : constant String :=
        Version.Test_Support.Join (Root, "truncated-target");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Bad_Hex_Raised : Boolean := False;
      Truncated_Raised : Boolean := False;
   begin
      begin
         Version.Clone.Clone
           (Source => "file:///tmp/repo%ZZ",
            Target => Bad_Hex_Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Bad_Hex_Raised := True;
      end;

      Assert
        (Bad_Hex_Raised,
         "clone must reject non-hex file URL percent escapes");
      Assert
        (not Ada.Directories.Exists (Bad_Hex_Target),
         "bad percent escape clone must not create target");

      begin
         Version.Clone.Clone
           (Source => "file:///tmp/repo%2",
            Target => Truncated_Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Truncated_Raised := True;
      end;

      Assert
        (Truncated_Raised,
         "clone must reject truncated file URL percent escapes");
      Assert
        (not Ada.Directories.Exists (Truncated_Target),
         "truncated percent escape clone must not create target");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Rejects_Malformed_File_Url_Escapes;

   procedure Clone_Checkout_Appends_Reflogs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source-reflog");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target-reflog");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
   begin
      Version.Init.Init (Source);
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File,
         "clone reflog" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("initial");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
        (Source => Source,
         Target => Target);

      declare
         Commit : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join (Target, ".git/refs/heads/main"));

         Target_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open_Git_Dir
             (Version.Test_Support.Join (Target, ".git"));

         Head_Log : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Reflog.Path (Target_Repo, "HEAD"));

         Branch_Log : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Reflog.Path (Target_Repo, "refs/heads/main"));

         Expected_Ids : constant String :=
           "0000000000000000000000000000000000000000 " & Commit;
      begin
         Assert
           (Ada.Strings.Fixed.Index (Head_Log, Expected_Ids) /= 0,
            "clone HEAD reflog must contain zero old id and checkout commit id");

         Assert
           (Ada.Strings.Fixed.Index (Head_Log, "clone: checkout main") /= 0,
            "clone HEAD reflog must contain checkout message");

         Assert
           (Ada.Strings.Fixed.Index (Branch_Log, Expected_Ids) /= 0,
            "clone branch reflog must contain zero old id and checkout commit id");

         Assert
           (Ada.Strings.Fixed.Index (Branch_Log, "clone: checkout main") /= 0,
            "clone branch reflog must contain checkout message");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Checkout_Appends_Reflogs;

   procedure Clone_Rolls_Back_Target_After_Fetch_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "rollback-source");

      Target : constant String :=
        Version.Test_Support.Join (Root, "rollback-target");

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Bad_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source, ".git"), "refs/heads"),
           "main");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Init.Init (Source);

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "rollback clone" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("rollback clone");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File
        (Bad_Ref, "not-an-object-id" & Character'Val (10));

      begin
         Version.Clone.Clone (Source => Source, Target => Target);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "clone should reject malformed source branch ref");
      Assert
        (not Ada.Directories.Exists (Target),
         "failed clone must remove the target directory it created");
      Assert
        (Version.Test_Support.Read_Text_File (Bad_Ref) = "not-an-object-id",
         "failed clone must not rewrite malformed source ref");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Rolls_Back_Target_After_Fetch_Failure;

   procedure Clone_Rolls_Back_Target_After_Checkout_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "checkout-rollback-source");

      Target : constant String :=
        Version.Test_Support.Join (Root, "checkout-rollback-target");

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Head_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, ".git"), "HEAD");

      Main_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source, ".git"), "refs/heads"),
           "main");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Init.Init (Source);

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "checkout rollback clone" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("checkout rollback clone");
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Main_Before : constant String :=
           Version.Files.Read_Binary_File (Main_Ref);
      begin
         Version.Files.Write_Binary_File
           (Path    => Head_Path,
            Content => "ref: refs/heads/missing" & Character'Val (10));

         begin
            Version.Clone.Clone (Source => Source, Target => Target);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (Raised,
            "clone should reject missing remote default branch tracking ref");
         Assert
           (not Ada.Directories.Exists (Target),
            "failed clone checkout must remove the target directory it created");
         Assert
           (Version.Files.Read_Binary_File (Main_Ref) = Main_Before,
            "failed clone checkout must not rewrite source branch ref");
         Assert
           (Version.Files.Read_Binary_File (Head_Path)
            = "ref: refs/heads/missing" & Character'Val (10),
            "failed clone checkout must not rewrite source HEAD");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Clone_Rolls_Back_Target_After_Checkout_Failure;

   procedure Clone_Depth_Rejects_Local_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target");

      Raised : Boolean := False;
   begin
      begin
         Version.Clone.Clone
           (Source => Source,
            Target => Target,
            Depth  => 1);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "depth clone should reject local transports");
      Assert (not Ada.Directories.Exists (Target),
              "failed shallow local clone must not create target directory");
   end Clone_Depth_Rejects_Local_Source;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Clone_Local_Repository'Access,
         "Clone: local repository");

      Register_Routine
        (T,
         Clone_Filtered_Blob_None_Is_Partial'Access,
         "Clone: --filter=blob:none yields a partial clone with lazy fetch");

      Register_Routine
         (T,
            Clone_Uses_Remote_Default_Branch'Access,
            "Clone: uses remote default branch");

      Register_Routine
        (T,
         Clone_Accepts_Relative_Local_Bare_Source'Access,
         "Clone: accepts relative local bare source");




      Register_Routine
         (T,
            Clone_File_Url_Repository'Access,
            "Clone: file URL repository");

      Register_Routine
        (T,
         Clone_File_Url_Localhost_Repository'Access,
         "Clone: file URL localhost repository");

      Register_Routine
        (T,
         Clone_Rejects_File_Url_Remote_Authority'Access,
         "Clone: rejects non-local file URL authority");

      Register_Routine
        (T,
         Clone_Rejects_Malformed_File_Url_Escapes'Access,
         "Clone: rejects malformed file URL escapes");

      Register_Routine
        (T,
         Clone_Checkout_Appends_Reflogs'Access,
         "Clone: checkout appends reflogs");

      Register_Routine
        (T,
         Clone_Rolls_Back_Target_After_Fetch_Failure'Access,
         "Clone: rolls back target after fetch failure");

      Register_Routine
        (T,
         Clone_Rolls_Back_Target_After_Checkout_Failure'Access,
         "Clone: rolls back target after checkout failure");

      Register_Routine
        (T,
         Clone_Depth_Rejects_Local_Source'Access,
         "Clone: depth rejects local source");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Clone");
   end Name;

end Version.Clone.Tests;
