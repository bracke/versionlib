with Ada.Containers;        use Ada.Containers;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Archive;
with Version.Branch;
with Version.Compression;
with Version.Fetch;
with Version.Files;
with Version.Git_Fixtures;
with Version.Hash;
with Version.Init;
with Version.Objects;
with Version.Pack_Write;
with Version.Log;
with Version.Maintenance;
with Version.Merge_State;
with Version.Refs;
with Version.Remotes;
with Version.Repository;
with Version.Revisions;
with Version.Restore;
with Version.Stage;
with Version.Status;
with Version.Stash;
with Version.Stash_Test_Support;
with Version.Pathspec;
with Version.Submodules;
with Version.Tags;
with Version.Test_Support;
with Version.Write;

package body Version.Command_Corruption.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   function Raw_Id (Id : Version.Objects.Hex_Object_Id) return String is
      Result : String (1 .. 20);
      Pos    : Positive := To_String (Id)'First;

      function Nibble (C : Character) return Natural is
      begin
         if C in '0' .. '9' then
            return Character'Pos (C) - Character'Pos ('0');
         elsif C in 'a' .. 'f' then
            return Character'Pos (C) - Character'Pos ('a') + 10;
         elsif C in 'A' .. 'F' then
            return Character'Pos (C) - Character'Pos ('A') + 10;
         else
            raise Ada.IO_Exceptions.Data_Error with "invalid object id hex digit";
         end if;
      end Nibble;
   begin
      for I in Result'Range loop
         declare
            V : constant Natural :=
              Nibble (To_String (Id) (Pos)) * 16 + Nibble (To_String (Id) (Pos + 1));
         begin
            Result (I) := Character'Val (V);
            Pos := Pos + 2;
         end;
      end loop;

      return Result;
   end Raw_Id;

   procedure Append_U32_BE
     (Buffer : in out Unbounded_String;
      Value  : Natural)
   is
   begin
      Append (Buffer, Character'Val ((Value / 16#1000000#) mod 256));
      Append (Buffer, Character'Val ((Value / 16#10000#) mod 256));
      Append (Buffer, Character'Val ((Value / 16#100#) mod 256));
      Append (Buffer, Character'Val (Value mod 256));
   end Append_U32_BE;

   procedure Append_U16_BE
     (Buffer : in out Unbounded_String;
      Value  : Natural)
   is
   begin
      Append (Buffer, Character'Val ((Value / 16#100#) mod 256));
      Append (Buffer, Character'Val (Value mod 256));
   end Append_U16_BE;

   function Write_Raw_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String)
      return Version.Objects.Hex_Object_Id;


   procedure Append_Sparse_Directory_Index_Entry
     (Buffer : in out Unbounded_String;
      Path   : String;
      Tree   : Version.Objects.Hex_Object_Id)
   is
      Entry_Start_Length : constant Natural := Length (Buffer);
      Flags              : constant Natural := 16#4000# + Path'Length;
      Extended_Flags     : constant Natural := 16#4000#;
   begin
      for I in 1 .. 4 loop
         Append_U32_BE (Buffer, 0);
      end loop;

      Append_U32_BE (Buffer, 0);
      Append_U32_BE (Buffer, 0);
      Append_U32_BE (Buffer, 16#4000#);
      Append_U32_BE (Buffer, 0);
      Append_U32_BE (Buffer, 0);
      Append_U32_BE (Buffer, 0);
      Append (Buffer, Raw_Id (Tree));
      Append_U16_BE (Buffer, Flags);
      Append_U16_BE (Buffer, Extended_Flags);
      Append (Buffer, Path);
      Append (Buffer, Character'Val (0));

      while ((Length (Buffer) - Entry_Start_Length) mod 8) /= 0 loop
         Append (Buffer, Character'Val (0));
      end loop;
   end Append_Sparse_Directory_Index_Entry;

   function Sparse_Index_With_Directory
     (Repo       : Version.Repository.Repository_Handle;
      Directory  : String;
      File_Name  : String;
      Content    : String)
      return String
   is
      Blob_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Raw_Object (Repo, "blob", Content);
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Raw_Object
          (Repo,
           "tree",
           "100644 " & File_Name & Character'Val (0) & Raw_Id (Blob_Id));
      Buffer  : Unbounded_String;
   begin
      Append (Buffer, "DIRC");
      Append_U32_BE (Buffer, 2);
      Append_U32_BE (Buffer, 1);
      Append_Sparse_Directory_Index_Entry
        (Buffer => Buffer,
         Path   => Directory & "/",
         Tree   => Tree_Id);
      Append (Buffer, "sdir");
      Append_U32_BE (Buffer, 0);

      for I in 1 .. 20 loop
         Append (Buffer, Character'Val (0));
      end loop;

      return To_String (Buffer);
   end Sparse_Index_With_Directory;

   function Write_Raw_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String)
      return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);
      Raw : constant String := Header & Content;
      Id  : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
   begin
      --  Objects are content-addressed; skip if it already exists (the
      --  loose object file is written read-only, so overwriting fails).
      if not Ada.Directories.Exists
        (Version.Objects.Loose_Object_Path (Repo, Id))
      then
         Version.Files.Write_Binary_File
           (Path    => Version.Objects.Loose_Object_Path (Repo, Id),
            Content => Version.Compression.Deflate_Zlib (Raw));
      end if;
      return Id;
   end Write_Raw_Object;

   procedure Write_Corrupt_Loose_Object_For_Id
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
   is
      Raw : constant String := "blob 999" & Character'Val (0) & "bad";
   begin
      Version.Files.Write_Binary_File
        (Path    => Version.Objects.Loose_Object_Path (Repo, Id),
         Content => Version.Compression.Deflate_Zlib (Raw));
   end Write_Corrupt_Loose_Object_For_Id;

   procedure Point_Main_At
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
   begin
      Version.Refs.Atomic_Write_Ref
        (Path      =>
           Version.Files.Join
             (Version.Files.Join (Version.Repository.Git_Dir (Repo), "refs/heads"),
              "main"),
         Object_Id => Commit_Id);
   end Point_Main_At;

   procedure Write_Branch
     (Repo      : Version.Repository.Repository_Handle;
      Name      : String;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
   begin
      Version.Refs.Atomic_Write_Ref
        (Path      =>
           Version.Files.Join
             (Version.Files.Join (Version.Repository.Git_Dir (Repo), "refs/heads"),
              Name),
         Object_Id => Commit_Id);
   end Write_Branch;

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Save_File
     (Root    : String;
      Path    : String;
      Content : String;
      Message : String)
   is
   begin
      Version.Test_Support.Write_Text_File (Join (Root, Path), Content);
      Version.Git_Fixtures.Run (Root, "git add " & Path);
      Version.Write.Save (Message);
   end Save_File;

   function Corrupt_Tree_Commit
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Write_Raw_Object
          (Repo,
           "tree",
           "100644 broken.txt" & Character'Val (0) & "short");
   begin
      return
        Version.Write.Write_Commit
          (Repo      => Repo,
           Tree_Id   => Tree_Id,
           Parent_Id => "",
           Message   => "corrupt tree boundary fixture");
   end Corrupt_Tree_Commit;

   procedure Corrupt_Loose_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
   is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Objects.Loose_Object_Path (Repo, Id), "not-a-zlib-object");
   end Corrupt_Loose_Object;

   function Stash_Ref_Path (Root : String) return String
     renames Version.Stash_Test_Support.Stash_Ref_Path;
   function Stash_Log_Path (Root : String) return String
     renames Version.Stash_Test_Support.Stash_Log_Path;
   procedure Write_Stash_Storage
     (Root    : String;
      New_Id  : String;
      Message : String)
     renames Version.Stash_Test_Support.Write_Stash_Storage;

   procedure Status_Corrupt_Index_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      Sentinel : constant String := Join (Root, "sentinel.txt");
      Raised : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File (Sentinel, "sentinel" & LF);
      Version.Test_Support.Write_Text_File (Index_Path, "not-a-git-index");

      Ada.Directories.Set_Directory (Root);
      begin
         declare
            Result : constant Version.Status.Status_Result := Version.Status.Current_Status;
            pragma Unreferenced (Result);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "status must reject a corrupt index at command boundary");
      Assert (Version.Test_Support.Read_Text_File (Sentinel) = "sentinel",
              "failed status must not mutate working-tree files");
      Assert (Version.Test_Support.Read_Text_File (Index_Path) = "not-a-git-index",
              "failed status must not rewrite a corrupt index");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Corrupt_Index_Fails_Without_Mutation;

   procedure Restore_Corrupt_Source_Tree_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Join (Root, "broken.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (File_Path, "keep" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id := Corrupt_Tree_Commit (Repo);
      begin
         Point_Main_At (Repo, Bad);

         begin
            Version.Restore.Restore_Path ("broken.txt");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "restore must reject corrupt source trees");
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "keep",
              "failed restore from corrupt tree must preserve working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Restore_Corrupt_Source_Tree_Fails_Without_Mutation;

   procedure Branch_Switch_Corrupt_Target_Tree_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      File_Path : constant String := Join (Root, "a.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "main" & LF, "main");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Main : constant String := Version.Refs.Current_Commit_Id (Repo);
         Bad  : constant Version.Objects.Hex_Object_Id := Corrupt_Tree_Commit (Repo);
      begin
         Write_Branch (Repo, "bad", Bad);

         begin
            Version.Branch.Switch_Branch ("bad");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Refs.Current_Branch_Name (Repo) = "main",
                 "failed switch to corrupt tree must leave HEAD on main");
         Assert (Version.Refs.Current_Commit_Id (Repo) = Main,
                 "failed switch to corrupt tree must preserve current branch ref");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "branch switch must reject corrupt target trees");
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "main",
              "failed branch switch must preserve working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Switch_Corrupt_Target_Tree_Fails_Without_Mutation;

   procedure Archive_Corrupt_Tree_Fails_Without_Replacing_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output : constant String := Join (Root, "existing.tar");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (Output, "existing archive bytes" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id := Corrupt_Tree_Commit (Repo);
      begin
         Point_Main_At (Repo, Bad);

         begin
            Version.Archive.Create (Repo, "HEAD", Output, Version.Archive.Tar_Format);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "archive must reject corrupt source trees");
      Assert (Version.Test_Support.Read_Text_File (Output) = "existing archive bytes",
              "failed archive from corrupt tree must preserve preexisting output");
      Assert (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
              "failed archive from corrupt tree must clean temporary output");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Corrupt_Tree_Fails_Without_Replacing_Output;

   procedure Fetch_Corrupt_Local_Object_Fails_Before_Ref_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String := Join (Root, "remote");
      Target : constant String := Join (Root, "target");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
      Old_Ref : constant String := "4444444444444444444444444444444444444444";
   begin
      Ada.Directories.Create_Directory (Remote);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Remote);
      Version.Init.Init (Target);

      declare
         Remote_Old : constant String := Ada.Directories.Current_Directory;
         Remote_Id  : Version.Objects.Object_Id_Storage;
      begin
         Ada.Directories.Set_Directory (Remote);
         declare
            Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         begin
            Remote_Id := Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         end;
         Ada.Directories.Set_Directory (Remote_Old);

         Ada.Directories.Set_Directory (Target);
         declare
            Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
            Ref_Dir : constant String := Join (Join (Join (Join (Target, ".git"), "refs"), "remotes"), "origin");
            Ref_Path : constant String := Join (Ref_Dir, "main");
         begin
            Ada.Directories.Create_Path (Ref_Dir);
            Version.Test_Support.Write_Text_File (Ref_Path, Old_Ref & LF);
            Write_Corrupt_Loose_Object_For_Id (Repo, Remote_Id);
            Version.Remotes.Add_Remote ("origin", Remote);

            begin
               Version.Fetch.Fetch ("origin");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Version.Test_Support.Read_Text_File (Ref_Path) = Old_Ref,
                    "fetch encountering corrupt local object must preserve existing remote-tracking ref");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "fetch must reject corrupt local object before ref update");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Corrupt_Local_Object_Fails_Before_Ref_Update;

   function Commit_With_Corrupt_Blob
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Version.Objects.Hex_Object_Id
   is
      Bad_Blob : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("1111111111111111111111111111111111111111");
      Tree_Id : Version.Objects.Object_Id_Storage;
   begin
      Write_Corrupt_Loose_Object_For_Id (Repo, Bad_Blob);
      Tree_Id :=
        Write_Raw_Object
          (Repo,
           "tree",
           "100644 " & Path & Character'Val (0) & Raw_Id (Bad_Blob));
      return
        Version.Write.Write_Commit
          (Repo      => Repo,
           Tree_Id   => Tree_Id,
           Parent_Id => "",
           Message   => "corrupt blob boundary fixture");
   end Commit_With_Corrupt_Blob;

   function Commit_With_Malformed_Parent
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Empty_Tree : constant Version.Objects.Hex_Object_Id :=
        Write_Raw_Object (Repo, "tree", "");
      Content : constant String :=
        "tree " & To_String (Empty_Tree) & LF &
        "parent not-a-valid-parent" & LF &
        "author Test <test@example.com> 0 +0000" & LF &
        "committer Test <test@example.com> 0 +0000" & LF & LF &
        "malformed parent" & LF;
   begin
      return Write_Raw_Object (Repo, "commit", Content);
   end Commit_With_Malformed_Parent;

   function Commit_With_Corrupt_Gitmodules_Blob
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Bad_Blob : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("2222222222222222222222222222222222222222");
      Tree_Id : Version.Objects.Object_Id_Storage;
   begin
      Write_Corrupt_Loose_Object_For_Id (Repo, Bad_Blob);
      Tree_Id :=
        Write_Raw_Object
          (Repo,
           "tree",
           "100644 .gitmodules" & Character'Val (0) & Raw_Id (Bad_Blob));
      return
        Version.Write.Write_Commit
          (Repo      => Repo,
           Tree_Id   => Tree_Id,
           Parent_Id => "",
           Message   => "corrupt gitmodules boundary fixture");
   end Commit_With_Corrupt_Gitmodules_Blob;

   procedure Stage_Corrupt_Index_Fails_Without_Rewriting_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      File_Path : constant String := Join (Root, "stage-me.txt");
      Raised : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Test_Support.Write_Text_File (File_Path, "content" & LF);
      Version.Test_Support.Write_Text_File (Index_Path, "corrupt-index-before-stage");

      Ada.Directories.Set_Directory (Root);
      begin
         Version.Stage.Stage_Path ("stage-me.txt");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stage must reject corrupt index at command boundary");
      Assert (Version.Test_Support.Read_Text_File (Index_Path) = "corrupt-index-before-stage",
              "failed stage must not rewrite corrupt index");
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "content",
              "failed stage must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stage_Corrupt_Index_Fails_Without_Rewriting_Index;

   procedure Stage_Sparse_Index_Desparsifies_On_Write
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      File_Path : constant String := Join (Root, "stage-me.txt");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "dir/kept.txt", "kept" & LF, "base");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Before_Index : constant String :=
           Sparse_Index_With_Directory (Repo, "dir", "kept.txt", "kept" & LF);
      begin
         Version.Test_Support.Write_Text_File (File_Path, "content" & LF);
         Version.Files.Write_Binary_File (Index_Path, Before_Index);
         Version.Stage.Stage_Path ("stage-me.txt");

         Assert (Version.Files.Read_Binary_File (Index_Path) /= Before_Index,
                 "stage must rewrite sparse index as a normal index");
         Assert
           (Ada.Strings.Fixed.Index
              (Version.Files.Read_Binary_File (Index_Path), "sdir") = 0,
            "stage rewritten index must not retain sparse-index extension");
         Version.Git_Fixtures.Run
           (Root, "git ls-files -s dir/kept.txt | grep -q '^100644'");
         Version.Git_Fixtures.Run
           (Root, "git ls-files -s stage-me.txt | grep -q '^100644'");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "content",
              "stage sparse-index rewrite must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stage_Sparse_Index_Desparsifies_On_Write;


   procedure Save_Corrupt_Index_Fails_Before_Ref_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      File_Path : constant String := Join (Root, "a.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Reflog_Path : constant String := Join (Join (Join (Root, ".git"), "logs/refs/heads"), "main");
         Reflog_Before : constant String := Version.Test_Support.Read_Text_File (Reflog_Path);
      begin
         Version.Test_Support.Write_Text_File (File_Path, "dirty" & LF);
         Version.Test_Support.Write_Text_File (Index_Path, "corrupt-index-before-save");

         begin
            Version.Write.Save ("should fail");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                 "failed save must preserve current branch ref");
         Assert (Version.Test_Support.Read_Text_File (Reflog_Path) = Reflog_Before,
                 "failed save must not append reflog entries");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "save must reject corrupt index before commit/ref mutation");
      Assert (Version.Test_Support.Read_Text_File (Index_Path) = "corrupt-index-before-save",
              "failed save must not rewrite corrupt index");
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "dirty",
              "failed save must preserve dirty working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Corrupt_Index_Fails_Before_Ref_Mutation;

   procedure Save_Sparse_Index_Loads_Without_Ref_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      Reflog_Path : constant String := Join (Join (Join (Root, ".git"), "logs/refs/heads"), "main");
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "dir/kept.txt", "kept" & LF, "base");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Reflog_Before : constant String := Version.Test_Support.Read_Text_File (Reflog_Path);
         Before_Index : constant String :=
           Sparse_Index_With_Directory (Repo, "dir", "kept.txt", "kept" & LF);
      begin
         Version.Files.Write_Binary_File (Index_Path, Before_Index);
         Version.Write.Save ("sparse no-op");

         Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                 "no-op save from sparse index must preserve current branch ref");
         Assert (Version.Test_Support.Read_Text_File (Reflog_Path) = Reflog_Before,
                 "no-op save from sparse index must not append reflog entries");
         Assert (Version.Files.Read_Binary_File (Index_Path) = Before_Index,
                 "no-op save from sparse index must not rewrite the index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Save_Sparse_Index_Loads_Without_Ref_Mutation;


   procedure Merge_Sparse_Index_Desparsifies_And_Merges
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Git_Dir : constant String := Join (Root, ".git");
      Index_Path : constant String := Join (Git_Dir, "index");
      Options : Version.Branch.Merge_Options;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "dir/kept.txt", "kept" & LF, "base");
      Version.Branch.Create_Branch ("feature");
      Version.Branch.Switch_Branch ("feature");
      Save_File (Root, "feature.txt", "feature" & LF, "feature");
      Version.Branch.Switch_Branch ("main");
      Options.Fast_Forward := Version.Branch.Fast_Forward_Disabled;
      Options.Fast_Forward_Explicit := True;

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Reflog_Path : constant String :=
           Join (Join (Join (Git_Dir, "logs"), "refs/heads"), "main");
         Reflog_Before : constant String :=
           Version.Test_Support.Read_Text_File (Reflog_Path);
         Before_Index : constant String :=
           Sparse_Index_With_Directory (Repo, "dir", "kept.txt", "kept" & LF);
      begin
         Version.Files.Write_Binary_File (Index_Path, Before_Index);
         Version.Branch.Merge ("feature", Options);

         Assert (Version.Refs.Current_Commit_Id (Repo) /= Head_Before,
                 "sparse-index merge must advance current branch ref");
         Assert (Version.Test_Support.Read_Text_File (Reflog_Path) /= Reflog_Before,
                 "sparse-index merge must append reflog entry");
         Assert (Version.Files.Read_Binary_File (Index_Path) /= Before_Index,
                 "sparse-index merge must rewrite a normal merged index");
         Assert
           (Ada.Strings.Fixed.Index
              (Version.Files.Read_Binary_File (Index_Path), "sdir") = 0,
            "sparse-index merge result must not retain sparse-index extension");
      end;

      Version.Git_Fixtures.Run
        (Root, "git ls-files -s dir/kept.txt | grep -q '^100644'");
      Version.Git_Fixtures.Run
        (Root, "git ls-files -s feature.txt | grep -q '^100644'");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "feature.txt")) = "feature",
              "sparse-index merge must materialize target file");
      Assert (not Ada.Directories.Exists (Join (Git_Dir, "MERGE_HEAD")),
              "clean sparse-index merge must not leave MERGE_HEAD");
      Assert (not Version.Merge_State.State_Exists (Version.Repository.Open),
              "clean sparse-index merge must not leave Version merge state");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Merge_Sparse_Index_Desparsifies_And_Merges;


   procedure Log_Corrupt_Commit_Graph_Fails_Cleanly
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id := Commit_With_Malformed_Parent (Repo);
      begin
         Point_Main_At (Repo, Bad);
         begin
            declare
               Output : constant String := Version.Log.Log_Head (Repo);
               pragma Unreferenced (Output);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "log must reject a corrupt commit graph cleanly");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Log_Corrupt_Commit_Graph_Fails_Cleanly;

   procedure Branch_Switch_Corrupt_Blob_Fails_Without_Partial_Checkout
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Keep_Path : constant String := Join (Root, "keep.txt");
      Bad_Path : constant String := Join (Root, "bad.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "keep.txt", "keep" & LF, "base");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Main : constant String := Version.Refs.Current_Commit_Id (Repo);
         Bad  : constant Version.Objects.Hex_Object_Id := Commit_With_Corrupt_Blob (Repo, "bad.txt");
      begin
         Write_Branch (Repo, "badblob", Bad);
         begin
            Version.Branch.Switch_Branch ("badblob");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Refs.Current_Branch_Name (Repo) = "main",
                 "failed corrupt-blob switch must leave HEAD on main");
         Assert (Version.Refs.Current_Commit_Id (Repo) = Main,
                 "failed corrupt-blob switch must preserve current branch ref");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "branch switch must reject corrupt blob before completing checkout");
      Assert (Version.Test_Support.Read_Text_File (Keep_Path) = "keep",
              "failed corrupt-blob checkout must preserve existing tracked file");
      Assert (not Ada.Directories.Exists (Bad_Path),
              "failed corrupt-blob checkout must not materialize partial target file");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Switch_Corrupt_Blob_Fails_Without_Partial_Checkout;

   procedure Archive_Corrupt_Blob_Fails_Without_Replacing_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output : constant String := Join (Root, "existing-blob.tar");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (Output, "existing archive bytes" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id := Commit_With_Corrupt_Blob (Repo, "bad.txt");
      begin
         Point_Main_At (Repo, Bad);
         begin
            Version.Archive.Create (Repo, "HEAD", Output, Version.Archive.Tar_Format);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "archive must reject corrupt blob objects");
      Assert (Version.Test_Support.Read_Text_File (Output) = "existing archive bytes",
              "failed archive from corrupt blob must preserve preexisting output");
      Assert (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
              "failed archive from corrupt blob must clean temporary output");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Corrupt_Blob_Fails_Without_Replacing_Output;

   procedure Pack_Only_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id;
      Name : String)
   is
      Objects : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Dir : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), "objects/pack");
      Pack_Path : constant String := Join (Pack_Dir, Name & ".pack");
      Index_Path : constant String := Join (Pack_Dir, Name & ".idx");
   begin
      if not Ada.Directories.Exists (Pack_Dir) then
         Ada.Directories.Create_Path (Pack_Dir);
      end if;

      Objects.Append (Id);
      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Objects,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);
      Version.Files.Delete_File_If_Exists
        (Version.Objects.Loose_Object_Path (Repo, Id));
   end Pack_Only_Object;

   procedure Write_Tag_Ref
     (Repo : Version.Repository.Repository_Handle;
      Name : String;
      Id   : Version.Objects.Hex_Object_Id) is
   begin
      Version.Refs.Atomic_Write_Ref
        (Path      => Join (Join (Version.Repository.Git_Dir (Repo), "refs/tags"), Name),
         Object_Id => Id);
   end Write_Tag_Ref;

   function Malformed_Tag_Content
     (Target_Id : String;
      Target_Type : String := "commit") return String is
   begin
      return
        "object " & Target_Id & LF
        & "type " & Target_Type & LF
        & "tag bad" & LF
        & "tagger Test <test@example.com> 0 +0000" & LF & LF
        & "bad" & LF;
   end Malformed_Tag_Content;

   procedure Assert_Tag_Command_Raises
     (Repo          : Version.Repository.Repository_Handle;
      Tag_Name      : String;
      Revision      : String;
      Expect_List   : Boolean;
      Expect_Verify : Boolean)
   is
      Raised_Resolve : Boolean := False;
      Raised_List    : Boolean := False;
      Raised_Verify  : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve_Commit (Repo, Tag_Name & "^{}");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised_Resolve := True;
      end;

      begin
         declare
            Ignored : constant Version.Tags.Tag_Name_Vectors.Vector :=
              Version.Tags.List_Tags_Points_At (Revision);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised_List := True;
      end;

      begin
         declare
            Ignored : constant Version.Maintenance.Maintenance_Result :=
              Version.Maintenance.Verify (Repo);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised_Verify := True;
      end;

      Assert (Raised_Resolve, "tag peel must reject corrupt annotated tag");
      if Expect_List then
         Assert (Raised_List, "tag list --points-at must reject corrupt annotated tag");
      end if;
      if Expect_Verify then
         Assert (Raised_Verify, "maintenance verify must reject corrupt annotated tag");
      end if;
   end Assert_Tag_Command_Raises;

   procedure Tag_Corrupt_Tag_Object_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sentinel : constant String := Join (Root, "sentinel.txt");
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (Sentinel, "sentinel" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Missing_Target : constant String := "9999999999999999999999999999999999999999";
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "not a commit");

         procedure Run_Case
           (Name          : String;
            Content       : String;
            Revision      : String;
            Expect_List   : Boolean := True;
            Expect_Verify : Boolean := True)
         is
            Bad_Tag : constant Version.Objects.Hex_Object_Id :=
              Write_Raw_Object (Repo => Repo, Kind => "tag", Content => Content);
            Ref_Path : constant String :=
              Join (Join (Version.Repository.Git_Dir (Repo), "refs/tags"), Name);
         begin
            Write_Tag_Ref (Repo, Name, Bad_Tag);
            Assert_Tag_Command_Raises
              (Repo          => Repo,
               Tag_Name      => Name,
               Revision      => Revision,
               Expect_List   => Expect_List,
               Expect_Verify => Expect_Verify);
            Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                    "failed corrupt loose tag command must preserve HEAD");
            Assert (Version.Test_Support.Read_Text_File (Sentinel) = "sentinel",
                    "failed corrupt loose tag command must preserve working-tree files");

            Pack_Only_Object (Repo => Repo, Id => Bad_Tag, Name => "packed-" & Name);
            Assert_Tag_Command_Raises
              (Repo          => Repo,
               Tag_Name      => Name,
               Revision      => Revision,
               Expect_List   => Expect_List,
               Expect_Verify => Expect_Verify);
            Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                    "failed corrupt packed tag command must preserve HEAD");
            Assert (Version.Test_Support.Read_Text_File (Sentinel) = "sentinel",
                    "failed corrupt packed tag command must preserve working-tree files");
            Version.Files.Delete_File_If_Exists (Ref_Path);
         end Run_Case;
      begin
         Run_Case
           (Name          => "bad-missing-object-line",
            Content       => "not-object 1111111111111111111111111111111111111111" & LF,
            Revision      => "HEAD",
            Expect_Verify => True);
         Run_Case
           (Name          => "bad-invalid-target-id",
            Content       => Malformed_Tag_Content
              ("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"),
            Revision      => "HEAD",
            Expect_Verify => True);
         Run_Case
           (Name          => "bad-missing-target",
            Content       => Malformed_Tag_Content (Missing_Target),
            Revision      => "HEAD",
            Expect_Verify => True);
         Run_Case
           (Name          => "bad-blob-target",
            Content       => Malformed_Tag_Content (To_String (Blob_Id), "blob"),
            Revision      => "HEAD",
            Expect_List   => False,
            Expect_Verify => False);
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tag_Corrupt_Tag_Object_Fails_Without_Mutation;

   function Natural_Image (Value : Natural) return String is
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Left);
   end Natural_Image;

   function Delta_Tag_Content
     (Target_Id   : String;
      Tag_Name    : String;
      Target_Type : String := "commit") return String
   is
      Text : Unbounded_String;
   begin
      Append (Text, Malformed_Tag_Content (Target_Id, Target_Type));
      for I in 1 .. 200 loop
         Append
           (Text,
            "shared delta payload line shared delta payload line shared delta payload line"
            & LF);
      end loop;
      Append (Text, "name " & Tag_Name & LF);
      return To_String (Text);
   end Delta_Tag_Content;

   function Git_Write_Tag_Object
     (Root    : String;
      Name    : String;
      Content : String) return Version.Objects.Hex_Object_Id
   is
      Tag_Path : constant String := Join (Root, Name & ".tag");
      Id_Path  : constant String := Join (Root, Name & ".id");
   begin
      Version.Test_Support.Write_Text_File (Tag_Path, Content);
      Version.Git_Fixtures.Run
        (Root, "git hash-object -w -t tag " & Name & ".tag > " & Name & ".id");
      return Version.Objects.To_Object_Id
        (Version.Test_Support.Read_Text_File (Id_Path));
   end Git_Write_Tag_Object;

   procedure Pack_Objects_With_Git
     (Root      : String;
      Pack_Name : String;
      Objects   : Version.Objects.Object_Id_Vectors.Vector)
   is
      List_Path : constant String := Join (Root, Pack_Name & "-objects.txt");
      Lines     : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if not Objects.Is_Empty then
         for I in Objects.First_Index .. Objects.Last_Index loop
            if I /= Objects.First_Index then
               Ada.Strings.Unbounded.Append (Lines, LF);
            end if;
            Ada.Strings.Unbounded.Append (Lines, To_String (Objects.Element (I)));
         end loop;
      end if;

      Version.Test_Support.Write_Text_File
        (List_Path, Ada.Strings.Unbounded.To_String (Lines));
      Version.Git_Fixtures.Run
        (Root,
         "git pack-objects --window=50 --depth=50 .git/objects/pack/"
         & Pack_Name & " < " & Pack_Name & "-objects.txt >/dev/null");
      Version.Git_Fixtures.Run (Root, "git prune-packed");
   end Pack_Objects_With_Git;

   procedure Tag_Delta_Packed_Corrupt_Tag_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sentinel : constant String := Join (Root, "sentinel.txt");
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (Sentinel, "sentinel" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Before : constant String := Version.Refs.Current_Commit_Id (Repo);
         Head_Id : constant String := Head_Before;
         Missing_Target : constant String := "9999999999999999999999999999999999999999";
         Objects : Version.Objects.Object_Id_Vectors.Vector;
         Base_Tag : constant Version.Objects.Hex_Object_Id :=
           Git_Write_Tag_Object
             (Root, "delta-base", Delta_Tag_Content (Head_Id, "delta-base"));
         Valid_Tag : constant Version.Objects.Hex_Object_Id :=
           Git_Write_Tag_Object
             (Root, "delta-valid", Delta_Tag_Content (Head_Id, "delta-valid"));
         Bad_Tag : constant Version.Objects.Hex_Object_Id :=
           Git_Write_Tag_Object
             (Root, "delta-bad", Delta_Tag_Content (Missing_Target, "delta-bad"));
      begin
         Objects.Append (Base_Tag);
         Objects.Append (Valid_Tag);
         Objects.Append (Bad_Tag);
         for I in 1 .. 20 loop
            declare
               N : constant String := Natural_Image (I);
               Filler : constant Version.Objects.Hex_Object_Id :=
                 Git_Write_Tag_Object
                   (Root, "delta-fill" & N,
                    Delta_Tag_Content (Head_Id, "delta-fill" & N));
            begin
               Objects.Append (Filler);
            end;
         end loop;

         Pack_Objects_With_Git (Root, "delta-tags", Objects);
         Version.Git_Fixtures.Run
           (Root,
            "git verify-pack -v .git/objects/pack/delta-tags-*.idx | "
            & "awk '$1==""" & To_String (Bad_Tag) & """ && NF >= 7 { found=1 } "
            & "END { exit found ? 0 : 1 }'");

         Write_Tag_Ref (Repo, "delta-valid", Valid_Tag);
         Assert
           (Version.Revisions.Resolve_Commit (Repo, "delta-valid^{}")
            = Version.Objects.To_Object_Id (Head_Before),
            "delta-packed valid annotated tag must peel to HEAD");
         Version.Files.Delete_File_If_Exists
           (Join (Join (Version.Repository.Git_Dir (Repo), "refs/tags"), "delta-valid"));

         Write_Tag_Ref (Repo, "delta-bad", Bad_Tag);
         Assert_Tag_Command_Raises
           (Repo          => Repo,
            Tag_Name      => "delta-bad",
            Revision      => "HEAD",
            Expect_List   => True,
            Expect_Verify => True);
         Assert (Version.Refs.Current_Commit_Id (Repo) = Head_Before,
                 "failed corrupt delta-packed tag command must preserve HEAD");
         Assert (Version.Test_Support.Read_Text_File (Sentinel) = "sentinel",
                 "failed corrupt delta-packed tag command must preserve worktree files");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tag_Delta_Packed_Corrupt_Tag_Fails_Without_Mutation;

   procedure Submodule_Corrupt_Gitmodules_Blob_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Sentinel : constant String := Join (Root, "sentinel.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File (Sentinel, "sentinel" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Bad  : constant Version.Objects.Hex_Object_Id := Commit_With_Corrupt_Gitmodules_Blob (Repo);
      begin
         Point_Main_At (Repo, Bad);
         begin
            declare
               Items : constant Version.Submodules.Submodule_Status_Vectors.Vector :=
                 Version.Submodules.Statuses (Repo);
               pragma Unreferenced (Items);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "submodule command boundary must reject corrupt .gitmodules blob");
      Assert (Version.Test_Support.Read_Text_File (Sentinel) = "sentinel",
              "failed submodule status must not mutate working-tree files");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Submodule_Corrupt_Gitmodules_Blob_Fails_Without_Mutation;

   procedure Stash_Create_Corrupt_Index_Fails_Without_Stack_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Index_Path : constant String := Join (Join (Root, ".git"), "index");
      File_Path : constant String := Join (Root, "a.txt");
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (File_Path, "dirty" & LF);
      Version.Test_Support.Write_Text_File (Index_Path, "corrupt-index-before-stash-create");

      begin
         declare
            Id : constant String := Version.Stash.Create;
            pragma Unreferenced (Id);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
              "failed stash create must not update refs/stash");
      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash create must reject corrupt index input");
      Assert (Version.Test_Support.Read_Text_File (Index_Path) = "corrupt-index-before-stash-create",
              "failed stash create must not rewrite corrupt index");
      Assert (Version.Test_Support.Read_Text_File (File_Path) = "dirty",
              "failed stash create must preserve dirty working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Create_Corrupt_Index_Fails_Without_Stack_Mutation;

   procedure Stash_Store_Corrupt_Commit_Fails_Without_Stack_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "dirty" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Stash.Create);
      begin
         Corrupt_Loose_Object (Repo, Id);
         begin
            Version.Stash.Store (Id, "corrupt stash");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Stash.List_Entries (Repo).Is_Empty,
                 "failed stash store must not update refs/stash");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash store must reject corrupt stash commit objects");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "dirty",
              "failed stash store must preserve working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Store_Corrupt_Commit_Fails_Without_Stack_Mutation;

   procedure Stash_Show_Corrupt_Stash_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "dirty" & LF);
      Version.Stash.Push;

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Stash_Id : constant Version.Objects.Hex_Object_Id := Version.Stash.Resolve_Stash (Repo, "stash@{0}");
      begin
         Corrupt_Loose_Object (Repo, Stash_Id);
         begin
            declare
               Text : constant String := Version.Stash.Show;
               pragma Unreferenced (Text);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Stash.List_Entries (Repo).Length = 1,
                 "failed stash show must preserve stash stack");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash show must reject corrupt stash commit objects");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash show must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Show_Corrupt_Stash_Fails_Without_Mutation;

   procedure Stash_Apply_Corrupt_Untracked_Parent_Fails_Without_Partial_Write
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs : Version.Pathspec.Pathspec_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "dirty" & LF);
      Version.Test_Support.Write_Text_File (Join (Root, "u.txt"), "untracked" & LF);
      Version.Stash.Push (Include_Untracked => True);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Stash_Id : constant Version.Objects.Hex_Object_Id := Version.Stash.Resolve_Stash (Repo, "stash@{0}");
         Stash_Obj : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Stash_Id);
         Parents : constant Version.Objects.Object_Id_Vectors.Vector := Version.Objects.Commit_Parent_Ids (Stash_Obj);
      begin
         Assert (Parents.Length = 3, "fixture must create an untracked stash parent");
         Corrupt_Loose_Object (Repo, Parents.Element (Parents.First_Index + 2));
         Version.Pathspec.Append_Parse (Specs, "a.txt");
         Version.Pathspec.Append_Parse (Specs, "u.txt");

         begin
            Version.Stash.Apply (Pathspecs => Specs);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Stash.List_Entries (Repo).Length = 1,
                 "failed stash apply must keep the stash entry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash apply must reject corrupt untracked stash parents");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash apply must not partially restore tracked paths");
      Assert (not Ada.Directories.Exists (Join (Root, "u.txt")),
              "failed stash apply must not partially restore untracked paths");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Corrupt_Untracked_Parent_Fails_Without_Partial_Write;

   procedure Stash_List_Malformed_Reflog_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Log_Path : constant String := Stash_Log_Path (Root);
      Ref_Path : constant String := Stash_Ref_Path (Root);
      Zero_Id : constant String := Version.Stash_Test_Support.Zero_Id;
      Bad_Log : constant String := Version.Stash.Malformed_Stash_Reflog_Diagnostic;

      procedure Assert_Malformed_Reflog (Line, Label : String) is
         Ref_Before : constant String := Version.Test_Support.Read_Text_File (Ref_Path);
         Raised : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File (Log_Path, Line & LF);
         begin
            declare
               Entries : constant Version.Stash.Stash_Entry_Vectors.Vector :=
                 Version.Stash.List_Entries (Version.Repository.Open);
               pragma Unreferenced (Entries);
            begin
               null;
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Stash.Malformed_Stash_Reflog_Diagnostic,
                  Label & " must use the public malformed reflog diagnostic");
         end;

         Assert (Raised, Label & " must reject malformed stash reflog lines");
         Assert (Version.Test_Support.Read_Text_File (Ref_Path) = Ref_Before,
                 Label & " must preserve refs/stash bytes");
         Assert (Version.Test_Support.Read_Text_File (Log_Path) = Line,
                 Label & " must preserve malformed reflog bytes");
      end Assert_Malformed_Reflog;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "dirty" & LF);
      Version.Stash.Push;

      declare
         Valid_Id : constant String := Version.Test_Support.Read_Text_File (Ref_Path);
      begin
         Assert_Malformed_Reflog (Bad_Log, "short stash reflog line");
         Assert_Malformed_Reflog
           (Version.Stash_Test_Support.Stash_Reflog_Line
              ("x" & Zero_Id (Zero_Id'First + 1 .. Zero_Id'Last),
               Valid_Id, "bad old id"),
            "bad old stash reflog id");
         Assert_Malformed_Reflog
           (Zero_Id & ":" & Valid_Id
            & " Version <version@example.invalid> 0 +0000" & Character'Val (9) & "bad separator",
            "bad stash reflog id separator");
         Assert_Malformed_Reflog
           (Version.Stash_Test_Support.Stash_Reflog_Line
              (Zero_Id, "x" & Valid_Id (Valid_Id'First + 1 .. Valid_Id'Last),
               "bad new id"),
            "bad new stash reflog id");
         Assert_Malformed_Reflog
           (Zero_Id & " " & Valid_Id
            & " Version <version@example.invalid> 0 +0000 no-tab-message",
            "missing stash reflog tab separator");
         Assert_Malformed_Reflog
           (Zero_Id & " " & Valid_Id & Character'Val (9),
            "empty stash reflog message");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_List_Malformed_Reflog_Fails_Without_Mutation;

   procedure Stash_Drop_Missing_Reflog_Target_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Missing_Id : constant String := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Write_Stash_Storage (Root, Missing_Id, "missing stash target");

      declare
         Ref_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root));
         Log_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Log_Path (Root));
      begin
         begin
            Version.Stash.Drop;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = Ref_Before,
                 "failed stash drop must preserve refs/stash bytes");
         Assert (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root)) = Log_Before,
                 "failed stash drop must preserve stash reflog bytes");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash drop must reject missing stash targets before rewrite");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash drop must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Drop_Missing_Reflog_Target_Fails_Without_Mutation;

   procedure Stash_Pop_And_Branch_Missing_Target_Fail_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Missing_Id : constant String := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
      Pop_Raised : Boolean := False;
      Branch_Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Write_Stash_Storage (Root, Missing_Id, "missing stash target");

      declare
         Ref_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root));
         Log_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Log_Path (Root));
      begin
         begin
            Version.Stash.Pop;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Pop_Raised := True;
         end;

         begin
            Version.Stash.Branch ("feature");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Branch_Raised := True;
         end;

         Assert (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = Ref_Before,
                 "failed stash pop/branch must preserve refs/stash bytes");
         Assert (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root)) = Log_Before,
                 "failed stash pop/branch must preserve stash reflog bytes");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Pop_Raised, "stash pop must reject missing stash targets");
      Assert (Branch_Raised, "stash branch must reject missing stash targets");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash pop/branch must not mutate working-tree content");
      Assert (not Ada.Directories.Exists (Join (Join (Join (Root, ".git"), "refs/heads"), "feature")),
              "failed stash branch must not create the target branch");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_And_Branch_Missing_Target_Fail_Without_Mutation;

   procedure Stash_List_Broken_Reflog_Chain_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Bad_Old : constant String := Version.Stash_Test_Support.Bad_Old_Id;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "first" & LF);
      Version.Stash.Push;

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         First_Id : constant String := To_String (Version.Stash.Resolve_Stash (Repo, "stash@{0}"));
      begin
         Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "second" & LF);
         Version.Stash.Push;

         declare
            Second_Id : constant String := To_String (Version.Stash.Resolve_Stash (Repo, "stash@{0}"));
            Ref_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root));
            Broken_Log : constant String :=
              Version.Stash_Test_Support.Broken_Reflog_Chain
                (First_Id => First_Id, Second_Id => Second_Id, Bad_Old => Bad_Old);
         begin
            Version.Test_Support.Write_Text_File (Stash_Log_Path (Root), Broken_Log);
            begin
               declare
                  Entries : constant Version.Stash.Stash_Entry_Vectors.Vector :=
                    Version.Stash.List_Entries (Repo);
                  pragma Unreferenced (Entries);
               begin
                  null;
               end;
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Assert
                    (Ada.Exceptions.Exception_Message (E)
                     = Version.Stash.Inconsistent_Stash_Storage_Diagnostic,
                     "broken stash reflog chain must use inconsistent-storage diagnostic");
            end;

            Assert (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = Ref_Before,
                    "failed broken-chain stash list must preserve refs/stash bytes");
            Assert
              (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root))
               = Broken_Log (Broken_Log'First .. Broken_Log'Last - 1),
               "failed broken-chain stash list must preserve stash reflog bytes");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash list must reject broken stash reflog old-id chains");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed broken-chain stash list must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_List_Broken_Reflog_Chain_Fails_Without_Mutation;

   procedure Stash_List_Ref_Reflog_Mismatch_Fails_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "first" & LF);
      Version.Stash.Push;

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Older_Id : constant Version.Objects.Hex_Object_Id := Version.Stash.Resolve_Stash (Repo, "stash@{0}");
      begin
         Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "second" & LF);
         Version.Stash.Push;

         declare
            Log_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Log_Path (Root));
         begin
            Version.Test_Support.Write_Text_File (Stash_Ref_Path (Root), To_String (Older_Id) & LF);
            begin
               declare
                  Entries : constant Version.Stash.Stash_Entry_Vectors.Vector :=
                    Version.Stash.List_Entries (Repo);
                  pragma Unreferenced (Entries);
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = To_String (Older_Id),
                    "failed stash list must preserve mismatched refs/stash bytes");
            Assert (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root)) = Log_Before,
                    "failed stash list must preserve mismatched stash reflog bytes");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stash list must reject refs/stash and reflog top mismatches");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash list mismatch check must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_List_Ref_Reflog_Mismatch_Fails_Without_Mutation;

   procedure Stash_Read_Paths_Ref_Reflog_Mismatch_Fail_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Resolve_Raised : Boolean := False;
      Show_Raised : Boolean := False;
      Apply_Raised : Boolean := False;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "first" & LF);
      Version.Stash.Push;

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Older_Id : constant Version.Objects.Hex_Object_Id := Version.Stash.Resolve_Stash (Repo, "stash@{0}");
      begin
         Version.Test_Support.Write_Text_File (Join (Root, "a.txt"), "second" & LF);
         Version.Stash.Push;

         declare
            Log_Before : constant String := Version.Test_Support.Read_Text_File (Stash_Log_Path (Root));
         begin
            Version.Test_Support.Write_Text_File (Stash_Ref_Path (Root), To_String (Older_Id) & LF);

            begin
               declare
                  Id : constant Version.Objects.Hex_Object_Id := Version.Stash.Resolve_Stash (Repo, "stash@{0}");
                  pragma Unreferenced (Id);
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Resolve_Raised := True;
            end;

            begin
               declare
                  Text : constant String := Version.Stash.Show;
                  pragma Unreferenced (Text);
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Show_Raised := True;
            end;

            begin
               Version.Stash.Apply;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Apply_Raised := True;
            end;

            Assert (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = To_String (Older_Id),
                    "failed stash read paths must preserve mismatched refs/stash bytes");
            Assert (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root)) = Log_Before,
                    "failed stash read paths must preserve mismatched stash reflog bytes");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Resolve_Raised, "stash resolve must reject refs/stash and reflog top mismatches");
      Assert (Show_Raised, "stash show must reject refs/stash and reflog top mismatches");
      Assert (Apply_Raised, "stash apply must reject refs/stash and reflog top mismatches");
      Assert (Version.Test_Support.Read_Text_File (Join (Root, "a.txt")) = "base",
              "failed stash read paths mismatch check must not mutate working-tree content");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Read_Paths_Ref_Reflog_Mismatch_Fail_Without_Mutation;

   procedure Stash_Clear_Inconsistent_Storage_Removes_Ref_And_Log
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Missing_Id : constant String := "cccccccccccccccccccccccccccccccccccccccc";
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Save_File (Root, "a.txt", "base" & LF, "base");
      Write_Stash_Storage (Root, Missing_Id, "missing stash target");
      Version.Test_Support.Write_Text_File
        (Stash_Log_Path (Root), Version.Stash.Malformed_Stash_Reflog_Diagnostic & LF);

      Version.Stash.Clear;

      Assert (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
              "stash clear must remove inconsistent refs/stash");
      Assert (not Ada.Directories.Exists (Stash_Log_Path (Root)),
              "stash clear must remove inconsistent stash reflog");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Clear_Inconsistent_Storage_Removes_Ref_And_Log;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Stage_Corrupt_Index_Fails_Without_Rewriting_Index'Access,
         "Command corruption: stage rejects corrupt index without rewriting index");
      Register_Routine
        (T, Stage_Sparse_Index_Desparsifies_On_Write'Access,
         "Command corruption: stage desparsifies sparse index on write");
      Register_Routine
        (T, Save_Corrupt_Index_Fails_Before_Ref_Mutation'Access,
         "Command corruption: save rejects corrupt index before ref/reflog mutation");
      Register_Routine
        (T, Save_Sparse_Index_Loads_Without_Ref_Mutation'Access,
         "Command corruption: save loads sparse index without ref mutation");
      Register_Routine
        (T, Merge_Sparse_Index_Desparsifies_And_Merges'Access,
         "Command corruption: merge desparsifies sparse index and merges");
      Register_Routine
        (T, Log_Corrupt_Commit_Graph_Fails_Cleanly'Access,
         "Command corruption: log rejects corrupt commit graph cleanly");
      Register_Routine
        (T, Branch_Switch_Corrupt_Blob_Fails_Without_Partial_Checkout'Access,
         "Command corruption: branch switch rejects corrupt blob without partial checkout");
      Register_Routine
        (T, Archive_Corrupt_Blob_Fails_Without_Replacing_Output'Access,
         "Command corruption: archive rejects corrupt blob without replacing output");
      Register_Routine
        (T, Submodule_Corrupt_Gitmodules_Blob_Fails_Without_Mutation'Access,
         "Command corruption: submodule rejects corrupt .gitmodules blob without mutation");
      Register_Routine
        (T, Tag_Corrupt_Tag_Object_Fails_Without_Mutation'Access,
         "Command corruption: tag rejects corrupt annotated tag without mutation");
      Register_Routine
        (T, Tag_Delta_Packed_Corrupt_Tag_Fails_Without_Mutation'Access,
         "Command corruption: tag rejects corrupt delta-packed annotated tag");
      Register_Routine
        (T, Status_Corrupt_Index_Fails_Without_Mutation'Access,
         "Command corruption: status rejects corrupt index without mutation");
      Register_Routine
        (T, Restore_Corrupt_Source_Tree_Fails_Without_Mutation'Access,
         "Command corruption: restore rejects corrupt source tree without mutation");
      Register_Routine
        (T, Branch_Switch_Corrupt_Target_Tree_Fails_Without_Mutation'Access,
         "Command corruption: branch switch rejects corrupt target tree without mutation");
      Register_Routine
        (T, Archive_Corrupt_Tree_Fails_Without_Replacing_Output'Access,
         "Command corruption: archive rejects corrupt tree without replacing output");
      Register_Routine
        (T, Fetch_Corrupt_Local_Object_Fails_Before_Ref_Update'Access,
         "Command corruption: fetch rejects corrupt local object before ref update");
      Register_Routine
        (T, Stash_Create_Corrupt_Index_Fails_Without_Stack_Mutation'Access,
         "Command corruption: stash create rejects corrupt index without stack mutation");
      Register_Routine
        (T, Stash_Store_Corrupt_Commit_Fails_Without_Stack_Mutation'Access,
         "Command corruption: stash store rejects corrupt commit without stack mutation");
      Register_Routine
        (T, Stash_Show_Corrupt_Stash_Fails_Without_Mutation'Access,
         "Command corruption: stash show rejects corrupt stash without mutation");
      Register_Routine
        (T, Stash_Apply_Corrupt_Untracked_Parent_Fails_Without_Partial_Write'Access,
         "Command corruption: stash apply rejects corrupt untracked parent without partial write");
      Register_Routine
        (T, Stash_List_Malformed_Reflog_Fails_Without_Mutation'Access,
         "Command corruption: stash list rejects malformed reflog without mutation");
      Register_Routine
        (T, Stash_Drop_Missing_Reflog_Target_Fails_Without_Mutation'Access,
         "Command corruption: stash drop rejects missing reflog target without mutation");
      Register_Routine
        (T, Stash_Pop_And_Branch_Missing_Target_Fail_Without_Mutation'Access,
         "Command corruption: stash pop and branch reject missing reflog targets without mutation");
      Register_Routine
        (T, Stash_List_Broken_Reflog_Chain_Fails_Without_Mutation'Access,
         "Command corruption: stash list rejects broken reflog chain without mutation");
      Register_Routine
        (T, Stash_List_Ref_Reflog_Mismatch_Fails_Without_Mutation'Access,
         "Command corruption: stash list rejects ref/reflog mismatch without mutation");
      Register_Routine
        (T, Stash_Read_Paths_Ref_Reflog_Mismatch_Fail_Without_Mutation'Access,
         "Command corruption: stash read paths reject ref/reflog mismatch without mutation");
      Register_Routine
        (T, Stash_Clear_Inconsistent_Storage_Removes_Ref_And_Log'Access,
         "Command corruption: stash clear removes inconsistent stash storage");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Command_Corruption");
   end Name;

end Version.Command_Corruption.Tests;
