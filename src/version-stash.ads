with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Pathspec;
with Version.Repository;

package Version.Stash is

   use Ada.Strings.Unbounded;

   function Invalid_Stash_Spec_Diagnostic (Spec : String) return String;
   function Stash_Spec_Out_Of_Range_Diagnostic (Spec : String) return String;
   function No_Stash_Entries_Diagnostic return String;
   function Malformed_Stash_Reflog_Diagnostic return String;
   function Inconsistent_Stash_Storage_Diagnostic return String;
   function Apply_In_Progress_State_Diagnostic return String;
   function Apply_Dirty_Working_Tree_Diagnostic return String;
   function Apply_Conflicts_Diagnostic return String;

   type Stash_Entry is record
      Index   : Natural;
      Id      : Version.Objects.Object_Id_Storage;
      Message : Unbounded_String;
   end record;

   package Stash_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Stash_Entry);

   procedure Push
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   function Create
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String;

   procedure Store
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Message   : String := "");

   function List_Entries
     (Repo : Version.Repository.Repository_Handle)
      return Stash_Entry_Vectors.Vector;

   procedure List;

   function Show
     (Spec      : String := "stash@{0}";
      Patch     : Boolean := False;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String;

   function Resolve_Stash
     (Repo : Version.Repository.Repository_Handle;
      Spec : String := "stash@{0}")
      return Version.Objects.Hex_Object_Id;

   procedure Apply
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   procedure Apply_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   --  Re-apply an autostash onto the current working tree: 3-way merges the
   --  stash onto the current index tree (which may carry a staged --no-commit
   --  merge result), with no clean precondition and no reset to HEAD, leaving
   --  the index unchanged. Used by merge --autostash.
   procedure Apply_Autostash (Stash_Id : Version.Objects.Hex_Object_Id);

   function Apply_Selected
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean;

   procedure Pop
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   procedure Branch
     (Name : String;
      Spec : String := "stash@{0}");

   procedure Drop
     (Spec : String := "stash@{0}");

   procedure Clear;

end Version.Stash;
