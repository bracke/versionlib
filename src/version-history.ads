with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

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

   package Path_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   No_Parent_Limit : constant Integer := -1;

   type Rev_List_Options is record
      Max_Count    : Natural := 0;
      Skip         : Natural := 0;
      No_Merges    : Boolean := False;
      First_Parent : Boolean := False;
      Oldest_First : Boolean := False;
      Min_Parents  : Natural := 0;
      Max_Parents  : Integer := No_Parent_Limit;
      Paths        : Path_Vectors.Vector;
   end record;
   --  Max_Count caps the number of commits returned (git's `-<n>`); 0 means
   --  unlimited. Skip drops that many commits from the front of the selection
   --  before Max_Count applies, as git's `--skip` does. No_Merges drops
   --  commits with more than one parent from the output (they are still
   --  traversed), as `--no-merges`. First_Parent follows only each commit's
   --  first parent. Oldest_First reverses the result after Skip and Max_Count
   --  have been applied, exactly as git's `--reverse` composes with `-<n>`.
   --  Min_Parents and Max_Parents are git's `--min-parents`/`--max-parents`,
   --  which is also how it defines `--merges` (min 2) and `--no-merges`
   --  (max 1); Max_Parents = No_Parent_Limit means no upper bound.
   --
   --  Paths limits the walk to commits that changed one of them, with git's
   --  default history simplification: a merge whose content under the limits
   --  matches one of its parents is dropped and only that parent is followed,
   --  so a side branch that did not touch the paths disappears from the
   --  result instead of being listed. A path names either a file or a
   --  directory, whose whole subtree is matched.

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

   function Apply_Limits
     (Commits : Commit_Id_Vectors.Vector;
      Options : Rev_List_Options)
      return Commit_Id_Vectors.Vector;
   --  Apply Skip, then Max_Count, then Oldest_First to an already-selected
   --  list. Rev_List does this inside the walk; a caller that reorders the
   --  selection first (for `--topo-order`) has to defer the caps until after
   --  the reordering, which is what git does too.

   function Topological_Order
     (Repo     : Version.Repository.Repository_Handle;
      Selected : Commit_Id_Vectors.Vector)
      return Commit_Id_Vectors.Vector;
   --  Reorder a Rev_List selection the way git's `--topo-order` does: never
   --  emit a commit before every selected child of it has been emitted.
   --  Among the commits that become ready, git takes the most recently
   --  readied one (its topo sort runs the LIFO variant), which is what keeps
   --  a side branch together instead of interleaving it by date.

   type Named_Object is record
      Id   : Version.Objects.Object_Id_Storage;
      Name : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Named_Object_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Named_Object);

   function Object_List
     (Repo     : Version.Repository.Repository_Handle;
      Commits  : Commit_Id_Vectors.Vector;
      Excluded : Commit_Id_Vectors.Vector := Commit_Id_Vectors.Empty_Vector)
      return Named_Object_Vectors.Vector;
   --  git's `rev-list --objects`: first the given commits, each unnamed, then
   --  every tree and blob reachable from them paired with the path it appears
   --  under -- empty for a root tree, as git prints it. Objects reachable
   --  from Excluded are left out, which is what makes a range list only what
   --  the range introduced. Each object appears once.

   function Reachable_Objects
     (Repo    : Version.Repository.Repository_Handle;
      Root_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Return all commit, tree, and blob objects reachable from Root_Id.
   --  The traversal is conservative and deduplicated; callers that write
   --  packs may perform final sorting/deduplication themselves.

end Version.History;