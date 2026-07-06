with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Transport.Local is

   type Copied_Object is record
      Target : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Copied_Object_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Copied_Object);

   function Resolve_Git_Dir
     (Url : String)
      return String;

   procedure Copy_Object_Store
     (Source_Git_Dir : String;
      Target_Git_Dir : String);

   procedure Copy_Object_Store
     (Source_Git_Dir : String;
      Target_Git_Dir : String;
      Copied_Targets : out Copied_Object_Vectors.Vector);

   procedure Rollback_Copied_Objects
     (Copied_Targets : Copied_Object_Vectors.Vector);

   function Read_First_Line
     (Path : String)
      return String;

end Version.Transport.Local;
