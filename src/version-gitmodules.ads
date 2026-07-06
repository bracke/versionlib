with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Gitmodules is

   use Ada.Strings.Unbounded;

   type Submodule_Config is record
      Name : Unbounded_String;
      Path : Unbounded_String;
      Url  : Unbounded_String;
   end record;

   package Submodule_Config_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Submodule_Config);

   function Read
     (Repository_Path : String)
      return Submodule_Config_Vectors.Vector;

   function Read
     (Repo : Version.Repository.Repository_Handle)
      return Submodule_Config_Vectors.Vector;

   procedure Write
     (Repository_Path : String;
      Items           : Submodule_Config_Vectors.Vector);

   procedure Write
     (Repo  : Version.Repository.Repository_Handle;
      Items : Submodule_Config_Vectors.Vector);

   function Find_By_Path
     (Items : Submodule_Config_Vectors.Vector;
      Path  : String)
      return Natural;

end Version.Gitmodules;
