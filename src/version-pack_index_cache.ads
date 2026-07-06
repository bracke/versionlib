with Ada.Containers.Ordered_Maps;

with Version.Hash;
with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Pack;
with Version.Repository;

package Version.Pack_Index_Cache is

   type Cache is limited private;

   procedure Clear (Item : in out Cache);

   function Loaded
     (Item : Cache)
      return Boolean;

   function Cached_Location_Count
     (Item : Cache)
      return Natural;
   --  Return the number of object locations loaded from pack indexes.

   procedure Load
     (Repo : Version.Repository.Repository_Handle;
      Item : in out Cache);

   procedure Load_Index
     (Item       : in out Cache;
      Index_Path : String;
      Pack_Path  : String;
      Algorithm  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1);
   --  Load one explicit index/pack pair into Item. This is used by writers
   --  that need to verify temporary pack outputs before publishing them.
   --  Algorithm selects the object-id / checksum width (Sha1 = 20 bytes,
   --  Sha256 = 32).

   function Contains
     (Item : Cache;
      Id   : Version.Objects.Hex_Object_Id)
      return Boolean;

   function Locate
     (Item : Cache;
      Id   : Version.Objects.Hex_Object_Id)
      return Version.Pack.Pack_Location;

   procedure Match_Prefix
     (Item   : Cache;
      Prefix : String;
      Count  : in out Natural;
      Match  : in out Version.Objects.Hex_Object_Id);
   --  Add packed-object IDs whose hexadecimal spelling starts with Prefix to
   --  Count/Match.  This is intended for command-local revision abbreviation
   --  resolution after loose objects have been considered, so ambiguity is
   --  detected across both stores without reading object contents.

private

   package Location_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Version.Pack.Pack_Location,
      "="          => Version.Pack."=");

   type Cache is limited record
      Loaded    : Boolean := False;
      Locations : Location_Maps.Map;
   end record;

end Version.Pack_Index_Cache;
