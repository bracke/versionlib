with Ada.Containers.Ordered_Maps;
with Ada.Finalization;

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

   procedure List_Prefix
     (Item   : Cache;
      Prefix : String;
      Into   : in out Version.Objects.Object_Id_Vectors.Vector);
   --  Append every packed-object ID whose hexadecimal spelling starts with
   --  Prefix (case-insensitive) to Into.  Backs `rev-parse --disambiguate`,
   --  which lists all objects sharing a prefix rather than counting them.

private

   package Location_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Version.Pack.Pack_Location,
      "="          => Version.Pack."=");

   type Map_Access is access Location_Maps.Map;

   --  A cache's locations: its own, or the ones Load shares among every
   --  cache of one pack directory as it stands -- loaded, sorted and
   --  mapped once, not once a commit, which log -M spent most of its time
   --  doing. A shared map is never changed: Load_Index copies it first.
   type Cache is new Ada.Finalization.Limited_Controlled with record
      Loaded    : Boolean := False;
      Locations : Map_Access;
      Shared    : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Cache);

end Version.Pack_Index_Cache;
