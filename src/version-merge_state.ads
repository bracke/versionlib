with Ada.Strings.Unbounded;

with Version.Merge;
with Version.Objects;
with Version.Repository;

package Version.Merge_State is

   procedure Write_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : Version.Objects.Hex_Object_Id;
      Target_Id     : Version.Objects.Hex_Object_Id;
      Target_Branch : String;
      Git_State     : Boolean := False;
      Message       : String := "";
      Mode          : String := "");

   procedure Write_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : Version.Objects.Hex_Object_Id;
      Target_Id     : Version.Objects.Hex_Object_Id;
      Base_Id       : Version.Objects.Hex_Object_Id;
      Target_Branch : String;
      Conflicts     : Version.Merge.Conflict_Vectors.Vector;
      Git_State     : Boolean := False;
      Message       : String := "";
      Mode          : String := "");

   procedure Read_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Target_Branch :
        out Ada.Strings.Unbounded.Unbounded_String);

   procedure Read_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Base_Id       : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Ada.Strings.Unbounded.Unbounded_String;
      Conflicts     : in out Version.Merge.Conflict_Vectors.Vector);

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle);

   procedure Write_Orig_Head
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id);

   function Git_Message_Text
     (Repo     : Version.Repository.Repository_Handle;
      Fallback : String)
      return String;

   function Git_Mode_Text
     (Repo : Version.Repository.Repository_Handle)
      return String;

   function Git_State_Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function State_Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

end Version.Merge_State;
