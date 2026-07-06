with Ada.Containers;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Tags;
with Version.Test_Support;

use type Ada.Containers.Count_Type;

package body Version.Packed_Refs.Tests is
   use Version.Objects;

   use AUnit.Assertions;

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   function Read_File (Path : String) return String is
   begin
      return Version.Files.Read_Binary_File (Path);
   end Read_File;

   procedure With_Fresh_Repo
     (T   : in out AUnit.Test_Cases.Test_Case'Class;
      Old : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Old := Ada.Strings.Unbounded.To_Unbounded_String
        (Ada.Directories.Current_Directory);

      Ada.Directories.Set_Directory (Root);
      Version.Init.Init (".");
   end With_Fresh_Repo;

   Main_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("0123456789012345678901234567890123456789");

   procedure Write_Ref
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
   begin
      Version.Refs.Atomic_Write_Ref
        (Path      => Join (Version.Repository.Git_Dir (Repo), Name),
         Object_Id => Main_Id);
   end Write_Ref;

   procedure Write_Main_Ref (Repo : Version.Repository.Repository_Handle) is
   begin
      Write_Ref (Repo, "refs/heads/main");
   end Write_Main_Ref;

   procedure Missing_File_Returns_Empty
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
           Version.Packed_Refs.Read_All (Repo);
      begin
         Assert (Refs.Is_Empty, "missing packed-refs should read as empty");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Missing_File_Returns_Empty;

   procedure Write_Read_And_Find
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Found_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/tags/v1"),
             Id   => Version.Objects.To_Object_Id ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Version.Objects.To_Object_Id ("0123456789012345678901234567890123456789")));

         Version.Packed_Refs.Write_All (Repo, Refs);

         Assert
           (Version.Packed_Refs.Find
              (Repo => Repo,
               Name => "refs/heads/main",
               Id   => Found_Id),
            "find should locate written packed branch");

         Assert
           (To_String (Found_Id) = "0123456789012345678901234567890123456789",
            "find returned wrong object id");

         declare
            Text : constant String :=
              Read_File (Join (Version.Repository.Git_Dir (Repo), "packed-refs"));
         begin
            Assert
              (Text = "# pack-refs with: sorted" & Character'Val (10)
                 & "0123456789012345678901234567890123456789 refs/heads/main"
                 & Character'Val (10)
                 & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/tags/v1"
                 & Character'Val (10),
               "packed-refs output should be sorted and deterministic");
         end;
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Write_Read_And_Find;

   procedure Rejects_Malformed_Object_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Test_Support.Write_Text_File
           (Join (Version.Repository.Git_Dir (Repo), "packed-refs"),
            "not-a-valid-object refs/heads/main" & Character'Val (10));

         begin
            declare
               Ignored : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
                 Version.Packed_Refs.Read_All (Repo);
            begin
               Assert (Ignored.Is_Empty, "unreachable");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "malformed packed-ref id should raise Data_Error");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Rejects_Malformed_Object_Id;

   procedure Rejects_Malformed_Write_Object_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
      begin
         Refs.Append
           (Packed_Ref'(Name => Ada.Strings.Unbounded.To_Unbounded_String ("refs/heads/main"),
             Id   => Version.Objects.To_Object_Id ("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")));

         begin
            Version.Packed_Refs.Write_All (Repo, Refs);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "Write_All should reject malformed object ids");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Rejects_Malformed_Write_Object_Id;

   procedure Pack_Loose_Heads_And_Tags
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Write_Main_Ref (Repo);
         Write_Ref (Repo, "refs/heads/feature/x");
         Write_Ref (Repo, "refs/tags/release/v1.0");
         Version.Packed_Refs.Pack_Refs (Repo);

         declare
            Text : constant String :=
              Read_File (Join (Version.Repository.Git_Dir (Repo), "packed-refs"));
         begin
            Assert
              (Ada.Strings.Fixed.Index (Text, "refs/heads/main") /= 0,
               "pack-refs should include main branch");
            Assert
              (Ada.Strings.Fixed.Index (Text, "refs/heads/feature/x") /= 0,
               "pack-refs should include nested branch");
            Assert
              (Ada.Strings.Fixed.Index (Text, "refs/tags/release/v1.0") /= 0,
               "pack-refs should include nested tag");
         end;
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Pack_Loose_Heads_And_Tags;

   procedure Loose_Overrides_Packed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Write_Main_Ref (Repo);
         declare
            Loose_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
         begin
            Version.Test_Support.Write_Text_File
            (Join (Version.Repository.Git_Dir (Repo), "packed-refs"),
            "# pack-refs with: sorted" & Character'Val (10)
            & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/main"
            & Character'Val (10));

            Assert
              (Version.Refs.Current_Commit_Id (Repo) = Loose_Id,
               "loose branch ref should override packed branch ref");
         end;
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Loose_Overrides_Packed;

   procedure Prune_Removes_Loose_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Git_Dir (Repo);
      begin
         Write_Main_Ref (Repo);
         Version.Tags.Create_Tag ("v1");
         Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);

         Assert
           (not Ada.Directories.Exists (Join (Git_Dir, "refs/tags/v1")),
            "prune should remove packed loose tag");
         Assert
           (Version.Refs.Ref_Exists (Repo, "refs/tags/v1"),
            "packed tag should still resolve after pruning loose tag");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Prune_Removes_Loose_Refs;

   procedure Pack_Refs_Rejects_Malformed_Loose_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
      Existing_Packed_Content : constant String :=
        "# pack-refs with: sorted" & Character'Val (10)
        & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/tags/existing"
        & Character'Val (10);
      Bad_Ref_Content : constant String := "not-an-object-id" & Character'Val (10);
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Git_Dir (Repo);
         Packed_Path : constant String := Join (Git_Dir, "packed-refs");
         Bad_Ref_Path : constant String := Join (Git_Dir, "refs/heads/bad");
      begin
         Write_Main_Ref (Repo);
         Version.Test_Support.Write_Text_File
           (Packed_Path, Existing_Packed_Content);
         Version.Test_Support.Write_Text_File
           (Bad_Ref_Path, Bad_Ref_Content);

         declare
            Packed_Before : constant String := Read_File (Packed_Path);
            Bad_Ref_Before : constant String := Read_File (Bad_Ref_Path);
         begin
            begin
               Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "pack-refs should reject malformed loose branch refs");
            Assert
              (Read_File (Packed_Path) = Packed_Before,
               "malformed loose branch must not rewrite packed-refs");
            Assert
              (Read_File (Bad_Ref_Path) = Bad_Ref_Before,
               "malformed loose branch must be preserved");
            Assert
              (Ada.Directories.Exists (Join (Git_Dir, "refs/heads/main")),
               "valid loose branch must not be pruned after failure");
         end;
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Pack_Refs_Rejects_Malformed_Loose_Branch;

   procedure Pack_Refs_Rejects_Malformed_Loose_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
      Existing_Packed_Content : constant String :=
        "# pack-refs with: sorted" & Character'Val (10)
        & To_String (Main_Id) & " refs/heads/main" & Character'Val (10);
      Bad_Ref_Content : constant String := "not-an-object-id" & Character'Val (10);
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Git_Dir (Repo);
         Packed_Path : constant String := Join (Git_Dir, "packed-refs");
         Bad_Ref_Path : constant String := Join (Git_Dir, "refs/tags/bad");
      begin
         Write_Main_Ref (Repo);
         Version.Tags.Create_Tag ("good");
         Version.Test_Support.Write_Text_File
           (Packed_Path, Existing_Packed_Content);
         Version.Test_Support.Write_Text_File
           (Bad_Ref_Path, Bad_Ref_Content);

         declare
            Packed_Before : constant String := Read_File (Packed_Path);
            Bad_Ref_Before : constant String := Read_File (Bad_Ref_Path);
         begin
            begin
               Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "pack-refs should reject malformed loose tag refs");
            Assert
              (Read_File (Packed_Path) = Packed_Before,
               "malformed loose tag must not rewrite packed-refs");
            Assert
              (Read_File (Bad_Ref_Path) = Bad_Ref_Before,
               "malformed loose tag must be preserved");
            Assert
              (Ada.Directories.Exists (Join (Git_Dir, "refs/tags/good")),
               "valid loose tag must not be pruned after failure");
         end;
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Pack_Refs_Rejects_Malformed_Loose_Tag;

   procedure Ignores_Comments_Blanks_And_Peeled_Lines
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
      begin
         Version.Test_Support.Write_Text_File
           (Join (Version.Repository.Git_Dir (Repo), "packed-refs"),
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10)
            & Character'Val (10)
            & "0123456789012345678901234567890123456789 refs/heads/main"
            & Character'Val (10)
            & "^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            & Character'Val (10));

         Refs := Version.Packed_Refs.Read_All (Repo);

         Assert (Refs.Length = 1, "comments, blanks, and peeled lines should be ignored");
         Assert
           (Ada.Strings.Unbounded.To_String (Refs.Element (0).Name) = "refs/heads/main",
            "remaining packed ref should be main");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Ignores_Comments_Blanks_And_Peeled_Lines;

   procedure Rejects_Malformed_Peeled_Lines
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;

      procedure Assert_Read_All_Raises
        (Repo    : Version.Repository.Repository_Handle;
         Content : String;
         Message : String)
      is
         Raised : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File
           (Join (Version.Repository.Git_Dir (Repo), "packed-refs"),
            Content);

         begin
            declare
               Ignored : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
                 Version.Packed_Refs.Read_All (Repo);
            begin
               Assert (Ignored.Is_Empty, "unreachable");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, Message);
      end Assert_Read_All_Raises;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Ref_Line : constant String :=
           "0123456789012345678901234567890123456789 refs/tags/v1"
           & Character'Val (10);
      begin
         Assert_Read_All_Raises
           (Repo,
            "^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            & Character'Val (10),
            "orphan packed-ref peeled line should raise Data_Error");

         Assert_Read_All_Raises
           (Repo,
            Ref_Line
            & "^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            & Character'Val (10),
            "short packed-ref peeled line should raise Data_Error");

         Assert_Read_All_Raises
           (Repo,
            Ref_Line
            & "^not-a-valid-peeled-object-id"
            & Character'Val (10),
            "malformed packed-ref peeled id should raise Data_Error");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Rejects_Malformed_Peeled_Lines;

   procedure Branch_Lookup_Falls_Back_To_Packed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Git_Dir (Repo);
      begin
         Write_Main_Ref (Repo);
         Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);

         Assert
           (not Ada.Directories.Exists (Join (Git_Dir, "refs/heads/main")),
            "prune should remove packed loose branch");
         Assert
           (To_String (Version.Branch.Resolve_Branch ("main")) = To_String (Main_Id),
            "branch lookup should fall back to packed refs");
         Assert
           (Version.Refs.Current_Commit_Id (Repo) = To_String (Main_Id),
            "current commit lookup should fall back to packed current branch");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Branch_Lookup_Falls_Back_To_Packed;

   procedure Tag_List_Includes_Packed_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
      Found : Boolean := False;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Write_Main_Ref (Repo);
         Version.Tags.Create_Tag ("v1");
         Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);

         declare
            Tags : constant Version.Tags.Tag_Name_Vectors.Vector := Version.Tags.List_Tags;
         begin
            if not Tags.Is_Empty then
               for I in Tags.First_Index .. Tags.Last_Index loop
                  if Ada.Strings.Unbounded.To_String (Tags.Element (I)) = "v1" then
                     Found := True;
                  end if;
               end loop;
            end if;
         end;
      end;

      Assert (Found, "tag list should include packed-only tags");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Tag_List_Includes_Packed_Tag;

   procedure Packed_Only_Tag_Delete_Removes_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Write_Main_Ref (Repo);
         Version.Tags.Create_Tag ("v1");
         Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);
         Assert
           (Version.Tags.Delete_Tag_Text ("v1")
            = "deleted tag v1 " & To_String (Main_Id),
            "packed tag delete text must include deleted object id");

         Assert
           (not Version.Refs.Ref_Exists (Repo, "refs/tags/v1"),
            "deleting packed-only tag should rewrite packed-refs without that tag");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Packed_Only_Tag_Delete_Removes_Packed_Ref;

   procedure Git_Show_Ref_Sees_Packed_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U : Ada.Strings.Unbounded.Unbounded_String;
      Root  : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Old_U := Ada.Strings.Unbounded.To_Unbounded_String
        (Ada.Directories.Current_Directory);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Version.Git_Fixtures.Run (Root, "git branch -M main");
      Version.Git_Fixtures.Run (Root, "git tag v1");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      begin
         Version.Packed_Refs.Pack_Refs (Repo => Repo, Prune_Loose => True);

         Version.Git_Fixtures.Run
           (Root,
            "git show-ref --verify refs/heads/main && "
            & "git show-ref --verify refs/tags/v1 && "
            & "git fsck --strict");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Git_Show_Ref_Sees_Packed_Refs;

   procedure Failed_Write_Removes_Created_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U  : Ada.Strings.Unbounded.Unbounded_String;
      Raised : Boolean := False;
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Packed_Path : constant String :=
           Join (Version.Repository.Git_Dir (Repo), "packed-refs");
         Lock_Path : constant String := Packed_Path & ".lock";
      begin
         Ada.Directories.Create_Directory (Packed_Path);

         begin
            Version.Packed_Refs.Write_All (Repo, Refs);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "packed-refs target directory should fail write");
         Assert
           (not Ada.Directories.Exists (Lock_Path),
            "failed packed-refs write must remove created lock file");
      end;

      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Failed_Write_Removes_Created_Lock;

   procedure Lock_File_Blocks_Write
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_U                   : Ada.Strings.Unbounded.Unbounded_String;
      Raised                  : Boolean := False;
      Existing_Packed_Content : constant String :=
        "# pack-refs with: sorted" & Character'Val (10)
        & To_String (Main_Id) & " refs/heads/main" & Character'Val (10);
      Existing_Lock_Content   : constant String := "stale lock";
   begin
      With_Fresh_Repo (T, Old_U);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Refs : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
         Packed_Path : constant String :=
           Join (Version.Repository.Git_Dir (Repo), "packed-refs");
         Lock_Path : constant String := Packed_Path & ".lock";
      begin
         Version.Test_Support.Write_Text_File
           (Packed_Path, Existing_Packed_Content);
         Version.Test_Support.Write_Text_File
           (Lock_Path, Existing_Lock_Content);

         declare
            Packed_Before : constant String := Read_File (Packed_Path);
            Lock_Before   : constant String := Read_File (Lock_Path);
         begin
            begin
               Version.Packed_Refs.Write_All (Repo, Refs);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Read_File (Packed_Path) = Packed_Before,
               "blocked packed-refs write must preserve existing packed refs");
            Assert
              (Read_File (Lock_Path) = Lock_Before,
               "blocked packed-refs write must preserve stale lock");
         end;
      end;

      Assert (Raised, "existing packed-refs.lock should block write");
      Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
   exception
      when others =>
         Ada.Directories.Set_Directory (Ada.Strings.Unbounded.To_String (Old_U));
         raise;
   end Lock_File_Blocks_Write;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Missing_File_Returns_Empty'Access,
         "Packed refs missing file returns empty");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Write_Read_And_Find'Access,
         "Packed refs write/read/find and deterministic sort");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rejects_Malformed_Object_Id'Access,
         "Packed refs reject malformed object id");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rejects_Malformed_Write_Object_Id'Access,
         "Packed refs reject malformed object id on write");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Pack_Loose_Heads_And_Tags'Access,
         "Pack loose heads and tags");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Loose_Overrides_Packed'Access,
         "Loose refs override packed refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Prune_Removes_Loose_Refs'Access,
         "Prune removes packed loose refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Pack_Refs_Rejects_Malformed_Loose_Branch'Access,
         "Pack refs reject malformed loose branch");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Pack_Refs_Rejects_Malformed_Loose_Tag'Access,
         "Pack refs reject malformed loose tag");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Ignores_Comments_Blanks_And_Peeled_Lines'Access,
         "Packed refs ignore comments blanks and peeled lines");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rejects_Malformed_Peeled_Lines'Access,
         "Packed refs reject malformed peeled lines");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Branch_Lookup_Falls_Back_To_Packed'Access,
         "Branch lookup falls back to packed refs");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Tag_List_Includes_Packed_Tag'Access,
         "Tag list includes packed-only tag");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Packed_Only_Tag_Delete_Removes_Packed_Ref'Access,
         "Packed-only tag delete removes packed ref");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Git_Show_Ref_Sees_Packed_Refs'Access,
         "Git show-ref sees packed branch and tag");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Failed_Write_Removes_Created_Lock'Access,
         "Packed refs failed write removes created lock");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Lock_File_Blocks_Write'Access,
         "Packed refs stale lock preserves files");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Packed_Refs");
   end Name;

end Version.Packed_Refs.Tests;
