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

   --  A pending interactive-rebase `exec` step: run Command once After commits
   --  have been applied (After = number of commit lines above it in the todo).
   type Exec_Step is record
      After   : Natural := 0;
      Command : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
   end record;

   package Exec_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Exec_Step);

   --  Why a rebase is paused. Conflict/Edit stops are anchored to a commit
   --  (Current_Commit = Commits (Next_Index)); an Exec stop is anchored to the
   --  failed exec at Next_Exec and carries no current commit.
   type Pause_Kind is (Pause_Conflict, Pause_Edit, Pause_Exec);

   --  A linear rebase replays Commits (Next_Index) onto Current_Replay_Head; a
   --  Merges rebase replays Commits topologically, recreating merges, and
   --  carries Rebased_Map (original -> rebased commit id) instead.
   type Rebase_Mode is (Mode_Linear, Mode_Merges);

   type Map_Pair is record
      Original : Version.Objects.Object_Id_Storage;
      Rebased  : Version.Objects.Object_Id_Storage;
   end record;

   package Map_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Map_Pair);

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
      Actions             : Action_Vectors.Vector := Action_Vectors.Empty_Vector;
      Execs               : Exec_Vectors.Vector := Exec_Vectors.Empty_Vector;
      Next_Exec           : Natural := 0;
      Pause_Reason        : Pause_Kind := Pause_Conflict;
      Mode                : Rebase_Mode := Mode_Linear;
      Rebased_Map         : Map_Vectors.Vector := Map_Vectors.Empty_Vector);
   --  Actions, when non-empty, must have exactly one entry per commit; an empty
   --  vector means every commit is a Pick. Execs are pending exec steps in todo
   --  order; Next_Exec is how many have run. Pause_Reason is meaningful only
   --  when Paused (Current_Commit is required for Conflict/Edit, empty for Exec).

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
   function Execs (State : Rebase_State) return Exec_Vectors.Vector;
   function Next_Exec (State : Rebase_State) return Natural;
   function Pause_Reason (State : Rebase_State) return Pause_Kind;
   function Mode (State : Rebase_State) return Rebase_Mode;
   function Rebased_Map (State : Rebase_State) return Map_Vectors.Vector;

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
      Execs_Value               : Exec_Vectors.Vector;
      Next_Exec_Value           : Natural := 0;
      Pause_Reason_Value        : Pause_Kind := Pause_Conflict;
      Mode_Value                : Rebase_Mode := Mode_Linear;
      Rebased_Map_Value         : Map_Vectors.Vector;
   end record;
end Version.Rebase_State;
