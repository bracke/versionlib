with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Config is

   use Ada.Strings.Unbounded;

   type Identity is record
      Name  : Unbounded_String;
      Email : Unbounded_String;
   end record;

   type Config_Entry is record
      Section : Unbounded_String;
      Key     : Unbounded_String;
      Value   : Unbounded_String;
   end record;

   package Config_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Config_Entry);

   function User_Identity
     (Repo : Version.Repository.Repository_Handle)
      return Identity;

   function Trim
     (Value : String)
      return String;

   procedure Require_Config_Scalar
     (Value   : String;
      Context : String);

   procedure Require_Config_Key
     (Key     : String;
      Context : String := "config key");

   procedure Require_Config_Section
     (Section : String;
      Context : String := "config section");

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Config_Entry_Vectors.Vector;

   function Config_Entry_Name
     (Current_Entry : Config_Entry)
      return String;

   function Config_Entry_Line
     (Current_Entry : Config_Entry)
      return String;

   function Get_Value
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String;

   function Get_Text
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String;

   function Has_Key
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Boolean;

   procedure Set_Key
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Value : String);

   procedure Unset_Key
     (Repo : Version.Repository.Repository_Handle;
      Name : String);

   function List_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Keys_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   procedure Replace_Section
     (Repo    : Version.Repository.Repository_Handle;
      Section : String;
      Entries : Config_Entry_Vectors.Vector);

   procedure Remove_Section
     (Repo    : Version.Repository.Repository_Handle;
      Section : String);

end Version.Config;