with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Worktrees is
   type Worktree_Info is record
      Path      : Ada.Strings.Unbounded.Unbounded_String;
      Branch    : Ada.Strings.Unbounded.Unbounded_String;
      Detached  : Boolean := False;
      Current   : Boolean := False;
      Missing   : Boolean := False;
      Locked    : Boolean := False;
      Head      : Ada.Strings.Unbounded.Unbounded_String;
      --  The commit this worktree has checked out. git's `worktree list`
      --  reports it for every entry, attached or not, so it cannot be read
      --  off Branch alone.
   end record;

   package Worktree_Info_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Worktree_Info);

   procedure Add
     (Path   : String;
      Branch : String);

   procedure Add_Detached
     (Path : String;
      Rev  : String);

   function List
      return Worktree_Info_Vectors.Vector;

   function Worktree_Status_Markers
     (Item : Worktree_Info)
      return String;

   function Worktree_Status_Line
     (Item : Worktree_Info)
      return String;

   function Current_Worktree_Text
      return String;

   type Prunable_Entry is record
      Name   : Ada.Strings.Unbounded.Unbounded_String;  --  worktrees/<name>
      Reason : Ada.Strings.Unbounded.Unbounded_String;  --  git's wording
   end record;

   package Prunable_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Prunable_Entry);

   procedure Lock
     (Path   : String;
      Reason : String := "");
   --  Mark the worktree locked so `remove` and `prune` leave it alone -- what
   --  git offers for a worktree on removable media. Raises when it is already
   --  locked.

   procedure Unlock (Path : String);
   --  Raises when the worktree is not locked, as git does.

   function Is_Locked (Path : String) return Boolean;

   function Prunable
      return Prunable_Vectors.Vector;
   --  The administrative directories under .git/worktrees whose worktree is
   --  gone. Deleting a linked worktree's directory leaves its admin entry
   --  behind, and until it is cleared the branch it held stays checked out as
   --  far as the repository is concerned.

   procedure Prune;
   --  Delete what Prunable reports.

   procedure Remove
     (Path : String);
   --  Removes a linked worktree. A worktree whose directory has already been
   --  deleted is reclaimed by dropping its admin entry, which is the only way
   --  back: git accepts that, and refusing left the entry unreclaimable by
   --  any command.

   function Branch_Checked_Out_Elsewhere
     (Branch : String)
      return Boolean;
end Version.Worktrees;
