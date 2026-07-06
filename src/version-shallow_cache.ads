with Version.Objects;
with Version.Repository;

package Version.Shallow_Cache is

   type Shallow_Cache is limited private;

   procedure Clear
     (Cache : in out Shallow_Cache);

   procedure Load
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Shallow_Cache);

   function Is_Boundary
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Shallow_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Boolean;

   function Cached_Boundary_Count
     (Cache : Shallow_Cache)
      return Natural;

private

   type Shallow_Cache is limited record
      Loaded     : Boolean := False;
      Boundaries : Version.Objects.Object_Id_Vectors.Vector;
   end record;

end Version.Shallow_Cache;
