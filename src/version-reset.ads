with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

--  `git reset` semantics, in two forms:
--    * Reset_To_Commit moves HEAD (and, per Mode, the index and working tree)
--      to a target commit.
--    * Reset_Paths resets index entries for the given paths to their state in a
--      target commit (default HEAD), leaving HEAD and the working tree alone.
--  Both resolve the target before any mutation (fail-before-mutation contract).
package Version.Reset is

   type Reset_Mode is (Soft, Mixed, Hard);
   --  Soft : move HEAD only.
   --  Mixed: move HEAD and reset the index to the target tree (default).
   --  Hard : move HEAD, reset the index, and reset the working tree.

   package Path_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   procedure Reset_To_Commit
     (Repo   : Version.Repository.Repository_Handle;
      Mode   : Reset_Mode;
      Target : String);
   --  Move the current branch (or detached HEAD) to the commit named by Target,
   --  writing a "reset: moving to <Target>" reflog entry. With Mixed/Hard the
   --  index is reset to the target tree; with Hard the working tree is too.
   --  @param Repo Open repository handle.
   --  @param Mode Reset mode.
   --  @param Target Revision to reset to (e.g. "HEAD~1", a branch, a commit id).

   procedure Reset_Paths
     (Repo   : Version.Repository.Repository_Handle;
      Target : String;
      Paths  : Path_Vectors.Vector);
   --  Reset the index entries matching Paths (exact file or directory prefix)
   --  to their state in Target's tree; HEAD and the working tree are untouched.
   --  @param Repo Open repository handle.
   --  @param Target Revision whose tree supplies the reset index state.
   --  @param Paths Paths (or directory prefixes) to reset in the index.

end Version.Reset;
