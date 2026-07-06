with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;

package Version.Tags is

   use Ada.Strings.Unbounded;

   function Invalid_Tag_Name_Diagnostic
     (Name : String)
      return String;

   function Tag_Already_Exists_Diagnostic
     (Name : String)
      return String;

   function Tag_Does_Not_Exist_Diagnostic
     (Name : String)
      return String;

   function Invalid_Current_Commit_Id_Diagnostic return String;

   function Empty_Tag_Message_Diagnostic return String;

   package Tag_Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   procedure Create_Tag
     (Name : String);

   procedure Create_Tag
     (Name     : String;
      Revision : String);

   procedure Create_Annotated_Tag
     (Name    : String;
      Message : String);

   procedure Create_Annotated_Tag
     (Name     : String;
      Revision : String;
      Message  : String);

   procedure Delete_Tag
     (Name : String);

   function Delete_Tag_Text
     (Name : String)
      return String;

   procedure Rename_Tag
     (Old_Name : String;
      New_Name : String);

   function Rename_Tag_Text
     (Old_Name : String;
      New_Name : String)
      return String;

   function Tag_Exists
     (Name : String)
      return Boolean;

   function Resolve_Tag
     (Name : String)
      return Version.Objects.Hex_Object_Id;

   function Resolve_Tag_Text
     (Name : String)
      return String;

   function Peel_Tag
     (Name : String)
      return Version.Objects.Hex_Object_Id;

   function Peel_Tag_Text
     (Name : String)
      return String;

   function Show_Tag_Text
     (Name : String)
      return String;

   function List_Tags
      return Tag_Name_Vectors.Vector;

   function List_Tags_Points_At
     (Revision : String)
      return Tag_Name_Vectors.Vector;

   function List_Tags_Points_At_Text
     (Revision : String)
      return String;

   function List_Tags_Containing
     (Revision : String)
      return Tag_Name_Vectors.Vector;

   function List_Tags_Containing_Text
     (Revision : String)
      return String;

end Version.Tags;