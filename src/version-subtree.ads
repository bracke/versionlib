with Version.Objects;
with Version.Repository;

--  `git subtree`: keep a foreign project's history inside a subdirectory of
--  this one, without the submodule indirection.  `Add`/`Merge` graft the
--  foreign history in at Prefix; `Split` extracts the history of Prefix back
--  out as a standalone lineage of commits whose trees are the subdirectory's
--  content; `Push` splits and pushes that lineage upstream.
--
--  The commits `Split` synthesises are byte-identical to git's: it copies the
--  original author and committer lines verbatim, reuses an existing commit
--  whenever a parent already carries the identical subtree, and honours the
--  `git-subtree-dir:`/`-mainline:`/`-split:` trailers that `Add`/`Merge` leave
--  behind, so a re-split resumes where the previous one stopped.
package Version.Subtree is

   --  Graft Ref of Repository (a remote name, path, or URL) -- or, when
   --  Repository is empty, the local commit named by Ref -- into Prefix as a
   --  merge commit.  Squash collapses the foreign history into a single
   --  synthetic commit first, as `--squash` does.
   procedure Add
     (Prefix     : String;
      Repository : String;
      Ref        : String;
      Squash     : Boolean := False;
      Message    : String := "");

   --  The commit a `subtree merge`/`pull` should merge with
   --  `-Xsubtree=<prefix>`: the foreign tip itself, or -- with Squash -- a
   --  synthetic commit carrying its tree and none of its history.  Fetches
   --  first when Repository is given.  Already_Current comes back True when
   --  the subtree is already at that commit and there is nothing to merge.
   function Merge_Target
     (Prefix          : String;
      Repository      : String;
      Ref             : String;
      Squash          : Boolean;
      Already_Current : out Boolean)
      return Version.Objects.Hex_Object_Id;

   --  Merge a new state of the subtree into Prefix (`-Xsubtree=<prefix>`).
   procedure Merge
     (Prefix     : String;
      Repository : String;
      Ref        : String;
      Squash     : Boolean := False;
      Message    : String := "");

   --  Extract Prefix's history as a standalone lineage and return its tip.
   --  Branch, when given, is created (or fast-forwarded) to that tip.
   --  Rejoin merges the result back into the current history, leaving the
   --  trailers a later split resumes from.
   function Split
     (Repo    : Version.Repository.Repository_Handle;
      Prefix  : String;
      Rev     : String := "HEAD";
      Branch  : String := "";
      Onto    : String := "";
      Rejoin  : Boolean := False;
      Ignore_Joins : Boolean := False;
      Updated : out Boolean)
      return Version.Objects.Hex_Object_Id;

   --  Split Prefix out of Local_Rev and push the resulting tip to Remote_Ref
   --  (a branch name) on Repository.
   procedure Push
     (Prefix     : String;
      Repository : String;
      Local_Rev  : String;
      Remote_Ref : String;
      Force      : Boolean := False);

   --  The tree object Prefix names inside Commit_Id, or "" when the commit
   --  has no such directory (a gitlink there counts as absent, as it does for
   --  git).
   function Subtree_Tree_Id
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Prefix    : String)
      return String;

   function Prefix_Exists_Diagnostic (Prefix : String) return String;

   function Prefix_Missing_Diagnostic (Prefix : String) return String;

   function Working_Tree_Dirty_Diagnostic return String;

   function Index_Dirty_Diagnostic return String;

   function No_New_Revisions_Diagnostic return String;

end Version.Subtree;
