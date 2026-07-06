with Version.Objects;
with Version.Repository;
with Version.Rebase_State;

package Version.Rebase is

   Root_Rebase_Not_Supported : constant String := "root rebases not supported";
   Merge_Commit_Rebase_Not_Supported : constant String :=
     "rebase of merge commits not supported";
   Interactive_Rebase_Not_Supported : constant String :=
     "interactive rebase is not supported";
   Merge_Preserving_Rebase_Not_Supported : constant String :=
     "merge-preserving rebase is not supported";

   type Replay_Result_Kind is
     (Replay_Clean,
      Replay_Conflict);

   type Replay_Result is record
      Kind      : Replay_Result_Kind;
      Commit_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   end record;

   function Commits_To_Replay
     (Repo         : Version.Repository.Repository_Handle;
      Current_Head : Version.Objects.Hex_Object_Id;
      Target_Head  : Version.Objects.Hex_Object_Id)
      return Version.Rebase_State.Commit_Vectors.Vector;

   function Replay_Commit
     (Repo          : Version.Repository.Repository_Handle;
      Replay_Parent : Version.Objects.Hex_Object_Id;
      Commit_Id     : Version.Objects.Hex_Object_Id;
      Allow_Root    : Boolean := False;
      Reword        : Boolean := False)
      return Replay_Result;
   --  Replaying a root (parentless) commit is rejected unless Allow_Root. When
   --  Reword and the commit applies cleanly, the editor is opened to rewrite
   --  the replayed commit's message (git rebase -i "reword").

   procedure Start (Target : String);

   procedure Start_Interactive (Upstream : String);
   --  Interactive rebase onto Upstream: write a "pick <sha> <subject>" todo,
   --  open it in the sequence editor (GIT_SEQUENCE_EDITOR / GIT_EDITOR /
   --  EDITOR), and replay the edited list. Supports pick, drop (removing a
   --  line), and reordering; squash/fixup/reword/edit/exec are rejected.
   --  Replay reuses the same state machine, so --continue/--abort work.

   procedure Start_Root (Onto : String);
   --  rebase --root --onto Onto: replay the whole current branch, including
   --  its root commit, onto Onto. The root commit's base is the empty tree.

   procedure Start_Rebase_Merges (Upstream : String);
   --  rebase --rebase-merges Upstream: replay Upstream..HEAD onto Upstream
   --  topologically, recreating two-parent merge commits to preserve branch
   --  topology. One-shot (aborts on conflict); octopus merges are rejected.

   procedure Continue_Rebase;
   procedure Abort_Rebase;

   function In_Progress return Boolean;
   --  True when a rebase is still in progress after Start_Interactive or
   --  Continue_Rebase returns normally -- i.e. it stopped for an `edit` action
   --  (an intentional, non-error stop) rather than finishing.

end Version.Rebase;
