with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Remotes is

   use Ada.Strings.Unbounded;

   function Invalid_Remote_Name_Diagnostic
     (Name : String)
      return String;

   function Remote_Already_Exists_Diagnostic
     (Name : String)
      return String;

   function Remote_Does_Not_Exist_Diagnostic
     (Name : String)
      return String;

   type Remote is record
      Name : Unbounded_String;
      Url  : Unbounded_String;
   end record;

   package Remote_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Remote);

   procedure Add_Remote (Name : String; Url  : String);

   procedure Delete_Remote (Name : String);

   procedure Set_Url (Name : String; Url : String);

   procedure Rename_Remote (Old_Name : String; New_Name : String);

   function Get_Url (Name : String) return String;

   function Get_Url_Text (Name : String) return String;

   function Remote_Exists (Name : String) return Boolean;

   function Prune_Dry_Run_Text (Name : String) return String;

   function Prune_Text (Name : String) return String;

   function Remote_Line (Item : Remote) return String;

   function List_Text return String;

   function List_Remotes return Remote_Vectors.Vector;

end Version.Remotes;
