with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git range-diff`: compare two commit ranges (two revisions of a patch
--  series) and pair their commits. Following git's builtin/range-diff.c, each
--  commit is reduced to a canonical patch; identical patches pair exactly, and
--  the rest are paired by a minimum-cost assignment over a diff-of-diffs cost
--  matrix bounded by the creation factor. Leftovers are Removed (old only) or
--  Added (new only).
package Version.Range_Diff is

   type Pair_Status is (Unchanged, Changed, Removed, Added);
   --  Unchanged is git's "=", Changed its "!", Removed its "<", Added its ">".

   type Pairing is record
      Old_Pos : Natural;
      New_Pos : Natural;
      Old_Id  : Version.Objects.Object_Id_Storage;
      New_Id  : Version.Objects.Object_Id_Storage;
      Subject : Ada.Strings.Unbounded.Unbounded_String;
      Status  : Pair_Status;
      --  The two commits' canonical patches, so a Changed pair can be shown as
      --  the diff-of-diffs; empty for the absent side of a Removed/Added row.
      Old_Patch : Ada.Strings.Unbounded.Unbounded_String;
      New_Patch : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Pairing_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Pairing);

   function Compare
     (Repo     : Version.Repository.Repository_Handle;
      Old_Base : Version.Objects.Hex_Object_Id;
      Old_Tip  : Version.Objects.Hex_Object_Id;
      New_Base : Version.Objects.Hex_Object_Id;
      New_Tip  : Version.Objects.Hex_Object_Id;
      Creation_Factor : Natural := 60)
      return Pairing_Vectors.Vector;
   --  The pairings in git's output order (the RHS order, with each removed LHS
   --  commit placed once all its predecessors have been shown). Creation_Factor
   --  is git's --creation-factor (default 60): a higher value pairs commits
   --  whose contents diverged more.

   function Inner_Diff (Old_Patch, New_Patch : String) return String;
   --  git's diff-of-diffs body under a Changed ("!") pair: the unified diff
   --  between the two canonical patches, each line indented four spaces, with
   --  no file header and the hunk header naming the enclosing "## section ##".

end Version.Range_Diff;
