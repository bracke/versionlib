with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

--  `git grep`: search tracked files for a pattern. This is a fixed-string
--  (substring) search over the working-tree content of tracked files, not a
--  full regular-expression engine.
package Version.Grep is

   type Match is record
      Path    : Ada.Strings.Unbounded.Unbounded_String;
      Line_No : Positive;
      Text    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Match_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Match);

   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean := False)
      return Match_Vectors.Vector;

end Version.Grep;
