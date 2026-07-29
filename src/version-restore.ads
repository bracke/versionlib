with Version.Repository;
with Version.Objects;
with Version.Pathspec;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Path_Safety;

package Version.Restore is

   procedure Restore_Working_Tree
     (Repo : Version.Repository.Repository_Handle);

   procedure Restore_Working_Tree_For_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id);
   --  Update the working tree to match Tree_Id directly (git's `read-tree -u`
   --  target): write every blob the tree holds and delete the working copy of
   --  any path the current index tracks that the tree no longer contains.
   --  Call it before rewriting the index so the outgoing index still names the
   --  paths to remove.

   procedure Preflight_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Preflight_Working_Tree_For_Commit
     (Repo           : Version.Repository.Repository_Handle;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Sparse_Enabled : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector);

   procedure Restore_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Keep      : Version.Path_Safety.Path_Vector :=
        Version.Path_Safety.Path_Vectors.Empty_Vector);

   procedure Restore_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache;
      Keep      : Version.Path_Safety.Path_Vector :=
        Version.Path_Safety.Path_Vectors.Empty_Vector);
   --  Keep names working files to leave exactly as they are. A branch switch
   --  uses it for paths the target commit stores identically to the one being
   --  left: git carries a local edit to such a path across the switch, and
   --  rewriting it from the object store would silently discard the edit.

   procedure Write_Index_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Write_Index_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache);

   procedure Restore_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String);

   procedure Restore_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache);

   procedure Restore_Path_From_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Path    : String);

   procedure Restore_Path_From_Index
     (Repo : Version.Repository.Repository_Handle;
      Path : String);

   procedure Restore_Index_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String);

   procedure Restore_Index_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache);

   procedure Restore_Index_Path_From_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Path    : String);

   procedure Restore_Current_Commit;

   procedure Restore_Path
     (Path : String);

   procedure Restore_Staged_Path
     (Path : String);

   procedure Restore_Staged_Path_From_Source
     (Source : String;
      Path   : String);

   procedure Restore_Path_From_Source
     (Source : String;
      Path   : String);

   --  Set git skip-worktree bits on the index to reflect the current
   --  sparse-checkout pattern set (every stage-0 tracked path that is not
   --  sparse-included is marked), and rewrite the index (as version 3 when any
   --  bit is set). No-op when sparse checkout is disabled or nothing changes.
   procedure Apply_Sparse_Skip_Worktree
     (Repo : Version.Repository.Repository_Handle);

   procedure Apply_Sparse_Update
     (Repo : Version.Repository.Repository_Handle);
   --  Bring the working tree into line with the current sparse patterns the way
   --  git's sparse-checkout does, WITHOUT the full-tree rewrite Restore does:
   --  materialise a now-included path only when it is absent, remove a
   --  now-excluded path only when its working copy still matches the index
   --  (a locally-modified excluded file is left in place, as git leaves it),
   --  and set each entry's skip-worktree bit to match. Unlike a plain
   --  Restore_Working_Tree this never clobbers a dirty file, so a
   --  sparse-checkout set/init needs no clean working tree.

   --  Clear every skip-worktree bit from the index (used by `sparse disable`).
   procedure Clear_Skip_Worktree
     (Repo : Version.Repository.Repository_Handle);

end Version.Restore;
