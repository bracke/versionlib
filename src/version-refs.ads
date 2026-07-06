with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;
with Version.Objects;

package Version.Refs is

   use Ada.Strings.Unbounded;

   type Head_Kind is
     (Attached_Branch,
      Detached_Commit);

   type Head_Info (Kind : Head_Kind := Attached_Branch) is private;

   package Branch_Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   function Read_Head
     (Repo : Version.Repository.Repository_Handle)
      return Head_Info;

   function Current_Commit_Id
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Current_Branch_Name
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Resolve_Ref
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Version.Objects.Hex_Object_Id;

   function Ref_Exists
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Boolean;

   function List_Branches
     (Repo : Version.Repository.Repository_Handle)
      return Branch_Name_Vectors.Vector;

   function Is_Attached
     (Head : Head_Info)
      return Boolean;

   function Is_Detached
     (Head : Head_Info)
      return Boolean;

   function Is_Detached
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Detached_Commit_Id
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id;

   function Branch_Name
     (Head : Head_Info)
      return String;

   function Commit_Id
     (Head : Head_Info)
      return String;

   procedure Write_Detached_HEAD
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Write_Detached_HEAD
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Expected_Old : Version.Objects.Hex_Object_Id);

   procedure Atomic_Write_Ref
      (Path      : String;
      Object_Id : Version.Objects.Hex_Object_Id);

   procedure Write_Symbolic_HEAD
     (Repo   : Version.Repository.Repository_Handle;
      Target : String);
   --  Point HEAD at the symbolic ref Target (e.g. "refs/heads/main") without
   --  touching the working tree, as `symbolic-ref HEAD Target` does.

private

   type Head_Info (Kind : Head_Kind := Attached_Branch) is record
      case Kind is
         when Attached_Branch =>
            Branch_Value : Unbounded_String;

         when Detached_Commit =>
            Commit_Value : Unbounded_String;
      end case;
   end record;

end Version.Refs;
