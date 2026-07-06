with Version.Objects;
with Version.Repository;

package Version.Shallow is

   function Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Read
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;

   procedure Write
     (Repo  : Version.Repository.Repository_Handle;
      Items : Version.Objects.Object_Id_Vectors.Vector);

   procedure Add
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Remove
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id);

   function Is_Shallow_Boundary
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Boolean;

   procedure Validate_Depth (Depth : Natural);

end Version.Shallow;
