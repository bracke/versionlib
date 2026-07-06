with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
use type Version.Objects.Object_Id_Storage;
with Version.Repository;

package Version.Rebase_State is

   package Commit_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Version.Objects.Object_Id_Storage);

   --  Per-commit interactive-rebase action. Pick replays the commit unchanged;
   --  Reword replays it and opens the editor to rewrite its message; Edit
   --  replays it and stops the rebase so the user can amend before continuing.
   type Rebase_Action is (Pick, Reword, Edit);

   package Action_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Rebase_Action);

   type Rebase_State is private;

   procedure Write_State
     (Repo                : Version.Repository.Repository_Handle;
      Branch_Ref          : String;
      Original_Head       : Version.Objects.Hex_Object_Id;
      Target_Head         : Version.Objects.Hex_Object_Id;
      Current_Replay_Head : Version.Objects.Hex_Object_Id;
      Next_Index          : Natural;
      Commits             : Commit_Vectors.Vector;
      Paused              : Boolean := False;
      Current_Commit      : String := "";
      Actions             : Action_Vectors.Vector := Action_Vectors.Empty_Vector);
   --  Actions, when non-empty, must have exactly one entry per commit; an empty
   --  vector means every commit is a Pick.

   function Read_State
     (Repo : Version.Repository.Repository_Handle)
      return Rebase_State;

   procedure Clear_State
     (Repo : Version.Repository.Repository_Handle);

   function State_Exists
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;

   function Branch_Ref (State : Rebase_State) return String;
   function Original_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id;
   function Target_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id;
   function Current_Replay_Head (State : Rebase_State) return Version.Objects.Hex_Object_Id;
   function Next_Index (State : Rebase_State) return Natural;
   function Total_Commits (State : Rebase_State) return Natural;
   function Commits (State : Rebase_State) return Commit_Vectors.Vector;
   function Actions (State : Rebase_State) return Action_Vectors.Vector;
   --  One action per commit (all Pick for state written without actions).
   function Paused (State : Rebase_State) return Boolean;
   function Current_Commit (State : Rebase_State) return Version.Objects.Hex_Object_Id;

private
   type Rebase_State is record
      Branch_Ref_Value          : Ada.Strings.Unbounded.Unbounded_String;
      Original_Head_Value       : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Target_Head_Value         : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Current_Replay_Head_Value : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Next_Index_Value          : Natural := 0;
      Commits_Value             : Commit_Vectors.Vector;
      Actions_Value             : Action_Vectors.Vector;
      Paused_Value              : Boolean := False;
      Current_Commit_Value      : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   end record;
end Version.Rebase_State;
