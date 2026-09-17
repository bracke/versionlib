with Ada.Containers.Indefinite_Vectors;
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

   --  git's todo grammar. A linear rebase only ever uses Cmd_Pick; a
   --  --rebase-merges rebase expresses topology with the other three:
   --  `label <name>` names the commit HEAD is on, `reset <name>` moves HEAD
   --  back to one, and `merge -C <original> <name>` recreates a merge of the
   --  labelled side. Together they say what a flat list of picks cannot.
   type Todo_Kind is (Cmd_Pick, Cmd_Label, Cmd_Reset, Cmd_Merge);

   type Todo_Command is record
      Kind   : Todo_Kind := Cmd_Pick;
      Action : Rebase_Action := Pick;
      --  Cmd_Pick: the commit to replay. Cmd_Merge: the original merge commit,
      --  whose message and authorship the recreated merge keeps.
      Id     : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      --  Cmd_Label/Cmd_Reset/Cmd_Merge: the label named.
      Label  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Todo_Command_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Todo_Command);

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

   procedure Write_Resume_Info
     (Repo        : Version.Repository.Repository_Handle;
      Author_Line : String;
      Message     : String;
      Patch       : String);
   --  The three files `git rebase --continue` reads for itself, written at a
   --  stop so the other tool can carry the rebase to completion: who authored
   --  the commit being replayed (Author_Line is the raw
   --  "Name <email> <ts> <tz>" from the commit header), the message that
   --  commit should carry, and the diff being applied. Nothing here is read
   --  back by this tool -- the state above is what it resumes from.

   procedure Write_Merges_State
     (Repo           : Version.Repository.Repository_Handle;
      Branch_Ref     : String;
      Original_Head  : Version.Objects.Hex_Object_Id;
      Target_Head    : Version.Objects.Hex_Object_Id;
      Todo           : Todo_Command_Vectors.Vector;
      Done_Count     : Natural;
      Paused         : Boolean := False;
      Current_Commit : String := "");
   --  A --rebase-merges rebase, whose todo carries label/reset/merge. Done is
   --  the number of leading commands already executed: everything below that
   --  goes to `done`, the rest to `git-rebase-todo`, which is what lets git
   --  read and finish the same rebase.

   function Todo (State : Rebase_State) return Todo_Command_Vectors.Vector;
   --  Every command, executed ones first.

   function Done_Count (State : Rebase_State) return Natural;
   --  How many leading commands of Todo have run.

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

   --  What git rebase's option files say about how each commit is replayed:
   --  --signoff, --committer-date-is-author-date, --ignore-date, the -X
   --  strategy options, what to do with a commit that becomes empty
   --  (--empty), whether a commit that starts empty is kept (--keep-empty,
   --  the default), -q, and --update-refs. Written once at the start under
   --  git's own file names (`signoff`, `cdate_is_adate`, `ignore_date`,
   --  `strategy`/`strategy_opts`, `keep_redundant_commits`/
   --  `drop_redundant_commits`, `quiet`, `update-refs`) so git can finish
   --  what this tool started, and read back on --continue.
   type Empty_Policy is (Empty_Drop, Empty_Keep, Empty_Stop);

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Natural, Element_Type => String);

   type Replay_Options is record
      Signoff        : Boolean := False;
      Cdate_Is_Adate : Boolean := False;
      Ignore_Date    : Boolean := False;
      Keep_Empty     : Boolean := True;
      Empty          : Empty_Policy := Empty_Drop;
      Quiet          : Boolean := False;
      Verbose        : Boolean := False;
      Update_Refs    : Boolean := False;
      --  A pick whose parent is already the replay head is taken as it is
      --  (git's fast-forward) unless the rebase was forced (-f, --signoff,
      --  the date options).
      Allow_FF       : Boolean := True;
      --  -X options as typed ("theirs", "ignore-space-change", ...).
      Strategy_Opts  : String_Vectors.Vector;
   end record;

   procedure Write_Options
     (Repo : Version.Repository.Repository_Handle; Options : Replay_Options);

   function Options (State : Rebase_State) return Replay_Options;

   --  --update-refs bookkeeping (git's `update-refs` file: refname, the
   --  tip it had, the tip it gets -- zero until written). The refs are the
   --  branches other than the one being rebased whose tips lie among the
   --  replayed commits; Finish moves each to its rewritten commit.
   type Ref_Update is record
      Ref_Name : Ada.Strings.Unbounded.Unbounded_String;
      Old_Tip  : Version.Objects.Object_Id_Storage;
   end record;

   package Ref_Update_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Ref_Update);

   procedure Write_Update_Refs
     (Repo : Version.Repository.Repository_Handle;
      Refs : Ref_Update_Vectors.Vector);

   function Update_Refs (State : Rebase_State) return Ref_Update_Vectors.Vector;

   --  The same list straight from the state directory (for the finish,
   --  when the rest of the state is already being torn down).
   function Read_Update_Refs
     (Repo : Version.Repository.Repository_Handle)
      return Ref_Update_Vectors.Vector;

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
      Todo_Value                : Todo_Command_Vectors.Vector;
      Done_Count_Value          : Natural := 0;
      Options_Value             : Replay_Options;
      Update_Refs_Value         : Ref_Update_Vectors.Vector;
   end record;
end Version.Rebase_State;
