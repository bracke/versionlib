with Ada.Containers.Vectors;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Repository;

package Version.History is

   package Commit_Id_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Version.Objects.Object_Id_Storage);

   function Parent_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Commit_Id_Vectors.Vector;

   function Is_Ancestor
     (Repo       : Version.Repository.Repository_Handle;
      Base_Id    : Version.Objects.Hex_Object_Id;
      Derived_Id : Version.Objects.Hex_Object_Id)
      return Boolean;

   function Merge_Bases
     (Repo  : Version.Repository.Repository_Handle;
      Left  : Version.Objects.Hex_Object_Id;
      Right : Version.Objects.Hex_Object_Id)
      return Commit_Id_Vectors.Vector;

   function Merge_Base
     (Repo  : Version.Repository.Repository_Handle;
      Left  : Version.Objects.Hex_Object_Id;
      Right : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id;

   type Rev_List_Options is record
      Max_Count    : Natural := 0;
      No_Merges    : Boolean := False;
      First_Parent : Boolean := False;
      Oldest_First : Boolean := False;
   end record;
   --  Max_Count caps the number of commits returned (git's `-<n>`); 0 means
   --  unlimited. No_Merges drops commits with more than one parent from the
   --  output (they are still traversed), as `--no-merges`. First_Parent
   --  follows only each commit's first parent. Oldest_First reverses the
   --  result after Max_Count has been applied, exactly as git's `--reverse`
   --  composes with `-<n>`.

   function Rev_List
     (Repo    : Version.Repository.Repository_Handle;
      Include : Commit_Id_Vectors.Vector;
      Exclude : Commit_Id_Vectors.Vector := Commit_Id_Vectors.Empty_Vector;
      Options : Rev_List_Options := (others => <>))
      return Commit_Id_Vectors.Vector;
   --  git's `rev-list Include... ^Exclude...`: the commits reachable from any
   --  of Include but from none of Exclude, newest first in committer-date
   --  order. This is git's default ordering, and shares git's behaviour under
   --  clock skew (a parent stamped newer than its child can be emitted before
   --  the boundary is known). Merge commits are traversed through every
   --  parent, so unlike a first-parent walk this sees side-branch history.

   function Reachable_Objects
     (Repo    : Version.Repository.Repository_Handle;
      Root_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Return all commit, tree, and blob objects reachable from Root_Id.
   --  The traversal is conservative and deduplicated; callers that write
   --  packs may perform final sorting/deduplication themselves.

end Version.History;