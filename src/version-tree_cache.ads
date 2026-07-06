with Ada.Containers.Ordered_Maps;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Repository;

package Version.Tree_Cache is

   type Tree_Cache is limited private;

   procedure Clear (Cache : in out Tree_Cache);

   function Cached_Tree_Count
     (Cache : Tree_Cache)
      return Natural;
   --  Return the number of flattened trees held by this command-local cache.

   function Flatten_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Cache   : in out Tree_Cache;
      Tree_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector;

private

   package Tree_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Version.Objects.Tree_Entry_Vectors.Vector,
      "="          => Version.Objects.Tree_Entry_Vectors."=");

   type Tree_Cache is limited record
      Trees : Tree_Maps.Map;
   end record;

end Version.Tree_Cache;
