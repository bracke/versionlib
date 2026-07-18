with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Cherry_Pick_State;
with Version.Files;
with Version.Git_Fixtures;
with Version.Merge_State;
with Version.Objects;
with Version.Reachability;
with Version.Refs;
with Version.Repository;
with Version.Reflog;
with Version.Revert_State;
with Version.Test_Support;
with Version.Worktrees;
with Version.Write;

package body Version.Maintenance.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   --  True when the object can still be read, whether it is loose or has
   --  been packed away by gc.
   function Object_Readable
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Boolean
   is
      Obj : Version.Objects.Git_Object;
      pragma Unreferenced (Obj);
   begin
      Obj := Version.Objects.Read_Object (Repo, Id);
      return True;
   exception
      when others =>
         return False;
   end Object_Readable;

   function Object_File_Path
     (Root : String;
      Id   : Version.Objects.Hex_Object_Id)
      return String
   is
   begin
      return Join (Join (Join (Root, ".git"), "objects"), To_String (Id) (1 .. 2))
        & "/" & To_String (Id) (3 .. 40);
   end Object_File_Path;

   function Contains
     (Items : Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   procedure With_Root_Directory
     (Root : String;
      Proc : not null access procedure)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Ada.Directories.Set_Directory (Root);
      Proc.all;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end With_Root_Directory;

   procedure Verify_Clean_Repository
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo   : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Result : constant Version.Maintenance.Maintenance_Result :=
           Version.Maintenance.Verify (Repo);
      begin
         Assert (Result.Object_Count >= 3,
                 "verify should traverse at least commit, tree, and blob");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Verify_Clean_Repository;

   procedure Verify_Detects_Missing_Reachable_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Raised : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      declare
         Old_Dir : constant String := Ada.Directories.Current_Directory;
         Head_Id : Version.Objects.Object_Id_Storage;
      begin
         Ada.Directories.Set_Directory (Root);
         declare
            Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         begin
            Head_Id := Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         end;
         Ada.Directories.Set_Directory (Old_Dir);

         Ada.Directories.Delete_File (Object_File_Path (Root, Head_Id));
      exception
         when others =>
            if Ada.Directories.Current_Directory /= Old_Dir then
               Ada.Directories.Set_Directory (Old_Dir);
            end if;
            raise;
      end;

      declare
         procedure Exercise is
            Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
            Result : Version.Maintenance.Maintenance_Result;
         begin
            Result := Version.Maintenance.Verify (Repo);
            pragma Unreferenced (Result);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end Exercise;
      begin
         With_Root_Directory (Root, Exercise'Access);
      end;

      Assert (Raised, "verify must reject a missing reachable object");
   end Verify_Detects_Missing_Reachable_Object;

   procedure Reachability_Includes_HEAD
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Roots     : constant Version.Objects.Object_Id_Vectors.Vector :=
           Version.Reachability.Repository_Roots (Repo);
         Reachable : constant Version.Objects.Object_Id_Vectors.Vector :=
           Version.Reachability.Reachable_From (Repo, Roots);
         Found     : Boolean := False;
      begin
         if not Reachable.Is_Empty then
            for I in Reachable.First_Index .. Reachable.Last_Index loop
               if Reachable.Element (I) = Head_Id then
                  Found := True;
               end if;
            end loop;
         end if;

         Assert (Found, "reachable traversal must include HEAD commit");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Reachability_Includes_HEAD;

   procedure Reachability_Deduplicates_Duplicate_Roots
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Roots     : Version.Objects.Object_Id_Vectors.Vector;
         Reachable : Version.Objects.Object_Id_Vectors.Vector;
         Count     : Natural := 0;
      begin
         Roots.Append (Head_Id);
         Roots.Append (Head_Id);
         Roots.Append (Head_Id);

         Reachable := Version.Reachability.Reachable_From (Repo, Roots);

         if not Reachable.Is_Empty then
            for I in Reachable.First_Index .. Reachable.Last_Index loop
               if Reachable.Element (I) = Head_Id then
                  Count := Count + 1;
               end if;
            end loop;
         end if;

         Assert (Count = 1,
                 "reachable traversal should process duplicate roots once");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Reachability_Deduplicates_Duplicate_Roots;

   procedure Reachability_Includes_Branch_Tag_Remote_And_Packed_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo     : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Roots    : Version.Objects.Object_Id_Vectors.Vector;
         Remote_Dir : constant String := Join (Join (Version.Repository.Git_Dir (Repo), "refs/remotes"), "origin");
      begin
         Version.Git_Fixtures.Run (Root, "git branch topic");
         Version.Git_Fixtures.Run (Root, "git tag v1");

         if not Ada.Directories.Exists (Remote_Dir) then
            Ada.Directories.Create_Path (Remote_Dir);
         end if;
         Version.Test_Support.Write_Text_File
           (Join (Remote_Dir, "main"), To_String (Head_Id) & Character'Val (10));

         Roots := Version.Reachability.Repository_Roots (Repo);
         Assert (Contains (Roots, Head_Id),
                 "roots should include loose branch/tag/remote refs");

         Version.Git_Fixtures.Run (Root, "git pack-refs --all");
         Roots := Version.Reachability.Repository_Roots (Repo);
         Assert (Contains (Roots, Head_Id),
                 "roots should include packed refs after git pack-refs --all");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Reachability_Includes_Branch_Tag_Remote_And_Packed_Refs;

   procedure Reachability_Protects_Reflog_Old_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         First_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Roots     : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Version.Test_Support.Write_Text_File
           (Join (Root, "a.txt"), "second" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add a.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m second");

         Roots := Version.Reachability.Repository_Roots (Repo);
         Assert (Contains (Roots, First_Id),
                 "repository roots should protect old reflog commit ids");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Reachability_Protects_Reflog_Old_Commit;

   procedure Prune_Dry_Run_Reports_Unreachable_Loose_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Blob_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "unreachable blob");
         Result    : constant Version.Maintenance.Maintenance_Result :=
           Version.Maintenance.Prune (Repo, Dry_Run => True, Now => False);
         Blob_Path : constant String := Object_File_Path (Root, Blob_Id);
      begin
         Assert (Result.Unreachable_Count >= 1,
                 "prune dry-run should report an unreachable loose object");
         Assert (Ada.Directories.Exists (Blob_Path),
                 "prune dry-run must not delete unreachable loose objects");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Prune_Dry_Run_Reports_Unreachable_Loose_Object;

   procedure Prune_Now_Deletes_Unreachable_Loose_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Blob_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "delete-me");
         Blob_Path : constant String := Object_File_Path (Root, Blob_Id);
         Result    : Version.Maintenance.Maintenance_Result;
      begin
         Assert (Ada.Directories.Exists (Blob_Path),
                 "test-created unreachable blob should exist before prune");

         Result := Version.Maintenance.Prune (Repo, Dry_Run => False, Now => True);

         Assert (Result.Deleted_Count >= 1,
                 "prune --now should delete unreachable loose objects");
         Assert (not Ada.Directories.Exists (Blob_Path),
                 "unreachable loose object should be deleted by prune --now");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Prune_Now_Deletes_Unreachable_Loose_Object;

   procedure Prune_Does_Not_Delete_Reachable_Object
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Head_Path : constant String := Object_File_Path (Root, Head_Id);
         Result    : Version.Maintenance.Maintenance_Result;
      begin
         Result := Version.Maintenance.Prune (Repo, Dry_Run => False, Now => True);
         pragma Unreferenced (Result);

         Assert (Ada.Directories.Exists (Head_Path),
                 "prune --now must not delete reachable loose commit objects");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Prune_Does_Not_Delete_Reachable_Object;

   procedure Prune_Refuses_During_Merge_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Raised : Boolean := False;

      procedure Exercise is
         Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      begin
         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Head_Id,
            Target_Id     => Head_Id,
            Target_Branch => "other");

         begin
            declare
               Ignored : constant Version.Maintenance.Maintenance_Result :=
                 Version.Maintenance.Prune (Repo, Dry_Run => False, Now => True);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
      Assert (Raised, "destructive prune must refuse to run during merge state");
   end Prune_Refuses_During_Merge_State;

   function Commit_Tree_Object
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Git_Object
   is
   begin
      return Version.Objects.Read_Object
        (Repo, Version.Objects.Commit_Tree_Id
          (Version.Objects.Read_Object (Repo, Commit_Id)));
   end Commit_Tree_Object;

   procedure GC_Preserves_Annotated_Tag_Target
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Result : Version.Maintenance.Maintenance_Result;
         Tag_Id : Version.Objects.Object_Id_Storage;
         Target_Id : Version.Objects.Object_Id_Storage;
      begin
         Version.Test_Support.Write_Text_File
           (Join (Root, "tagged.txt"), "tagged" & Character'Val (10));
         Version.Git_Fixtures.Run (Root, "git add tagged.txt");
         Version.Git_Fixtures.Run (Root, "git commit -m tagged");
         Version.Git_Fixtures.Run
           (Root, "git tag -a keep-tag -m keep-tag");
         Version.Git_Fixtures.Run
           (Root, "git rev-parse keep-tag > tag-id.txt");
         Version.Git_Fixtures.Run
           (Root, "git rev-parse keep-tag^{} > tag-target.txt");
         Tag_Id := Version.Objects.To_Object_Id
           (Version.Test_Support.Read_Text_File (Join (Root, "tag-id.txt")));
         Target_Id := Version.Objects.To_Object_Id
           (Version.Test_Support.Read_Text_File (Join (Root, "tag-target.txt")));

         Version.Git_Fixtures.Run (Root, "git reset --hard HEAD~1");
         Version.Git_Fixtures.Run
           (Root, "git reflog expire --expire=now --all");

         Result := Version.Maintenance.GC (Repo, Dry_Run => False);
         pragma Unreferenced (Result);

         Assert
           (Version.Objects.Kind (Version.Objects.Read_Object (Repo, Tag_Id))
            = Version.Objects.Tag_Object,
            "gc must preserve annotated tag object reachable only from tag ref");
         Assert
           (Version.Objects.Kind (Version.Objects.Read_Object (Repo, Target_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve annotated tag peeled target");
         Assert
           (Version.Objects.Kind (Commit_Tree_Object (Repo, Target_Id))
            = Version.Objects.Tree_Object,
            "gc must preserve annotated tag target tree");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Annotated_Tag_Target;

   function State_Only_Commit
     (Root : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      Version.Git_Fixtures.Run
        (Root, "git commit-tree HEAD^{tree} -p HEAD -m pending > pending-id.txt");
      return Version.Objects.To_Object_Id
        (Version.Test_Support.Read_Text_File (Join (Root, "pending-id.txt")));
   end State_Only_Commit;

   procedure GC_Preserves_Cherry_Pick_State_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Commits : Version.Cherry_Pick_State.Commit_Vectors.Vector;
         Result : Version.Maintenance.Maintenance_Result;
      begin
         Commits.Append (Pending_Id);
         Version.Cherry_Pick_State.Write_State
           (Repo          => Repo,
            Kind          => Version.Cherry_Pick_State.Symbolic_Head,
            Head_Ref      => "refs/heads/main",
            Original_Head => Head_Id,
            Current_Head  => Head_Id,
            Next_Index    => 0,
            Commits       => Commits);

         Assert
           (Contains (Version.Reachability.Repository_Roots (Repo), Pending_Id),
            "cherry-pick state commit should be a repository root");
         Result := Version.Maintenance.GC (Repo, Dry_Run => False);
         pragma Unreferenced (Result);
         Assert
           (Version.Objects.Kind (Version.Objects.Read_Object (Repo, Pending_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve commit reachable only from cherry-pick state");
         Assert
           (Version.Objects.Kind (Commit_Tree_Object (Repo, Pending_Id))
            = Version.Objects.Tree_Object,
            "gc must preserve cherry-pick state commit tree");
         Version.Cherry_Pick_State.Clear_State (Repo);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Cherry_Pick_State_Commit;

   procedure GC_Preserves_Revert_State_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Commits : Version.Revert_State.Commit_Vectors.Vector;
         Result : Version.Maintenance.Maintenance_Result;
      begin
         Commits.Append (Pending_Id);
         Version.Revert_State.Write_State
           (Repo          => Repo,
            Kind          => Version.Revert_State.Symbolic_Head,
            Head_Ref      => "refs/heads/main",
            Original_Head => Head_Id,
            Current_Head  => Head_Id,
            Next_Index    => 0,
            Commits       => Commits);

         Assert
           (Contains (Version.Reachability.Repository_Roots (Repo), Pending_Id),
            "revert state commit should be a repository root");
         Result := Version.Maintenance.GC (Repo, Dry_Run => False);
         pragma Unreferenced (Result);
         Assert
           (Version.Objects.Kind (Version.Objects.Read_Object (Repo, Pending_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve commit reachable only from revert state");
         Assert
           (Version.Objects.Kind (Commit_Tree_Object (Repo, Pending_Id))
            = Version.Objects.Tree_Object,
            "gc must preserve revert state commit tree");
         Version.Revert_State.Clear_State (Repo);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Revert_State_Commit;

   procedure Prepare_Linked_Worktree
     (Root : String;
      Work : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Version.Worktrees.Add (Path => Work, Branch => "feature");
   end Prepare_Linked_Worktree;

   procedure Reflog_Roots_Include_Linked_HEAD_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Primary_Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Roots : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Prepare_Linked_Worktree (Root, Work);

         declare
            Linked_Git_Dir : constant String :=
              Version.Repository.Resolve_Git_Dir (Work);
            Log_Path : constant String :=
              Join (Join (Linked_Git_Dir, "logs"), "HEAD");
         begin
            Version.Files.Create_Parent_Directories (Log_Path);
            Version.Test_Support.Write_Text_File
              (Log_Path,
               To_String (Head_Id) & " " & To_String (Pending_Id)
               & " Test <test@example.com> 0 +0000"
               & Character'Val (9)
               & "checkout: linked reflog root" & Character'Val (10));
         end;

         Roots := Version.Reachability.Reflog_Roots (Primary_Repo);
         Assert
           (Contains (Roots, Pending_Id),
            "reflog roots should include linked worktree HEAD reflog ids");
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Reflog_Roots_Include_Linked_HEAD_Reflog;

   procedure GC_Preserves_Linked_Cherry_Pick_State_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Primary_Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Commits : Version.Cherry_Pick_State.Commit_Vectors.Vector;
         Result : Version.Maintenance.Maintenance_Result;

         procedure Write_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Cherry_Pick_State.Write_State
              (Repo          => Linked_Repo,
               Kind          => Version.Cherry_Pick_State.Symbolic_Head,
               Head_Ref      => "refs/heads/feature",
               Original_Head => Head_Id,
               Current_Head  => Head_Id,
               Next_Index    => 0,
               Commits       => Commits);
         end Write_Linked_State;

         procedure Clear_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Cherry_Pick_State.Clear_State (Linked_Repo);
         end Clear_Linked_State;
      begin
         Prepare_Linked_Worktree (Root, Work);
         Commits.Append (Pending_Id);
         Version.Files.With_Directory (Work, Write_Linked_State'Access);

         Assert
           (Contains (Version.Reachability.Repository_Roots (Primary_Repo), Pending_Id),
            "linked cherry-pick state commit should be a primary repository root");
         Result := Version.Maintenance.GC (Primary_Repo, Dry_Run => False);
         pragma Unreferenced (Result);
         Assert
           (Version.Objects.Kind
              (Version.Objects.Read_Object (Primary_Repo, Pending_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve commit reachable only from linked cherry-pick state");
         Version.Files.With_Directory (Work, Clear_Linked_State'Access);
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Linked_Cherry_Pick_State_Commit;

   procedure GC_Preserves_Linked_Revert_State_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Primary_Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Commits : Version.Revert_State.Commit_Vectors.Vector;
         Result : Version.Maintenance.Maintenance_Result;

         procedure Write_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Revert_State.Write_State
              (Repo          => Linked_Repo,
               Kind          => Version.Revert_State.Symbolic_Head,
               Head_Ref      => "refs/heads/feature",
               Original_Head => Head_Id,
               Current_Head  => Head_Id,
               Next_Index    => 0,
               Commits       => Commits);
         end Write_Linked_State;

         procedure Clear_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Revert_State.Clear_State (Linked_Repo);
         end Clear_Linked_State;
      begin
         Prepare_Linked_Worktree (Root, Work);
         Commits.Append (Pending_Id);
         Version.Files.With_Directory (Work, Write_Linked_State'Access);

         Assert
           (Contains (Version.Reachability.Repository_Roots (Primary_Repo), Pending_Id),
            "linked revert state commit should be a primary repository root");
         Result := Version.Maintenance.GC (Primary_Repo, Dry_Run => False);
         pragma Unreferenced (Result);
         Assert
           (Version.Objects.Kind
              (Version.Objects.Read_Object (Primary_Repo, Pending_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve commit reachable only from linked revert state");
         Version.Files.With_Directory (Work, Clear_Linked_State'Access);
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Linked_Revert_State_Commit;

   procedure GC_Preserves_Linked_Merge_State_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Primary_Repo));
         Target_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Result : Version.Maintenance.Maintenance_Result;

         procedure Write_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Merge_State.Write_State
              (Repo          => Linked_Repo,
               Current_Id    => Head_Id,
               Target_Id     => Target_Id,
               Target_Branch => "linked-merge");
         end Write_Linked_State;

         procedure Clear_Linked_State is
            Linked_Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Merge_State.Clear_State (Linked_Repo);
         end Clear_Linked_State;
      begin
         Prepare_Linked_Worktree (Root, Work);
         Version.Files.With_Directory (Work, Write_Linked_State'Access);

         Assert
           (Contains (Version.Reachability.Repository_Roots (Primary_Repo), Target_Id),
            "linked merge state target should be a primary repository root");
         Result := Version.Maintenance.GC (Primary_Repo, Dry_Run => False);
         pragma Unreferenced (Result);
         Assert
           (Version.Objects.Kind
              (Version.Objects.Read_Object (Primary_Repo, Target_Id))
            = Version.Objects.Commit_Object,
            "gc must preserve commit reachable only from linked merge state");
         Version.Files.With_Directory (Work, Clear_Linked_State'Access);
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Preserves_Linked_Merge_State_Commit;

   procedure Prune_Preserves_Linked_HEAD_Reflog_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Primary_Repo));
         Pending_Id : constant Version.Objects.Hex_Object_Id :=
           State_Only_Commit (Root);
         Result : Version.Maintenance.Maintenance_Result;
      begin
         Prepare_Linked_Worktree (Root, Work);

         declare
            Linked_Git_Dir : constant String :=
              Version.Repository.Resolve_Git_Dir (Work);
            Log_Path : constant String :=
              Join (Join (Linked_Git_Dir, "logs"), "HEAD");
         begin
            Version.Files.Create_Parent_Directories (Log_Path);
            Version.Test_Support.Write_Text_File
              (Log_Path,
               To_String (Head_Id) & " " & To_String (Pending_Id)
               & " Test <test@example.com> 0 +0000"
               & Character'Val (9)
               & "checkout: linked reflog root" & Character'Val (10));
         end;

         Assert
           (Contains (Version.Reachability.Repository_Roots (Primary_Repo), Pending_Id),
            "linked HEAD reflog commit should be a repository root");
         Result := Version.Maintenance.Prune
           (Primary_Repo, Dry_Run => False, Now => True);
         pragma Unreferenced (Result);
         Assert
           (Ada.Directories.Exists (Object_File_Path (Root, Pending_Id)),
            "prune must preserve commit reachable only from linked HEAD reflog");
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Prune_Preserves_Linked_HEAD_Reflog_Commit;

   procedure GC_Rejects_Malformed_Linked_HEAD_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";

      procedure Exercise is
         Primary_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         Prepare_Linked_Worktree (Root, Work);

         declare
            Linked_Git_Dir : constant String :=
              Version.Repository.Resolve_Git_Dir (Work);
            Log_Path : constant String :=
              Join (Join (Linked_Git_Dir, "logs"), "HEAD");
            Result : Version.Objects.Object_Id_Vectors.Vector;
         begin
            Version.Files.Create_Parent_Directories (Log_Path);
            Version.Test_Support.Write_Text_File
              (Log_Path, "malformed linked head reflog" & Character'Val (10));

            begin
               Result := Version.Reachability.Repository_Roots (Primary_Repo);
               if Result.Is_Empty then
                  null;
               end if;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
         end;

         Assert (Raised, "malformed linked HEAD reflog must reject gc roots");
         Version.Worktrees.Remove (Work);
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Rejects_Malformed_Linked_HEAD_Reflog;

   procedure Assert_GC_Rejects_Malformed_Nested_Ref
     (T            : in out AUnit.Test_Cases.Test_Case'Class;
      Ref_Name     : String;
      Ref_Path     : String;
      Test_Message : String)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Bad_Ref_Content : constant String := "not-an-object-id" & Character'Val (10);
         Bad_Ref_Path : constant String := Join (Join (Root, ".git"), Ref_Path);
         Object_Path : constant String := Object_File_Path (Root, Head_Id);
         Object_Existed : constant Boolean := Ada.Directories.Exists (Object_Path);
         Raised : Boolean := False;
      begin
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Bad_Ref_Path));
         Version.Test_Support.Write_Text_File (Bad_Ref_Path, Bad_Ref_Content);

         declare
            Bad_Ref_Before : constant String :=
              Version.Files.Read_Binary_File (Bad_Ref_Path);
            Result : Version.Maintenance.Maintenance_Result;
            pragma Unreferenced (Result);
         begin
            begin
               Result := Version.Maintenance.GC (Repo, Dry_Run => False);
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
                  Assert
                    (Ada.Strings.Fixed.Index
                       (Ada.Exceptions.Exception_Message (E), Ref_Name) /= 0,
                     Test_Message & " should report full ref name");
            end;

            Assert (Raised, Test_Message & " should reject malformed ref");
            Assert
              (Version.Files.Read_Binary_File (Bad_Ref_Path) = Bad_Ref_Before,
               Test_Message & " must preserve malformed ref file");
            Assert
              (Ada.Directories.Exists (Object_Path) = Object_Existed,
               Test_Message & " must not mutate existing object storage");
         end;
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Assert_GC_Rejects_Malformed_Nested_Ref;

   procedure GC_Rejects_Malformed_Nested_Loose_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Assert_GC_Rejects_Malformed_Nested_Ref
        (T            => T,
         Ref_Name     => "refs/heads/feature/bad",
         Ref_Path     => "refs/heads/feature/bad",
         Test_Message => "gc malformed nested branch");
   end GC_Rejects_Malformed_Nested_Loose_Branch;

   procedure GC_Rejects_Malformed_Nested_Loose_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Assert_GC_Rejects_Malformed_Nested_Ref
        (T            => T,
         Ref_Name     => "refs/tags/release/bad",
         Ref_Path     => "refs/tags/release/bad",
         Test_Message => "gc malformed nested tag");
   end GC_Rejects_Malformed_Nested_Loose_Tag;

   procedure GC_Rejects_Malformed_Nested_Remote_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Assert_GC_Rejects_Malformed_Nested_Ref
        (T            => T,
         Ref_Name     => "refs/remotes/origin/feature/bad",
         Ref_Path     => "refs/remotes/origin/feature/bad",
         Test_Message => "gc malformed nested remote ref");
   end GC_Rejects_Malformed_Nested_Remote_Ref;

   procedure GC_Ignores_Stale_Loose_Ref_Lockfiles
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Branch_Lock : constant String :=
           Join (Join (Root, ".git"), "refs/heads/stale/topic.lock");
         Tag_Lock : constant String :=
           Join (Join (Root, ".git"), "refs/tags/release/v1.lock");
         Remote_Lock : constant String :=
           Join (Join (Root, ".git"), "refs/remotes/origin/main.lock");
         Lock_Content : constant String := "not-a-ref" & Character'Val (10);
         Object_Path : constant String := Object_File_Path (Root, Head_Id);
         Object_Existed : constant Boolean := Ada.Directories.Exists (Object_Path);
         Result : Version.Maintenance.Maintenance_Result;
         pragma Unreferenced (Result);
      begin
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Branch_Lock));
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Tag_Lock));
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Remote_Lock));
         Version.Test_Support.Write_Text_File (Branch_Lock, Lock_Content);
         Version.Test_Support.Write_Text_File (Tag_Lock, Lock_Content);
         Version.Test_Support.Write_Text_File (Remote_Lock, Lock_Content);

         Result := Version.Maintenance.GC (Repo, Dry_Run => False);

         Assert
           (Ada.Directories.Exists (Branch_Lock),
            "gc should preserve stale branch ref lockfile");
         Assert
           (Ada.Directories.Exists (Tag_Lock),
            "gc should preserve stale tag ref lockfile");
         Assert
           (Ada.Directories.Exists (Remote_Lock),
            "gc should preserve stale remote ref lockfile");
         --  gc packs reachable objects and removes the now-redundant loose
         --  copies, as git's repack -d does, so the loose file is expected to
         --  be gone. What must hold is that the object is still readable.
         Assert
           (Object_Readable (Repo, Head_Id),
            "gc should not mutate reachable object storage around lockfiles");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Ignores_Stale_Loose_Ref_Lockfiles;

   procedure GC_Ignores_Stale_Reflog_Lockfiles
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Head_Log_Lock : constant String :=
           Version.Reflog.Path (Repo, "HEAD") & ".lock";
         Branch_Log_Lock : constant String :=
           Version.Reflog.Path (Repo, "refs/heads/main") & ".lock";
         Remote_Log_Lock : constant String :=
           Version.Reflog.Path (Repo, "refs/remotes/origin/main") & ".lock";
         Lock_Content : constant String := "not-a-reflog" & Character'Val (10);
         Object_Path : constant String := Object_File_Path (Root, Head_Id);
         Object_Existed : constant Boolean := Ada.Directories.Exists (Object_Path);
         Result : Version.Maintenance.Maintenance_Result;
         pragma Unreferenced (Result);
      begin
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Head_Log_Lock));
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Branch_Log_Lock));
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Remote_Log_Lock));
         Version.Test_Support.Write_Text_File (Head_Log_Lock, Lock_Content);
         Version.Test_Support.Write_Text_File (Branch_Log_Lock, Lock_Content);
         Version.Test_Support.Write_Text_File (Remote_Log_Lock, Lock_Content);

         Result := Version.Maintenance.GC (Repo, Dry_Run => False);

         Assert
           (Ada.Directories.Exists (Head_Log_Lock),
            "gc should preserve stale HEAD reflog lockfile");
         Assert
           (Ada.Directories.Exists (Branch_Log_Lock),
            "gc should preserve stale branch reflog lockfile");
         Assert
           (Ada.Directories.Exists (Remote_Log_Lock),
            "gc should preserve stale remote reflog lockfile");
         --  gc packs reachable objects and removes the now-redundant loose
         --  copies, as git's repack -d does, so the loose file is expected to
         --  be gone. What must hold is that the object is still readable.
         Assert
           (Object_Readable (Repo, Head_Id),
            "gc should not mutate reachable object storage around reflog lockfiles");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end GC_Ignores_Stale_Reflog_Lockfiles;

   procedure Repack_Writes_Git_Valid_Pack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo   : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Result : constant Version.Maintenance.Maintenance_Result :=
           Version.Maintenance.Repack (Repo);
      begin
         Assert (Result.Object_Count >= 3,
                 "repack should write reachable commit, tree, and blob objects");
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);

      Assert
        (Ada.Directories.Exists
           (Join (Join (Join (Root, ".git"), "objects"), "pack")
            & "/version-repack.pack"),
         "repack should create a pack file");
      Assert
        (Ada.Directories.Exists
           (Join (Join (Join (Root, ".git"), "objects"), "pack")
            & "/version-repack.idx"),
         "repack should create a pack index");

      Version.Git_Fixtures.Run
        (Root, "git verify-pack -v .git/objects/pack/version-repack.idx >/dev/null");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
   end Repack_Writes_Git_Valid_Pack;

   procedure Repack_Failure_Preserves_Published_Pack_Pair
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Exercise is
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Pack_Dir : constant String :=
           Join (Join (Join (Root, ".git"), "objects"), "pack");
         Pack_Path : constant String := Join (Pack_Dir, "version-repack.pack");
         Idx_Path : constant String := Join (Pack_Dir, "version-repack.idx");
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Head_Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Head_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Head_Obj);
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo, Tree_Id);
         Blob_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
         Other_Blob : Version.Objects.Object_Id_Storage;
         First_Result : Version.Maintenance.Maintenance_Result;
         Second_Result : Version.Maintenance.Maintenance_Result;
         pragma Unreferenced (First_Result, Second_Result);
         Raised : Boolean := False;
      begin
         for Tree_Item of Entries loop
            if Tree_Item.Kind = Version.Objects.Tree_Blob then
               Blob_Id := Tree_Item.Id;
               exit;
            end if;
         end loop;

         Assert
           (Blob_Id /= Version.Objects.Object_Id_Storage'(Version.Objects.Zero_Object_Id),
            "fixture should contain a reachable blob");

         First_Result := Version.Maintenance.Repack (Repo);

         declare
            Pack_Before : constant String := Version.Files.Read_Binary_File (Pack_Path);
            Idx_Before : constant String := Version.Files.Read_Binary_File (Idx_Path);
         begin
            Other_Blob := Version.Write.Write_Blob (Repo, "different blob payload");
            Ada.Directories.Create_Path
              (Ada.Directories.Containing_Directory
                 (Object_File_Path (Root, Blob_Id)));
            Version.Files.Delete_File_If_Exists (Object_File_Path (Root, Blob_Id));
            Version.Files.Write_Binary_File
              (Path    => Object_File_Path (Root, Blob_Id),
               Content => Version.Files.Read_Binary_File
                 (Object_File_Path (Root, Other_Blob)));

            begin
               Second_Result := Version.Maintenance.Repack (Repo);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "corrupt reachable blob should reject repack");
            Assert
              (Version.Files.Read_Binary_File (Pack_Path) = Pack_Before,
               "failed repack must preserve published pack bytes");
            Assert
              (Version.Files.Read_Binary_File (Idx_Path) = Idx_Before,
               "failed repack must preserve published index bytes");
            Assert
              (not Ada.Directories.Exists (Pack_Path & ".lock"),
               "failed repack must remove temporary pack file");
            Assert
              (not Ada.Directories.Exists (Idx_Path & ".lock"),
               "failed repack must remove temporary index file");
         end;
      end Exercise;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      With_Root_Directory (Root, Exercise'Access);
   end Repack_Failure_Preserves_Published_Pack_Pair;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Verify_Clean_Repository'Access,
         "Maintenance: verify clean repository");

      Register_Routine
        (T,
         Verify_Detects_Missing_Reachable_Object'Access,
         "Maintenance: verify detects missing object");

      Register_Routine
        (T,
         Reachability_Includes_HEAD'Access,
         "Maintenance: reachability includes HEAD");

      Register_Routine
        (T,
         Reachability_Deduplicates_Duplicate_Roots'Access,
         "Maintenance: reachability deduplicates duplicate roots");

      Register_Routine
        (T,
         Repack_Writes_Git_Valid_Pack'Access,
         "Maintenance: repack writes Git-valid pack/index");

      Register_Routine
        (T,
         Repack_Failure_Preserves_Published_Pack_Pair'Access,
         "Maintenance: failed repack preserves published pack/index");

      Register_Routine
        (T,
         GC_Preserves_Annotated_Tag_Target'Access,
         "Maintenance: gc preserves annotated tag target");

      Register_Routine
        (T,
         GC_Preserves_Cherry_Pick_State_Commit'Access,
         "Maintenance: gc preserves cherry-pick state commit");

      Register_Routine
        (T,
         GC_Preserves_Revert_State_Commit'Access,
         "Maintenance: gc preserves revert state commit");

      Register_Routine
        (T,
         GC_Preserves_Linked_Cherry_Pick_State_Commit'Access,
         "Maintenance: gc preserves linked cherry-pick state commit");

      Register_Routine
        (T,
         GC_Preserves_Linked_Revert_State_Commit'Access,
         "Maintenance: gc preserves linked revert state commit");

      Register_Routine
        (T,
         GC_Preserves_Linked_Merge_State_Commit'Access,
         "Maintenance: gc preserves linked merge state commit");

      Register_Routine
        (T,
         Prune_Preserves_Linked_HEAD_Reflog_Commit'Access,
         "Maintenance: prune preserves linked HEAD reflog commit");

      Register_Routine
        (T,
         GC_Rejects_Malformed_Linked_HEAD_Reflog'Access,
         "Maintenance: gc rejects malformed linked HEAD reflog");

      Register_Routine
        (T,
         Reachability_Includes_Branch_Tag_Remote_And_Packed_Refs'Access,
         "Maintenance: reachability includes branch tag remote and packed refs");

      Register_Routine
        (T,
         Reachability_Protects_Reflog_Old_Commit'Access,
         "Maintenance: reachability protects reflog old commit");

      Register_Routine
        (T,
         Reflog_Roots_Include_Linked_HEAD_Reflog'Access,
         "Maintenance: reflog roots include linked HEAD reflog");

      Register_Routine
        (T,
         GC_Rejects_Malformed_Nested_Loose_Branch'Access,
         "Maintenance: gc rejects malformed nested loose branch");

      Register_Routine
        (T,
         GC_Rejects_Malformed_Nested_Loose_Tag'Access,
         "Maintenance: gc rejects malformed nested loose tag");

      Register_Routine
        (T,
         GC_Rejects_Malformed_Nested_Remote_Ref'Access,
         "Maintenance: gc rejects malformed nested remote ref");

      Register_Routine
        (T,
         GC_Ignores_Stale_Loose_Ref_Lockfiles'Access,
         "Maintenance: gc ignores stale loose ref lockfiles");

      Register_Routine
        (T,
         GC_Ignores_Stale_Reflog_Lockfiles'Access,
         "Maintenance: gc ignores stale reflog lockfiles");

      Register_Routine
        (T,
         Prune_Dry_Run_Reports_Unreachable_Loose_Object'Access,
         "Maintenance: prune dry-run reports unreachable loose object");

      Register_Routine
        (T,
         Prune_Now_Deletes_Unreachable_Loose_Object'Access,
         "Maintenance: prune --now deletes unreachable loose object");

      Register_Routine
        (T,
         Prune_Does_Not_Delete_Reachable_Object'Access,
         "Maintenance: prune does not delete reachable object");

      Register_Routine
        (T,
         Prune_Refuses_During_Merge_State'Access,
         "Maintenance: prune refuses during merge state");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Maintenance");
   end Name;

end Version.Maintenance.Tests;
