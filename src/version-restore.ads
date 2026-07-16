with Version.Repository;
with Version.Objects;
with Version.Pathspec;
with Version.Object_Cache;
with Version.Tree_Cache;

package Version.Restore is

   procedure Restore_Working_Tree
     (Repo : Version.Repository.Repository_Handle);

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
      Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Restore_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache);

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

   --  Clear every skip-worktree bit from the index (used by `sparse disable`).
   procedure Clear_Skip_Worktree
     (Repo : Version.Repository.Repository_Handle);

end Version.Restore;
