with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Staging is

   use Ada.Strings.Unbounded;

   type Index_Entry is record
      Path : Unbounded_String;
      Id    : Version.Objects.Object_Id_Storage;
      Mode  : Unbounded_String;
      Stage : Natural := 0;
      --  git's skip-worktree bit (extended flag 0x4000): the path is tracked
      --  but intentionally absent from the working tree (sparse checkout).
      Skip_Worktree : Boolean := False;
      --  git's assume-valid bit (base flag 0x8000, "assume unchanged"): git
      --  trusts the working file to match without stat'ing it. Preserved so a
      --  rewrite for an unrelated reason does not clear a user's setting.
      Assume_Valid  : Boolean := False;
      --  git's intent-to-add bit (extended flag 0x2000, `add -N`): the path
      --  is recorded with an empty blob so diffs show it, but it is left
      --  out of any tree written from the index and status reports it as
      --  an unstaged addition.
      Intent_To_Add : Boolean := False;
   end record;

   package Index_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Index_Entry);

   function Load
     (Repo : Version.Repository.Repository_Handle)
      return Index_Entry_Vectors.Vector;

   procedure Write
      (Repo    : Version.Repository.Repository_Handle;
       Entries : Index_Entry_Vectors.Vector);

   procedure Write_From_Tree
      (Repo    : Version.Repository.Repository_Handle;
       Tree_Id : Version.Objects.Hex_Object_Id);

   function Entries_From_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id)
      return Index_Entry_Vectors.Vector;
   --  The stage-0 entries an index made from Tree_Id would hold (what
   --  Write_From_Tree writes), without touching the index file.

   function Find_Entry
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String)
      return Natural;

   function Find_Stage_Entry
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String;
      Stage   : Natural)
      return Natural;

   function Find_Path
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String)
      return Natural;

   procedure Replace_Entry
     (Entries : in out Index_Entry_Vectors.Vector;
      Current_Entry   : Index_Entry);

   procedure Remove_Path
     (Entries : in out Index_Entry_Vectors.Vector;
      Path    : String);

   procedure Sort_By_Path
     (Entries : in out Index_Entry_Vectors.Vector);

end Version.Staging;
