with Ada.Containers.Indefinite_Vectors;

with Version.Repository;

--  `git show-branch`-compatible rendering: a header naming each branch tip and
--  a matrix marking, for every commit back to the branches' merge base, which
--  branches reach it.  Byte-compatible with git for branches that diverge from
--  a common base without merge commits in the shown range; merge commits inside
--  the range (git's convergence traversal + `^2` naming) are not yet modelled.
package Version.Show_Branch is

   package Name_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  Render the matrix (or, with List_Only, just the head list) for the named
   --  branches in argument order.  Each output line is newline-terminated.
   function Format
     (Repo      : Version.Repository.Repository_Handle;
      Branches  : Name_Vectors.Vector;
      List_Only : Boolean := False) return String;

end Version.Show_Branch;
