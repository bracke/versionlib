with Version.Objects;
with Version.Repository;

--  A position-independent identity for the change a commit introduces: the
--  SHA-1 of its diff against its first parent with volatile bits (diff/index
--  headers and hunk line numbers) removed. Equal ids mean the same textual
--  change regardless of where it lands. Used by `cherry` and `range-diff`.
package Version.Patch_Id is

   function Of_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String;

end Version.Patch_Id;
