with AUnit.Assertions;
with AUnit.Test_Cases;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Version.Repository;
with Version.Objects;
with Version.Ref_Cache;
with Version.Test_Support;
with Ada.Directories;

package body Version.Refs.Tests is
   use Version.Objects;

   use AUnit.Assertions;

   procedure Create_Basic_Repo
     (Root : String)
   is
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

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Heads, "main"),
         "0123456789012345678901234567890123456789");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Heads, "feature"),
         "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
   end Create_Basic_Repo;

   procedure Read_Attached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
  (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Create_Basic_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
      begin
         Assert (Version.Refs.Is_Attached (Head), "HEAD should be attached");
         Assert (Version.Refs.Branch_Name (Head) = "main",
                 "HEAD branch name should be main");
         Assert (Version.Refs.Current_Commit_Id (Repo) =
                   "0123456789012345678901234567890123456789",
                 "current commit id was not read from branch ref");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Attached_HEAD;

   procedure Read_Head_Rejects_Invalid_Attached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Head    : constant String := Version.Test_Support.Join (Root, ".git/HEAD");

      procedure Assert_Read_Head_Raises
        (Content : String; Message : String)
      is
         Raised : Boolean := False;
      begin
         Version.Test_Support.Write_Text_File (Head, Content);

         begin
            declare
               Ignored : constant Version.Refs.Head_Info :=
                 Version.Refs.Read_Head (Version.Repository.Open);
            begin
               Assert (Version.Refs.Is_Attached (Ignored), "unreachable");
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = "unsupported repository: HEAD does not point to a branch",
                  Message & " diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;

         Assert (Raised, Message);
      end Assert_Read_Head_Raises;
   begin
      Create_Basic_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Assert_Read_Head_Raises
        ("ref: refs/tags/v1",
         "HEAD pointing outside refs/heads must raise Data_Error");
      Assert_Read_Head_Raises
        ("ref: refs/heads/bad..name",
         "HEAD pointing to invalid branch ref must raise Data_Error");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Head_Rejects_Invalid_Attached_HEAD;

   procedure Read_Head_Rejects_Invalid_Detached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Head    : constant String := Version.Test_Support.Join (Root, ".git/HEAD");
      Raised  : Boolean := False;
   begin
      Create_Basic_Repo (Root);
      Version.Test_Support.Write_Text_File (Head, "not-a-commit-id");
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Ignored : constant Version.Refs.Head_Info :=
              Version.Refs.Read_Head (Version.Repository.Open);
         begin
            Assert (Version.Refs.Is_Detached (Ignored), "unreachable");
         end;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E) = "invalid HEAD value",
               "invalid detached HEAD diagnostic changed: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "invalid detached HEAD must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Head_Rejects_Invalid_Detached_HEAD;

   procedure List_Branches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
  (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Create_Basic_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo     : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Branches : constant Version.Refs.Branch_Name_Vectors.Vector :=
           Version.Refs.List_Branches (Repo);
      begin
         Assert (Natural (Branches.Length) = 2, "expected exactly two branches");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Branches;

   procedure List_Branches_Omits_Malformed_Loose_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Broken_Ref : constant String :=
        Version.Test_Support.Join (Dot_Git, "refs/heads/broken");

      function Contains
        (Branches : Version.Refs.Branch_Name_Vectors.Vector;
         Name     : String)
         return Boolean
      is
      begin
         if Branches.Is_Empty then
            return False;
         end if;

         for I in Branches.First_Index .. Branches.Last_Index loop
            if To_String (Branches.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains;
   begin
      Create_Basic_Repo (Root);
      Version.Test_Support.Write_Text_File (Broken_Ref, "not-an-object-id");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Branches : constant Version.Refs.Branch_Name_Vectors.Vector :=
           Version.Refs.List_Branches (Repo);
      begin
         Assert (Contains (Branches, "main"), "valid branch main should be listed");
         Assert
           (Contains (Branches, "feature"),
            "valid branch feature should be listed");
         Assert
           (not Contains (Branches, "broken"),
            "malformed loose branch ref must not be listed");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Version.Test_Support.Read_Text_File (Broken_Ref) = "not-an-object-id",
         "branch listing must not rewrite malformed loose refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Branches_Omits_Malformed_Loose_Refs;

   procedure Current_Commit_From_Packed_Refs
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Root    : constant String := Version.Test_Support.Fresh_Temp_Dir ("packed_refs_current");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Refs    : constant String := Version.Test_Support.Join (Dot_Git, "refs");
      Heads   : constant String := Version.Test_Support.Join (Refs, "heads");

      Commit : constant String :=
      "0123456789012345678901234567890123456789";
   begin
      Version.Test_Support.Make_Directory (Dot_Git);
      Version.Test_Support.Make_Directory (Refs);
      Version.Test_Support.Make_Directory (Heads);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Dot_Git, "HEAD"),
         "ref: refs/heads/main");

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Dot_Git, "packed-refs"),
         "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10)
         & Commit & " refs/heads/main" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
         Version.Repository.Open;
      begin
         Assert
         (Version.Refs.Current_Commit_Id (Repo) = Commit,
            "current commit id should be read from packed-refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Current_Commit_From_Packed_Refs;

   procedure List_Branches_From_Packed_Refs
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Root    : constant String := Version.Test_Support.Fresh_Temp_Dir ("packed_refs_list");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Refs    : constant String := Version.Test_Support.Join (Dot_Git, "refs");
      Heads   : constant String := Version.Test_Support.Join (Refs, "heads");

      Commit : constant String :=
      "0123456789012345678901234567890123456789";

      function Contains
      (Branches : Version.Refs.Branch_Name_Vectors.Vector;
         Name     : String)
         return Boolean
      is
      begin
         if Branches.Is_Empty then
            return False;
         end if;

         for I in Branches.First_Index .. Branches.Last_Index loop
            if To_String (Branches.Element (I)) = Name then
               return True;
            end if;
         end loop;

         return False;
      end Contains;

   begin
      Version.Test_Support.Make_Directory (Dot_Git);
      Version.Test_Support.Make_Directory (Refs);
      Version.Test_Support.Make_Directory (Heads);

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Dot_Git, "HEAD"),
         "ref: refs/heads/main");

      Version.Test_Support.Write_Text_File
      (Version.Test_Support.Join (Dot_Git, "packed-refs"),
         "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10)
         & Commit & " refs/heads/main" & Character'Val (10)
         & Commit & " refs/heads/feature" & Character'Val (10)
         & Commit & " refs/tags/v1" & Character'Val (10)
         & "^aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
         Version.Repository.Open;

         Branches : constant Version.Refs.Branch_Name_Vectors.Vector :=
         Version.Refs.List_Branches (Repo);
      begin
         Assert
         (Contains (Branches, "main"),
            "packed branch list should contain main");

         Assert
         (Contains (Branches, "feature"),
            "packed branch list should contain feature");

         Assert
         (not Contains (Branches, "v1"),
            "packed branch list must not include tags");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end List_Branches_From_Packed_Refs;

   procedure Ref_Cache_Loads_Packed_Refs_Once
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Root    : constant String :=
        Version.Test_Support.Fresh_Temp_Dir ("ref_cache_packed_refs");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Refs    : constant String := Version.Test_Support.Join (Dot_Git, "refs");
      Heads   : constant String := Version.Test_Support.Join (Refs, "heads");

      Main_Id : constant String :=
        "0123456789012345678901234567890123456789";
      Tag_Id  : constant String :=
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      New_Id  : constant String :=
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
   begin
      Version.Test_Support.Make_Directory (Dot_Git);
      Version.Test_Support.Make_Directory (Refs);
      Version.Test_Support.Make_Directory (Heads);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Dot_Git, "HEAD"),
         "ref: refs/heads/main");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Dot_Git, "packed-refs"),
         "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10)
         & Main_Id & " refs/heads/main" & Character'Val (10)
         & Tag_Id & " refs/tags/v1" & Character'Val (10));

      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cache : Version.Ref_Cache.Ref_Cache;
         Id    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         Assert
           (Version.Ref_Cache.Try_Resolve_Ref
              (Repo, Cache, "refs/heads/main", Id),
            "packed branch should resolve through ref cache");
         Assert (To_String (Id) = Main_Id, "unexpected packed branch id");
         Assert
           (Version.Ref_Cache.Packed_Refs_Loaded (Cache),
            "packed refs should be loaded after packed lookup");
         Assert
           (Version.Ref_Cache.Cached_Packed_Ref_Count (Cache) = 2,
            "packed refs should be loaded once into the command-local cache");

         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Dot_Git, "packed-refs"),
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10)
            & New_Id & " refs/heads/new" & Character'Val (10));

         Assert
           (not Version.Ref_Cache.Try_Resolve_Ref
              (Repo, Cache, "refs/heads/new", Id),
            "already-loaded ref cache must not reread packed-refs implicitly");

         Version.Ref_Cache.Clear (Cache);

         Assert
           (Version.Ref_Cache.Try_Resolve_Ref
              (Repo, Cache, "refs/heads/new", Id),
            "clear should make ref cache reload current packed-refs");
         Assert (To_String (Id) = New_Id, "unexpected reloaded packed branch id");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ref_Cache_Loads_Packed_Refs_Once;

   procedure Ref_Cache_Malformed_Loose_Ref_Does_Not_Poison_Cache
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Main_Ref : constant String :=
        Version.Test_Support.Join (Dot_Git, "refs/heads/main");
      Main_Id : constant String :=
        "0123456789012345678901234567890123456789";
      Raised : Boolean := False;
   begin
      Create_Basic_Repo (Root);
      Version.Test_Support.Write_Text_File (Main_Ref, "not-an-object-id");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cache : Version.Ref_Cache.Ref_Cache;
         Id    : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      begin
         begin
            if Version.Ref_Cache.Try_Resolve_Ref
              (Repo, Cache, "refs/heads/main", Id)
            then
               Assert (False, "malformed loose ref must not resolve");
            end if;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = "invalid ref object id: refs/heads/main",
                  "malformed loose ref cache diagnostic changed: "
                  & Ada.Exceptions.Exception_Message (E));
         end;

         Assert
           (Raised,
            "malformed loose ref cache lookup must raise Data_Error");
         Assert
           (Version.Ref_Cache.Cached_Ref_Count (Cache) = 0,
            "malformed loose ref must not be cached");
         Assert
           (not Version.Ref_Cache.Packed_Refs_Loaded (Cache),
            "malformed loose ref must fail before loading packed refs");

         Version.Test_Support.Write_Text_File (Main_Ref, Main_Id);

         Assert
           (Version.Ref_Cache.Try_Resolve_Ref
              (Repo, Cache, "refs/heads/main", Id),
            "repaired loose ref must resolve with the same cache");
         Assert (To_String (Id) = Main_Id, "unexpected repaired loose ref id");
         Assert
           (Version.Ref_Cache.Cached_Ref_Count (Cache) = 1,
            "repaired loose ref should be cached after successful lookup");

         Version.Test_Support.Write_Text_File (Main_Ref, "not-an-object-id");

         Assert
           (Version.Ref_Cache.Resolve_Ref (Repo, Cache, "refs/heads/main")
            = Version.Objects.To_Object_Id (Main_Id),
            "cached successful ref should remain stable within the cache");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ref_Cache_Malformed_Loose_Ref_Does_Not_Poison_Cache;

   procedure Ref_Cache_Current_Commit_Id_Caches_Attached_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Main_Ref : constant String :=
        Version.Test_Support.Join (Dot_Git, "refs/heads/main");
      First_Id : constant String :=
        "0123456789012345678901234567890123456789";
      Second_Id : constant String :=
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
   begin
      Create_Basic_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cache : Version.Ref_Cache.Ref_Cache;
      begin
         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = First_Id,
            "attached current commit should read the branch tip");

         Version.Test_Support.Write_Text_File (Main_Ref, Second_Id);

         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = First_Id,
            "attached current commit should remain cached");

         Version.Ref_Cache.Clear (Cache);

         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = Second_Id,
            "clearing the ref cache should reload the changed branch tip");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ref_Cache_Current_Commit_Id_Caches_Attached_Branch;

   procedure Ref_Cache_Current_Commit_Id_Caches_Detached_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Head_Path : constant String :=
        Version.Test_Support.Join (Root, ".git/HEAD");
      First_Id : constant String :=
        "1111111111111111111111111111111111111111";
      Second_Id : constant String :=
        "2222222222222222222222222222222222222222";
   begin
      Create_Basic_Repo (Root);
      Version.Test_Support.Write_Text_File (Head_Path, First_Id);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Cache : Version.Ref_Cache.Ref_Cache;
      begin
         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = First_Id,
            "detached current commit should read HEAD");

         Version.Test_Support.Write_Text_File (Head_Path, Second_Id);

         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = First_Id,
            "detached current commit should remain cached");

         Version.Ref_Cache.Clear (Cache);

         Assert
           (Version.Ref_Cache.Current_Commit_Id (Repo, Cache) = Second_Id,
            "clearing the ref cache should reload detached HEAD");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ref_Cache_Current_Commit_Id_Caches_Detached_HEAD;

   procedure Ref_Exists_Rejects_Malformed_Loose_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Main_Ref : constant String :=
        Version.Test_Support.Join (Dot_Git, "refs/heads/main");
      Main_Id : constant String :=
        "0123456789012345678901234567890123456789";
      Raised : Boolean := False;
   begin
      Create_Basic_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Refs.Ref_Exists (Repo, "refs/heads/main"),
            "valid loose ref should exist");

         Version.Test_Support.Write_Text_File (Main_Ref, "not-an-object-id");

         Assert
           (not Version.Refs.Ref_Exists (Repo, "refs/heads/main"),
            "malformed loose ref must not be reported as existing");

         begin
            declare
               Ignored : constant Version.Objects.Hex_Object_Id :=
                 Version.Refs.Resolve_Ref (Repo, "refs/heads/main");
            begin
               Assert
                 (To_String (Ignored) = Main_Id,
                  "malformed loose ref must not resolve");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed loose ref resolve must raise Data_Error");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) = "not-an-object-id",
         "existence checks must not rewrite malformed loose refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Ref_Exists_Rejects_Malformed_Loose_Ref;

   procedure Detached_HEAD_Expected_Old_Mismatch_Preserves_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root
        (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Dot_Git : constant String := Version.Test_Support.Join (Root, ".git");
      Head    : constant String := Version.Test_Support.Join (Dot_Git, "HEAD");
      Old_Id  : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("1111111111111111111111111111111111111111");
      Actual_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("2222222222222222222222222222222222222222");
      New_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("3333333333333333333333333333333333333333");
      Raised : Boolean := False;
   begin
      Create_Basic_Repo (Root);
      Version.Test_Support.Write_Text_File (Head, To_String (Actual_Id));
      Ada.Directories.Set_Directory (Root);

      begin
         Version.Refs.Write_Detached_HEAD
           (Repo         => Version.Repository.Open,
            Commit_Id    => New_Id,
            Expected_Old => Old_Id);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "expected old HEAD mismatch",
               "stale detached HEAD diagnostic changed: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale detached HEAD update must be rejected");
      Assert
        (Version.Test_Support.Read_Text_File (Head) = To_String (Actual_Id),
         "stale detached HEAD update must preserve HEAD");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Detached_HEAD_Expected_Old_Mismatch_Preserves_HEAD;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine (T, Read_Attached_HEAD'Access,
                        "Read attached HEAD and current commit");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Read_Head_Rejects_Invalid_Attached_HEAD'Access,
            "Read HEAD rejects invalid attached refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Read_Head_Rejects_Invalid_Detached_HEAD'Access,
            "Read HEAD rejects invalid detached commit");
      AUnit.Test_Cases.Registration.Register_Routine (T, List_Branches'Access,
                        "List loose branch refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            List_Branches_Omits_Malformed_Loose_Refs'Access,
            "List branches omits malformed loose refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Current_Commit_From_Packed_Refs'Access,
            "Read current commit from packed-refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            List_Branches_From_Packed_Refs'Access,
            "List branches from packed-refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Ref_Cache_Loads_Packed_Refs_Once'Access,
            "Ref cache loads packed refs once");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Ref_Cache_Malformed_Loose_Ref_Does_Not_Poison_Cache'Access,
            "Ref cache rejects malformed loose refs without poisoning cache");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Ref_Cache_Current_Commit_Id_Caches_Attached_Branch'Access,
            "Ref cache current commit caches attached branch tip");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Ref_Cache_Current_Commit_Id_Caches_Detached_HEAD'Access,
            "Ref cache current commit caches detached HEAD");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Ref_Exists_Rejects_Malformed_Loose_Ref'Access,
            "Ref exists rejects malformed loose refs");
      AUnit.Test_Cases.Registration.Register_Routine
         (T,
            Detached_HEAD_Expected_Old_Mismatch_Preserves_HEAD'Access,
            "Detached HEAD expected-old mismatch preserves HEAD");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Refs");
   end Name;

end Version.Refs.Tests;
