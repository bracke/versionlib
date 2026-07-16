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
