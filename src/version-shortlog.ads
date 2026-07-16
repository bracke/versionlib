with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git shortlog`: summarize history grouped by author.
package Version.Shortlog is

   package Subject_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   type Author_Group is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      Subjects : Subject_Vectors.Vector;
   end record;

   package Group_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Author_Group);

   function Summarize
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id)
      return Group_Vectors.Vector;
   --  Commits reachable from Tip, grouped by author name (groups sorted by
   --  name); each group lists the commit subjects oldest first (chronological),
   --  matching git shortlog.

end Version.Shortlog;
