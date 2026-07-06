with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Repository;

package Version.Cherry_Pick_State is

   package Commit_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Version.Objects.Object_Id_Storage);

   type Head_Kind is (Symbolic_Head, Detached_Head);

   type State is private;

   procedure Write_State
     (Repo         : Version.Repository.Repository_Handle;
      Kind         : Head_Kind;
      Head_Ref     : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Current_Head  : Version.Objects.Hex_Object_Id;
      Next_Index    : Natural;
      Commits       : Commit_Vectors.Vector;
      Mainline      : Natural := 0;
      Paused        : Boolean := False;
      Current_Commit : String := "");

   function Read_State
     (Repo : Version.Repository.Repository_Handle)
      return State;

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle);

   function State_Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Kind (S : State) return Head_Kind;
   function Head_Ref (S : State) return String;
   function Original_Head (S : State) return Version.Objects.Hex_Object_Id;
   function Current_Head (S : State) return Version.Objects.Hex_Object_Id;
   function Next_Index (S : State) return Natural;
   function Total_Commits (S : State) return Natural;
   function Commits (S : State) return Commit_Vectors.Vector;
   function Mainline (S : State) return Natural;
   function Paused (S : State) return Boolean;
   function Current_Commit (S : State) return Version.Objects.Hex_Object_Id;

private
   type State is record
      Kind_Value           : Head_Kind := Symbolic_Head;
      Head_Ref_Value       : Ada.Strings.Unbounded.Unbounded_String;
      Original_Head_Value  : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Current_Head_Value   : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Next_Index_Value     : Natural := 0;
      Commits_Value        : Commit_Vectors.Vector;
      Mainline_Value       : Natural := 0;
      Paused_Value         : Boolean := False;
      Current_Commit_Value : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   end record;
end Version.Cherry_Pick_State;
