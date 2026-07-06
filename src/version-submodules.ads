with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Submodules is

   use Ada.Strings.Unbounded;

   type Submodule_Status_Kind is
     (Submodule_Missing,
      Submodule_Clean,
      Submodule_New_Commits,
      Submodule_Dirty);

   type Submodule_Status is record
      Path     : Unbounded_String;
      Expected : Version.Objects.Object_Id_Storage;
      Actual   : Unbounded_String;
      Kind     : Submodule_Status_Kind;
   end record;

   package Submodule_Status_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Submodule_Status);

   procedure Init;

   procedure Init (Repo : Version.Repository.Repository_Handle);

   procedure Update
     (Recursive : Boolean := False);

   procedure Update
     (Repo      : Version.Repository.Repository_Handle;
      Recursive : Boolean := False);

   procedure Clone_Recursive
     (Url    : String;
      Target : String);

   procedure Status;

   function Statuses
     (Repo : Version.Repository.Repository_Handle)
      return Submodule_Status_Vectors.Vector;

   function Status_Kind_Label
     (Kind : Submodule_Status_Kind)
      return String;

   function Status_Line
     (Item : Submodule_Status)
      return String;

   function Gitlink_Commit
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Version.Objects.Hex_Object_Id;

   function Is_Submodule_Path
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return Boolean;

   function Submodule_Head
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
      return String;

   procedure Stage_Submodule
     (Repo : Version.Repository.Repository_Handle;
      Path : String);

   function Resolve_Relative_Submodule_Url
     (Relative_Url : String;
      Base_Url     : String)
      return String;

end Version.Submodules;
