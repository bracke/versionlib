with Version.Shallow;

package body Version.Shallow_Cache is
   use Version.Objects;

   function Contains
     (Items : Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains;

   procedure Clear
     (Cache : in out Shallow_Cache)
   is
   begin
      Cache.Loaded := False;
      Cache.Boundaries.Clear;
   end Clear;

   procedure Load
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Shallow_Cache)
   is
   begin
      if not Cache.Loaded then
         Cache.Boundaries := Version.Shallow.Read (Repo);
         Cache.Loaded := True;
      end if;
   end Load;

   function Is_Boundary
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Shallow_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      Load (Repo, Cache);
      return Contains (Cache.Boundaries, Commit_Id);
   end Is_Boundary;

   function Cached_Boundary_Count
     (Cache : Shallow_Cache)
      return Natural
   is
   begin
      return Natural (Cache.Boundaries.Length);
   end Cached_Boundary_Count;

end Version.Shallow_Cache;
