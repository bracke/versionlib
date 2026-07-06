with Version.Objects;
with Version.Repository;

package Version.Reachability is

   function Repository_Roots
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;

   function Reflog_Roots
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;

   function Reachable_From
     (Repo  : Version.Repository.Repository_Handle;
      Roots : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Object_Id_Vectors.Vector;

   function All_Loose_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;

end Version.Reachability;
