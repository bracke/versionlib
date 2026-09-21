with Ada.Strings.Unbounded;

with Version.Repository;

--  git's branch.c and the operations of builtin/branch.c that are not a
--  listing: creating a branch with its tracking set-up, upstream
--  configuration, rename/copy with reflog and config carried along, and
--  removal. Every refusal raises Branch_Error with git's exact die text.
package Version.Branches is

   use Ada.Strings.Unbounded;

   Branch_Error : exception;

   --  git's branch_track: how a new branch's upstream is chosen.
   type Track_Mode is
     (Track_Never,      --  branch.autoSetupMerge = false / --no-track
      Track_Remote,     --  true (default): only from a remote-tracking ref
      Track_Always,     --  always: also from a local branch
      Track_Explicit,   --  -t / --track[=direct]: the start must be a branch
      Track_Inherit,    --  --track=inherit: copy the start branch's upstream
      Track_Simple);    --  simple: a remote branch of the same name

   function Default_Track
     (Repo : Version.Repository.Repository_Handle) return Track_Mode;
   --  branch.autoSetupMerge, Track_Remote when unset.

   function Branch_Ref_Of
     (Repo : Version.Repository.Repository_Handle; Spec : String)
      return String;
   --  git's dwim_ref limited to what a start point or upstream may name:
   --  refs/heads/<spec>, refs/remotes/<spec>, or Spec itself when it is a
   --  full ref that exists; "" when none does.

   procedure Create
     (Repo       : Version.Repository.Repository_Handle;
      Name       : String;
      Start_Name : String;
      Force      : Boolean;
      Track      : Track_Mode;
      Quiet      : Boolean;
      Reflog     : Boolean;
      Note       : out Unbounded_String;
      Warning    : out Unbounded_String);
   --  git's create_branch: validates Name and Start_Name (`'x' is not a
   --  valid branch name`, `a branch named 'x' already exists`, `not a
   --  valid object name: 'x'`, `not a valid branch point: 'x'`, the
   --  worktree refusal under Force, the tracking refusals), points
   --  refs/heads/Name at the start commit with the reflog entry `branch:
   --  Created from <start>` (`branch: Reset to <start>` under Force), and
   --  sets up tracking per Track. Note receives the `branch 'x' set up to
   --  track 'y'.` line git prints (unless Quiet), or ""; Warning the
   --  `asked to inherit tracking ...` warning when Track_Inherit finds
   --  nothing to inherit.

   procedure Setup_Tracking
     (Repo     : Version.Repository.Repository_Handle;
      Name     : String;
      Orig_Ref : String;
      Track    : Track_Mode;
      Quiet    : Boolean;
      Note     : out Unbounded_String;
      Warning  : out Unbounded_String);
   --  git's setup_tracking for the branch Name against the full ref
   --  Orig_Ref: a remote-tracking ref maps to its remote and source branch,
   --  a local branch to remote "."; Track_Inherit copies the source
   --  branch's own upstream. Under Track_Remote/Track_Simple a local start
   --  sets nothing up.

   procedure Set_Upstream_To
     (Repo     : Version.Repository.Repository_Handle;
      Name     : String;
      Upstream : String;
      Quiet    : Boolean;
      Note     : out Unbounded_String);
   --  `--set-upstream-to=<upstream>`: git's dwim_and_setup_tracking, dying
   --  with `the requested upstream branch '<x>' does not exist` (the CLI
   --  adds git's advice).

   procedure Unset_Upstream
     (Repo : Version.Repository.Repository_Handle; Name : String);
   --  Drops branch.<Name>.remote and .merge; `branch '<x>' has no upstream
   --  information` when neither is set.

   function Has_Upstream_Config
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean;

   procedure Rename_Or_Copy
     (Repo        : Version.Repository.Repository_Handle;
      Old_Name    : String;
      New_Name    : String;
      Copy        : Boolean;
      Force       : Boolean;
      Head_Branch : String);
   --  git's copy_or_rename_branch. Head_Branch is the checked-out branch
   --  ("" when HEAD is detached): renaming it repoints HEAD. The reflog
   --  moves (or is copied) with the branch and gains `Branch: renamed
   --  refs/heads/a to refs/heads/b` (`copied` for a copy); the
   --  branch.<name> config section follows.

   procedure Remove
     (Repo   : Version.Repository.Repository_Handle;
      Name   : String;
      Remote : Boolean);
   --  Delete refs/heads/Name (or refs/remotes/Name), its reflog and its
   --  branch.<Name> config section -- no safety checks; the caller made
   --  them, as builtin/branch.c's delete_branches does.

end Version.Branches;
