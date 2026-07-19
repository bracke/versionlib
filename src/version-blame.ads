with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git blame`: attribute each line of a file to the commit that introduced
--  it, walking first-parent history and following lines between revisions
--  with git's own line correspondence (Version.Merge.Align_Lines).
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

   function Blame_Working_File
     (Repo         : Version.Repository.Repository_Handle;
      Tip          : Version.Objects.Hex_Object_Id;
      Path         : String;
      Working_Text : String)
      return Blame_Vectors.Vector;
   --  Blame the file as it stands in the working tree, which is what `git
   --  blame <file>` reports. Lines that do not correspond to any line at Tip
   --  are not in any commit yet and come back with Version.Objects.Zero -- the
   --  all-zero id git prints as "Not Committed Yet". Every other line is
   --  followed back through history exactly as Blame_File follows it.

end Version.Blame;
