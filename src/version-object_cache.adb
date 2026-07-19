with Ada.Directories;
with Ada.IO_Exceptions;

with Version.Pack;
with Version.Promisor;

package body Version.Object_Cache is
   use Version.Objects;

   procedure Clear (Cache : in out Object_Cache) is
   begin
      Cache.Objects.Clear;
      Version.Pack_Index_Cache.Clear (Cache.Pack_Indexes);
   end Clear;

   function Cached_Object_Count
     (Cache : Object_Cache)
      return Natural
   is
   begin
      return Natural (Cache.Objects.Length);
   end Cached_Object_Count;

   function Read_Object
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Object_Cache;
      Id    : Version.Objects.Hex_Object_Id)
      return Version.Objects.Git_Object
   is
      Pos : constant Object_Maps.Cursor := Cache.Objects.Find (Id);

      --  Resolve the replacement before reading. The uncached path does this
      --  already; skipping it here made every history walk -- which uses the
      --  cache for speed -- read the original object, so a `replace --graft`
      --  was honoured by `cat-file` and ignored by `rev-list`. The cache is
      --  keyed on the id asked for, so the mapping is paid for once.
      Eff : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.Replacement_Of (Repo, Id);
   begin
      if Object_Maps.Has_Element (Pos) then
         return Object_Maps.Element (Pos);
      end if;

      declare
         Path : constant String :=
           Version.Objects.Loose_Object_Path (Repo, Eff);
      begin
         if Ada.Directories.Exists (Path) then
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Loose_Object (Repo, Eff);
            begin
               Cache.Objects.Include (Id, Obj);
               return Obj;
            end;
         end if;
      end;

      Version.Pack_Index_Cache.Load
        (Repo => Repo,
         Item => Cache.Pack_Indexes);

      declare
         Location : constant Version.Pack.Pack_Location :=
           Version.Pack_Index_Cache.Locate (Cache.Pack_Indexes, Eff);
      begin
         if Location.Found then
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Pack.Read_Object_At_Location
                   (Repo     => Repo,
                    Location => Location);
            begin
               Cache.Objects.Include (Id, Obj);
               return Obj;
            end;
         end if;
      end;

      if Version.Promisor.Fetch_Promised_Object (Repo, To_String (Eff)) then
         declare
            Path : constant String := Version.Objects.Loose_Object_Path (Repo, Eff);
         begin
            if Ada.Directories.Exists (Path) then
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Objects.Read_Loose_Object (Repo, Eff);
               begin
                  Cache.Objects.Include (Id, Obj);
                  return Obj;
               end;
            end if;
         end;

         Version.Pack_Index_Cache.Clear (Cache.Pack_Indexes);
         Version.Pack_Index_Cache.Load
           (Repo => Repo,
            Item => Cache.Pack_Indexes);

         declare
            Location : constant Version.Pack.Pack_Location :=
              Version.Pack_Index_Cache.Locate (Cache.Pack_Indexes, Eff);
         begin
            if Location.Found then
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Pack.Read_Object_At_Location
                      (Repo     => Repo,
                       Location => Location);
               begin
                  Cache.Objects.Include (Id, Obj);
                  return Obj;
               end;
            end if;
         end;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        Version.Promisor.Missing_Object_Diagnostic (Repo, To_String (Id));
   end Read_Object;

end Version.Object_Cache;
