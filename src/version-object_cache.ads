with Ada.Containers.Ordered_Maps;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Pack_Index_Cache;
with Version.Repository;

package Version.Object_Cache is

   type Object_Cache is limited private;

   procedure Clear (Cache : in out Object_Cache);

   function Cached_Object_Count
     (Cache : Object_Cache)
      return Natural;
   --  Return the number of decoded objects held by this command-local cache.
   --  This is primarily useful for non-timing scalability tests and diagnostics.

   function Read_Object
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Object_Cache;
      Id    : Version.Objects.Hex_Object_Id)
      return Version.Objects.Git_Object;

private

   package Object_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Version.Objects.Git_Object,
      "="          => Version.Objects."=");

   type Object_Cache is limited record
      Objects      : Object_Maps.Map;
      Pack_Indexes : Version.Pack_Index_Cache.Cache;
   end record;

end Version.Object_Cache;
