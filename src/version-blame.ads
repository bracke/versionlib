with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git blame`: attribute each line of a file to a commit. This is a simpler
--  content-based attribution (each line is credited to the most recent commit
--  that added that exact line, walking first-parent history), not git's
--  position-tracking LCS algorithm, so results can differ for moved or
--  duplicated lines.
package Version.Blame is

   type Line_Blame is record
      Commit : Version.Objects.Object_Id_Storage;
      Text   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Blame_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Line_Blame);

   function Blame_File
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id;
      Path : String)
      return Blame_Vectors.Vector;
   --  Raises Ada.IO_Exceptions.Data_Error when Path is absent at Tip.

end Version.Blame;
