with Version.Objects;
with Version.Repository;

--  `git notes`: attach text notes to commits, stored in the refs/notes/commits
--  tree (commit id -> note blob). Notes are stored flat (one entry per full
--  commit id), which git reads; git's fanout layout is read only at top level.
package Version.Notes is

   procedure Add
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String);
   --  Set (or replace) the note for Commit and advance refs/notes/commits.

   function Show
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
      return String;
   --  The note text for Commit, or "" when there is none.

end Version.Notes;
