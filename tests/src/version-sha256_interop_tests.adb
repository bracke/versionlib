with Ada.Directories;
with Ada.Strings.Unbounded;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Clone;
with Version.Git_Fixtures;
with Version.Hash;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Stage;
with Version.Stash;
with Version.Test_Support;
with Version.Upload_Pack;
with Version.Write;

package body Version.Sha256_Interop_Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Version.Hash.Hash_Algorithm;
   use type Version.Objects.Object_Kind;

   LF : constant Character := Character'Val (10);

   function Join (Left, Right : String) return String
     renames Version.Test_Support.Join;

   --  Run the library action Action in Root (git operations and Save/Stage act
   --  on the current directory), restoring the previous directory afterwards.
   procedure In_Directory
     (Root : String; Action : not null access procedure)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Ada.Directories.Set_Directory (Root);
      Action.all;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end In_Directory;

   ---------------------------------------------------------------------------
   --  version writes a SHA-256 commit that git reads and fscks.
   ---------------------------------------------------------------------------
   procedure Version_Commit_Is_Readable_By_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Do_Commit is
      begin
         Version.Stage.Stage_Path ("a.txt");
         Version.Write.Save ("c1", Run_Hooks => False);

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Head : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Assert (Head'Length = 64,
                    "sha256 commit id must be 64 hex, got" & Head'Length'Image);
         end;
      end Do_Commit;
   begin
      Version.Init.Init (Root, Version.Hash.Sha256);
      Version.Git_Fixtures.Run (Root, "git config user.email t@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File
        (Join (Root, "a.txt"), "hello sha256" & LF);

      In_Directory (Root, Do_Commit'Access);

      --  git must accept version's objects and see a 64-hex HEAD commit.
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "git rev-parse HEAD | grep -qE '^[0-9a-f]{64}$'");
      Version.Git_Fixtures.Run (Root, "git log --oneline | grep -q c1");
   end Version_Commit_Is_Readable_By_Git;

   ---------------------------------------------------------------------------
   --  version reads a repository that git created with --object-format=sha256.
   ---------------------------------------------------------------------------
   procedure Version_Reads_Git_Sha256_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Read_It is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert (Version.Repository.Algorithm (Repo) = Version.Hash.Sha256,
                 "opened repo must report the Sha256 algorithm");

         declare
            Head : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id
                (Version.Refs.Current_Commit_Id (Repo));
            Commit : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Head);
            Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id (Commit);
            Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Flatten_Tree (Repo, Tree);
            Found : Boolean := False;
         begin
            Assert (Version.Objects.Kind (Commit)
                      = Version.Objects.Commit_Object,
                    "HEAD must read back as a commit");

            for E of Entries loop
               if Ada.Strings.Unbounded.To_String (E.Path) = "f.txt" then
                  Found := True;
                  declare
                     Blob : constant Version.Objects.Git_Object :=
                       Version.Objects.Read_Object (Repo, E.Id);
                  begin
                     Assert (Version.Objects.Content (Blob) = "git made me" & LF,
                             "blob content read from git sha256 repo must match");
                  end;
               end if;
            end loop;

            Assert (Found, "f.txt must be present in the git sha256 tree");
         end;
      end Read_It;
   begin
      Version.Test_Support.Make_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git init -q --object-format=sha256 .");
      Version.Git_Fixtures.Run (Root, "git config user.email g@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Git");
      Version.Test_Support.Write_Text_File
        (Join (Root, "f.txt"), "git made me" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Git_Fixtures.Run (Root, "git commit -qm gc1");

      In_Directory (Root, Read_It'Access);
   end Version_Reads_Git_Sha256_Repository;

   ---------------------------------------------------------------------------
   --  version's blob id equals git's for the same content in a sha256 repo.
   ---------------------------------------------------------------------------
   procedure Version_Blob_Id_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Content : constant String := "some blob content" & LF;
      Id : Version.Objects.Hex_Object_Id;

      procedure Write_It is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Id := Version.Write.Write_Blob (Repo, Content);
      end Write_It;
   begin
      Version.Init.Init (Root, Version.Hash.Sha256);
      Version.Git_Fixtures.Run (Root, "git config user.email t@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), Content);

      In_Directory (Root, Write_It'Access);

      Assert (Version.Objects.To_String (Id)'Length = 64,
              "sha256 blob id must be 64 hex");

      --  git computes the same id and can read the object version wrote.
      Version.Git_Fixtures.Run
        (Root,
         "test $(git hash-object a.txt) = "
         & Version.Objects.To_String (Id));
      Version.Git_Fixtures.Run
        (Root, "git cat-file -e " & Version.Objects.To_String (Id));
   end Version_Blob_Id_Matches_Git;

   ---------------------------------------------------------------------------
   --  version's SHA-256 reflog is parseable by git.
   ---------------------------------------------------------------------------
   procedure Version_Reflog_Is_Readable_By_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Two_Commits is
      begin
         Version.Stage.Stage_Path ("a.txt");
         Version.Write.Save ("c1", Run_Hooks => False);
         Version.Test_Support.Write_Text_File
           (Join (Root, "a.txt"), "second" & LF);
         Version.Stage.Stage_Path ("a.txt");
         Version.Write.Save ("c2", Run_Hooks => False);
      end Two_Commits;
   begin
      Version.Init.Init (Root, Version.Hash.Sha256);
      Version.Git_Fixtures.Run (Root, "git config user.email t@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File
        (Join (Root, "a.txt"), "first" & LF);

      In_Directory (Root, Two_Commits'Access);

      --  git parses the reflog and sees both entries (the initial old id must
      --  be the 64-zero null, not the 40-zero sha1 null).
      Version.Git_Fixtures.Run (Root, "test $(git reflog | wc -l) -ge 2");
   end Version_Reflog_Is_Readable_By_Git;

   ---------------------------------------------------------------------------
   --  version clones a git-created SHA-256 repository (local transport).
   ---------------------------------------------------------------------------
   procedure Version_Clones_Git_Sha256_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Join (Root, "src");
      Target : constant String := Join (Root, "clone");

      procedure Verify_Clone is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert (Version.Repository.Algorithm (Repo) = Version.Hash.Sha256,
                 "clone target must be a sha256 repository");
         Assert (Version.Refs.Current_Commit_Id (Repo)'Length = 64,
                 "clone target HEAD must be a 64-hex commit id");
      end Verify_Clone;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init -q --object-format=sha256 .");
      Version.Git_Fixtures.Run (Source, "git config user.email g@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Git");
      Version.Test_Support.Write_Text_File
        (Join (Source, "f.txt"), "clone me" & LF);
      Version.Git_Fixtures.Run (Source, "git add f.txt");
      Version.Git_Fixtures.Run (Source, "git commit -qm gc1");

      Version.Clone.Clone (Source, Target);

      In_Directory (Target, Verify_Clone'Access);
      Version.Git_Fixtures.Run (Target, "git fsck --strict");
   end Version_Clones_Git_Sha256_Repository;

   ---------------------------------------------------------------------------
   --  The smart-transport object-format capability is parsed correctly (this
   --  is how clone/fetch/push over HTTP and SSH learn a remote is SHA-256).
   ---------------------------------------------------------------------------
   procedure Object_Format_Capability_Is_Parsed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Upload_Pack.Advertised_Object_Format
           ("multi_ack ofs-delta object-format=sha256 agent=git/2.43.0")
         = Version.Hash.Sha256,
         "object-format=sha256 capability must resolve to Sha256");
      Assert
        (Version.Upload_Pack.Advertised_Object_Format
           ("multi_ack ofs-delta agent=git/2.43.0")
         = Version.Hash.Sha1,
         "an absent object-format capability must default to Sha1");
      Assert
        (Version.Upload_Pack.Advertised_Object_Format
           ("object-format=sha1 agent=git")
         = Version.Hash.Sha1,
         "object-format=sha1 must resolve to Sha1");
   end Object_Format_Capability_Is_Parsed;

   ---------------------------------------------------------------------------
   --  stash push/pop round-trips on a SHA-256 repo (the stash reflog stores a
   --  64-zero null old-id; the consistency + ref-CAS checks must accept it).
   ---------------------------------------------------------------------------
   procedure Version_Stash_Round_Trips_On_Sha256
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Do_Stash is
      begin
         Version.Stage.Stage_Path ("a.txt");
         Version.Write.Save ("c1", Run_Hooks => False);

         Version.Test_Support.Write_Text_File
           (Join (Root, "a.txt"), "dirty" & LF);
         Version.Stash.Push;

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Assert (not Version.Stash.List_Entries (Repo).Is_Empty,
                    "sha256 stash push must record a stash entry");
         end;

         Version.Stash.Pop;
      end Do_Stash;
   begin
      Version.Init.Init (Root, Version.Hash.Sha256);
      Version.Git_Fixtures.Run (Root, "git config user.email t@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "base" & LF);

      In_Directory (Root, Do_Stash'Access);

      --  Read_Text_File strips the trailing newline.
      Assert
        (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "dirty",
         "sha256 stash pop must restore the stashed working-tree change");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
   end Version_Stash_Round_Trips_On_Sha256;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Object_Format_Capability_Is_Parsed'Access,
         "Sha256Interop: smart-transport object-format capability parsed");
      Register_Routine
        (T, Version_Stash_Round_Trips_On_Sha256'Access,
         "Sha256Interop: stash push/pop round-trips on sha256");
      Register_Routine
        (T, Version_Commit_Is_Readable_By_Git'Access,
         "Sha256Interop: version commit is readable/fsck-clean by git");
      Register_Routine
        (T, Version_Reads_Git_Sha256_Repository'Access,
         "Sha256Interop: version reads a git sha256 repository");
      Register_Routine
        (T, Version_Blob_Id_Matches_Git'Access,
         "Sha256Interop: version blob id matches git");
      Register_Routine
        (T, Version_Reflog_Is_Readable_By_Git'Access,
         "Sha256Interop: version sha256 reflog is readable by git");
      Register_Routine
        (T, Version_Clones_Git_Sha256_Repository'Access,
         "Sha256Interop: version clones a git sha256 repository");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Sha256_Interop");
   end Name;

end Version.Sha256_Interop_Tests;
