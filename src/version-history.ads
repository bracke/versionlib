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

   function Reachable_Objects
     (Repo    : Version.Repository.Repository_Handle;
      Root_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Return all commit, tree, and blob objects reachable from Root_Id.
   --  The traversal is conservative and deduplicated; callers that write
   --  packs may perform final sorting/deduplication themselves.

end Version.History;