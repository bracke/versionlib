with Version.Objects;
with Version.Repository;

package Version.Maintenance is

   type Maintenance_Result is record
      Object_Count      : Natural := 0;
      Unreachable_Count : Natural := 0;
      Deleted_Count     : Natural := 0;
   end record;

   function Verify
     (Repo : Version.Repository.Repository_Handle)
      return Maintenance_Result;

   function Repack
     (Repo : Version.Repository.Repository_Handle)
      return Maintenance_Result;

   function Prune
     (Repo    : Version.Repository.Repository_Handle;
      Dry_Run : Boolean := True;
      Now     : Boolean := False)
      return Maintenance_Result;

   function GC
     (Repo    : Version.Repository.Repository_Handle;
      Dry_Run : Boolean := True)
      return Maintenance_Result;

   function Unreachable_Loose_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;

end Version.Maintenance;
