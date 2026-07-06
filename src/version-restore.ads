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

end Version.Restore;
