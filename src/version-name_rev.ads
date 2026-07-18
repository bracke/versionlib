with Version.Objects;
with Version.Repository;

--  git's `name-rev`: the nearest ref-based name for a commit.
--
--  This is a port of builtin/name-rev.c. It matters that it walks *every*
--  parent, not just the first: a commit reachable only through a merge's
--  second parent is named "<tip>^2", which a first-parent walk can never
--  produce (it would fall back to a branch name, or to "undefined").
package Version.Name_Rev is

   Undefined : constant String := "undefined";

   function Describe_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Target    : Version.Objects.Hex_Object_Id;
      Tags_Only : Boolean := False)
      return String;
   --  The name git's `name-rev` prints for Target: a ref name, optionally
   --  followed by `^<parent>` for each merge parent descended through and
   --  `~<n>` for first-parent steps. Returns Undefined when no ref reaches
   --  Target. Tags_Only restricts the search to `refs/tags/` (git's --tags).

end Version.Name_Rev;
