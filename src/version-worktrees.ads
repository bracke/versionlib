with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Worktrees is
   type Worktree_Info is record
      Path      : Ada.Strings.Unbounded.Unbounded_String;
      Branch    : Ada.Strings.Unbounded.Unbounded_String;
      Detached  : Boolean := False;
      Current   : Boolean := False;
      Missing   : Boolean := False;
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

   procedure Remove
     (Path : String);

   function Branch_Checked_Out_Elsewhere
     (Branch : String)
      return Boolean;
end Version.Worktrees;
