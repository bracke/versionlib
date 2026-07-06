with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Repository;

package Version.Ref_Cache is

   type Ref_Cache is limited private;

   procedure Clear (Cache : in out Ref_Cache);

   function Current_Commit_Id
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache)
      return String;

   function Resolve_Ref
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache;
      Name  : String)
      return Version.Objects.Hex_Object_Id;

   function Try_Resolve_Ref
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Ref_Cache;
      Name  : String;
      Id    : out Version.Objects.Hex_Object_Id)
      return Boolean;

   function Cached_Ref_Count (Cache : Ref_Cache) return Natural;
   function Packed_Refs_Loaded (Cache : Ref_Cache) return Boolean;
   function Cached_Packed_Ref_Count (Cache : Ref_Cache) return Natural;

private

   package Ref_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => Version.Objects.Hex_Object_Id);

   type Ref_Cache is limited record
      Current_Commit_Loaded : Boolean := False;
      Current_Commit        : Ada.Strings.Unbounded.Unbounded_String;
      Resolved_Refs         : Ref_Maps.Map;
      Packed_Loaded         : Boolean := False;
      Packed_Refs           : Ref_Maps.Map;
   end record;

end Version.Ref_Cache;
