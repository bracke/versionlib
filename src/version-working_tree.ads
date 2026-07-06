with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Ignore;
with Version.Objects;
with Version.Pathspec;
with Version.Repository;
with Version.Staging;

package Version.Working_Tree is

   use Ada.Strings.Unbounded;

   type Working_File is record
      Path : Unbounded_String;
      Id   : Version.Objects.Object_Id_Storage;
   end record;

   package Working_File_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Working_File);

   function Scan
     (Repo : Version.Repository.Repository_Handle)
      return Working_File_Vectors.Vector;

   function Scan
     (Repo          : Version.Repository.Repository_Handle;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Tracked_Paths : Version.Staging.Index_Entry_Vectors.Vector)
      return Working_File_Vectors.Vector;

   function Scan
     (Repo          : Version.Repository.Repository_Handle;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Tracked_Paths : Version.Staging.Index_Entry_Vectors.Vector;
      Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector)
      return Working_File_Vectors.Vector;
   --  Pathspec-aware scan used by status/diff style callers.  The tree is
   --  still traversed conservatively, but ordinary files and gitlinks that
   --  cannot contribute to the requested pathspecs are not hashed/appended.

end Version.Working_Tree;
