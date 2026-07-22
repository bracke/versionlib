with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;
with Version.History;

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

   function Summarize
     (Repo       : Version.Repository.Repository_Handle;
      Commits    : Version.History.Commit_Id_Vectors.Vector;
      With_Email : Boolean := False)
      return Group_Vectors.Vector;
   --  Same, over an already-selected commit list (so the caller can apply a
   --  range, pathspec or --no-merges via rev-list). With_Email groups by the
   --  full "Name <email>" author identity, as `shortlog -e` does. The list is
   --  expected newest-first (rev-list order); each group's subjects are
   --  reversed to chronological order.

end Version.Shortlog;
