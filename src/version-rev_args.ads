with Ada.Containers.Indefinite_Vectors;

with Version.History;
with Version.Repository;

package Version.Rev_Args is
   --  The part of git's setup_revisions() that rev-list, log and their kin
   --  all share: turning a command's operands into the two frontiers the
   --  history walk needs, plus the paths the result is limited to.

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Revision_Arguments is record
      Include      : Version.History.Commit_Id_Vectors.Vector;
      Exclude      : Version.History.Commit_Id_Vectors.Vector;
      Paths        : String_Vectors.Vector;
      Saw_Revision : Boolean := False;
   end record;

   function Parse
     (Repo : Version.Repository.Repository_Handle;
      Args : String_Vectors.Vector)
      return Revision_Arguments;
   --  Args holds the command's non-option operands in order, including a
   --  literal "--" separator when one was given. Before the separator each
   --  operand is a revision: `A..B` excludes A and includes B, `A...B` is the
   --  symmetric difference (both included, their merge base excluded), a
   --  leading `^` excludes, and anything else is included. Everything after
   --  the separator is a path. Without a separator, an operand that resolves
   --  to no revision is taken as a path, which is what git does.
   --
   --  Raises Ada.IO_Exceptions.Data_Error for an operand that is neither a
   --  revision nor, once paths have started, a plausible path.

   function Ref_Tips
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String := "")
      return Version.History.Commit_Id_Vectors.Vector;
   --  The commits at every ref tip under Prefix, peeled through tag objects;
   --  refs that do not lead to a commit are skipped. Prefix "" is git's
   --  `--all`, "refs/heads/" its `--branches`, "refs/tags/" its `--tags`.

end Version.Rev_Args;
