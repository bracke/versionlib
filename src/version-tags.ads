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
     (Name        : String;
      Message     : String;
      Signing_Key : String := "");

   procedure Create_Annotated_Tag
     (Name        : String;
      Revision    : String;
      Message     : String;
      Signing_Key : String := "");
   --  Signing_Key non-empty produces a GPG-signed tag (git `tag -s`/`-u`).

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

   function Tag_Message_Lines
     (Name  : String;
      Lines : Positive := 1)
      return String;
   --  The leading Lines lines of the text `git tag -n<Lines>` shows for Name:
   --  the annotation body of an annotated tag, the commit message of a
   --  lightweight one. Lines after the first carry git's four-space
   --  continuation indent (blank ones included, as %(contents:lines=N) does);
   --  the result has no trailing newline.

   function Tag_Object_Text
     (Name : String)
      return String;
   --  The raw contents of Name's tag object, as `git tag --verify` prints it.
   --  Raises Data_Error when Name is lightweight, since there is no tag
   --  object to verify.

   function Tag_Is_Signed
     (Name : String)
      return Boolean;
   --  True when Name resolves to a tag object carrying a PGP signature block.

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