with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Diff;
with Version.Objects;
with Version.Pathspec;
with Version.Repository;

package Version.Stash is

   use Ada.Strings.Unbounded;

   function Invalid_Stash_Spec_Diagnostic (Spec : String) return String;
   function Stash_Spec_Out_Of_Range_Diagnostic (Spec : String) return String;
   function No_Stash_Entries_Diagnostic return String;
   function Malformed_Stash_Reflog_Diagnostic return String;
   function Inconsistent_Stash_Storage_Diagnostic return String;
   function Apply_In_Progress_State_Diagnostic return String;
   function Apply_Dirty_Working_Tree_Diagnostic return String;
   function Apply_Conflicts_Diagnostic return String;

   type Stash_Entry is record
      Index   : Natural;
      Id      : Version.Objects.Object_Id_Storage;
      Message : Unbounded_String;
   end record;

   package Stash_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Stash_Entry);

   Stash_Error : exception;
   --  A condition git dies on; the message is git's text without "fatal: ".

   Stash_Failure : exception;
   --  A condition git reports with error()/fprintf and an exit status of 1
   --  rather than a die: no stash to act on, an unresolvable revision.

   --  git's `struct stash_info`: everything the subcommands need about one
   --  stash entry.
   type Stash_Info is record
      Revision : Unbounded_String;   --  "refs/stash@{0}", or the given rev
      W_Commit : Version.Objects.Object_Id_Storage;   --  the stash commit
      B_Commit : Version.Objects.Object_Id_Storage;   --  its first parent
      W_Tree   : Version.Objects.Object_Id_Storage;   --  the working tree
      I_Tree   : Version.Objects.Object_Id_Storage;   --  the index tree
      B_Tree   : Version.Objects.Object_Id_Storage;   --  the base tree
      U_Tree   : Version.Objects.Object_Id_Storage;   --  untracked, if any
      Has_U        : Boolean := False;
      Is_Stash_Ref : Boolean := False;   --  came from refs/stash
   end record;

   function Get_Info
     (Repo : Version.Repository.Repository_Handle;
      Spec : String := "") return Stash_Info;
   --  git's get_stash_info: an empty Spec means `stash@{0}` (and raises
   --  `No stash entries found.` when there is no stash), a bare number N
   --  means `stash@{N}`, anything else is a revision. Raises Stash_Error
   --  with git's `<rev> is not a valid reference` or `'<rev>' is not a
   --  stash-like commit`.

   type Apply_Options is record
      Restore_Index : Boolean := False;   --  --index
      Quiet         : Boolean := False;
      --  The conflict-marker labels; empty means git's defaults
      --  ("Updated upstream" / "Stashed changes" / "Stash base").
      Label_Ours    : Unbounded_String;
      Label_Theirs  : Unbounded_String;
      Label_Base    : Unbounded_String;
   end record;

   package Message_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   procedure Apply_Info
     (Repo       : Version.Repository.Repository_Handle;
      Info       : Stash_Info;
      Options    : Apply_Options;
      Conflicted : out Boolean;
      Narration  : out Message_Vectors.Vector);
   --  git's do_apply_stash: merge the stash's working tree onto the current
   --  index tree against the stash's base -- which works on a dirty tree,
   --  as git's does -- restore the index under --index, and unpack the
   --  untracked parent. Conflicted reports an unclean merge (the conflicted
   --  index is written and the markers are in the files). Raises
   --  Stash_Error with git's texts for the conditions git dies on, among
   --  them the `Your local changes ... would be overwritten by merge`
   --  refusal. Narration holds the lines git prints while merging (its
   --  `Auto-merging <path>` and `CONFLICT (...): Merge conflict in
   --  <path>`), in git's order.

   procedure Drop_Info
     (Repo : Version.Repository.Repository_Handle;
      Info : Stash_Info);
   --  Remove Info's reflog entry (and the ref itself once the reflog is
   --  empty), as git's do_drop_stash does.

   type Push_Options is record
      Include_Untracked : Boolean := False;   --  -u
      Include_Ignored   : Boolean := False;   --  -a
      Keep_Index        : Boolean := False;   --  -k
      Only_Staged       : Boolean := False;   --  -S
      Message           : Unbounded_String;
   end record;

   procedure Push_Entry
     (Repo      : Version.Repository.Repository_Handle;
      Options   : Push_Options;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Saved     : out Boolean;
      Title     : out Unbounded_String);
   --  git's do_push_stash: create the stash, advance refs/stash, and reset
   --  what was stashed. Saved is False (with no stash made) when there is
   --  nothing to save; Title is the stash's message, which the caller
   --  reports as `Saved working directory and index state <title>`.
   --  --keep-index leaves the staged content in the working tree and index,
   --  --staged stashes only the staged changes.

   function Untracked_Tree
     (Repo : Version.Repository.Repository_Handle;
      Info : Stash_Info) return Version.Objects.Hex_Object_Id;
   --  The tree `stash show -u` diffs against the base: the stash's working
   --  tree with its untracked files added.

   procedure Push
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Message           : String := "");
   --  Message is git's `-m`: the stash is titled "On <branch>: <message>"
   --  instead of the default "WIP on <branch>: <short> <subject>".

   function Create
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Message           : String := "")
      return String;

   procedure Store
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Message   : String := "");

   function List_Entries
     (Repo : Version.Repository.Repository_Handle)
      return Stash_Entry_Vectors.Vector;

   procedure List;

   function Show
     (Spec      : String := "stash@{0}";
      Options   : Version.Diff.Diff_Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String;
   --  git's `stash show`: the diff between the stash and its base commit,
   --  rendered per Options (the CLI defaults to `--stat`, git's default). A
   --  three-parent stash (`--include-untracked`) also appends the untracked
   --  tree against an empty base.

   function Resolve_Stash
     (Repo : Version.Repository.Repository_Handle;
      Spec : String := "stash@{0}")
      return Version.Objects.Hex_Object_Id;

   procedure Apply
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   procedure Apply_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   --  Re-apply an autostash onto the current working tree: 3-way merges the
   --  stash onto the current index tree (which may carry a staged --no-commit
   --  merge result), with no clean precondition and no reset to HEAD, leaving
   --  the index unchanged. Used by merge --autostash.
   procedure Apply_Autostash (Stash_Id : Version.Objects.Hex_Object_Id);

   function Apply_Selected
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean;

   procedure Pop
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector);

   procedure Branch
     (Name : String;
      Spec : String := "stash@{0}");

   procedure Drop
     (Spec : String := "stash@{0}");

   procedure Clear;

end Version.Stash;
