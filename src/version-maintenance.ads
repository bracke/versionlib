with Version.Objects;
with Version.Repository;

package Version.Maintenance is

   type Maintenance_Result is record
      Object_Count      : Natural := 0;
      Unreachable_Count : Natural := 0;
      Deleted_Count     : Natural := 0;
      --  Repack only: True when every reachable object was already in a pack,
      --  so the repack adds nothing (git's "Nothing new to pack.").
      Nothing_New       : Boolean := False;
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

   function Unreachable_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Every unreachable object in loose OR packed storage. `fsck` reports
   --  these as dangling, unlike `prune` (which only ever removes loose files
   --  and so consults Unreachable_Loose_Objects).

   function Unreachable_Objects
     (Repo  : Version.Repository.Repository_Handle;
      Roots : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  As above, but tracing unreachability from the given roots rather than
   --  the repository's refs. `git fsck <object>...` replaces the default
   --  ref/index/reflog heads with the objects it is handed, so an object a
   --  ref still points to (an annotated tag, say) shows up as dangling.

end Version.Maintenance;
