with Version.Objects;
with Version.Repository;
with Version.Staging;

package Version.Write is

   function Write_Blob
     (Repo    : Version.Repository.Repository_Handle;
      Content : String)
      return Version.Objects.Hex_Object_Id;

   procedure Copy_Object
     (Source : Version.Repository.Repository_Handle;
      Target : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id);
   --  Copy a single object verbatim from Source to Target as a loose object,
   --  preserving its id (used by partial-clone selective object copy).

   function Write_Tree_From_Index
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parent_Id : String;
      Message   : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit_With_Parents
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Commit_With_Author
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Author  : String;
      Message : String)
      return Version.Objects.Hex_Object_Id;
   --  Like Write_Commit_With_Parents but with an explicit author line value
   --  ("Name <email> <ts> <tz>"); the committer is the configured identity.
   --  Used by `am` to preserve a patch's authorship.

   function Write_Signed_Commit_With_Parents
     (Repo        : Version.Repository.Repository_Handle;
      Tree_Id     : Version.Objects.Hex_Object_Id;
      Parents     : Version.Objects.Object_Id_Vectors.Vector;
      Message     : String;
      Signing_Key : String)
      return Version.Objects.Hex_Object_Id;

   function Write_Tag
     (Repo      : Version.Repository.Repository_Handle;
      Target_Id : Version.Objects.Hex_Object_Id;
      Tag_Name  : String;
      Message   : String)
      return Version.Objects.Hex_Object_Id;

   procedure Save_Amend
     (Message   : String;
      Run_Hooks : Boolean := True);

   procedure Save
     (Message   : String;
      Run_Hooks : Boolean := True);

end Version.Write;