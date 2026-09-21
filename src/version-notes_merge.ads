with Ada.Strings.Unbounded;

with Version.Notes;
with Version.Objects;
with Version.Ref_Format;
with Version.Repository;

--  `git notes merge`: a port of git's notes-merge.c. Two notes commits are
--  merged note by note against their merge base; a note changed on both
--  sides is resolved by the strategy, and under the manual strategy is
--  written with conflict markers to .git/NOTES_MERGE_WORKTREE/<object>
--  while the partial result is parked in NOTES_MERGE_PARTIAL (a commit)
--  and NOTES_MERGE_REF (a symref to the ref being merged into) until
--  `merge --commit` or `merge --abort`.
package Version.Notes_Merge is

   use Ada.Strings.Unbounded;

   type Strategy is (Manual, Ours, Theirs, Union, Cat_Sort_Uniq);

   function Parse_Strategy
     (Text : String; Result : out Strategy) return Boolean;
   --  git's parse_notes_merge_strategy: the lower-case names; False when
   --  Text is none of them.

   Default_Verbosity : constant Integer := 2;
   --  git's NOTES_MERGE_VERBOSITY_DEFAULT; -q lowers it, each -v raises it.

   Unconcluded_Merge_Key : constant String :=
     "You have not concluded your previous notes merge (.git/NOTES_MERGE_* exists).";
   Unconcluded_Merge_Message : constant String :=
     Unconcluded_Merge_Key & Character'Val (10)
     & "Please, use 'git notes merge --commit' or 'git notes merge --abort' to "
     & "commit/abort the previous merge before you start a new notes merge.";
   --  Merge raises Notes_Error with the Key (first line) when a previous
   --  merge's worktree is still populated; callers print the full Message.

   type Merge_Options is record
      Local_Ref  : Unbounded_String;   --  the notes ref merged into
      Remote_Ref : Unbounded_String;   --  the notes ref (or commit) merged
      Strategy   : Notes_Merge.Strategy := Manual;
      Verbosity  : Integer := Default_Verbosity;
      Commit_Msg : Unbounded_String;   --  "Merged notes from X into Y"
   end record;

   --  git's notes_merge return value: 0 (trivial: the result is an
   --  existing commit), 1 (a merge commit was created), -1 (conflicts:
   --  the partial merge commit awaits `merge --commit`).
   type Merge_Result is (Trivial, Merged, Conflicted);

   procedure Merge
     (Repo      : Version.Repository.Repository_Handle;
      Options   : in out Merge_Options;
      Local     : in out Version.Notes.Notes_Tree;
      Result_Id : out Version.Objects.Hex_Object_Id;
      Result    : out Merge_Result;
      Output    : in out Unbounded_String;
      Warnings  : in out Version.Ref_Format.String_Vectors.Vector);
   --  git's notes_merge. Local is the tree of Options.Local_Ref (updated to
   --  the merge result, conflicting notes removed). Output collects what git
   --  prints on stdout at the configured verbosity, Warnings the lines it
   --  sends to stderr as warnings. Raises Version.Notes.Notes_Error with
   --  git's text for the conditions git dies on; Output is still valid then.

   procedure Record_Partial_Merge
     (Repo      : Version.Repository.Repository_Handle;
      Result_Id : Version.Objects.Hex_Object_Id;
      Notes_Ref : String);
   --  After a Conflicted merge: store the partial commit in
   --  NOTES_MERGE_PARTIAL and point NOTES_MERGE_REF at Notes_Ref. Raises
   --  Notes_Error when a notes merge into Notes_Ref is already in progress.

   function Worktree_Path
     (Repo : Version.Repository.Repository_Handle) return String;
   --  .git/NOTES_MERGE_WORKTREE as git names it in messages.

   procedure Merge_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Options   : Merge_Options;
      Result_Id : out Version.Objects.Hex_Object_Id;
      Output    : in out Unbounded_String);
   --  git's merge_commit: finalize the partial merge from the worktree's
   --  resolved notes, advance NOTES_MERGE_REF's target, and clear the
   --  merge state. Raises Notes_Error when no merge is in progress.

   procedure Clear_Merge_State
     (Repo     : Version.Repository.Repository_Handle;
      Options  : Merge_Options;
      Output   : in out Unbounded_String;
      Errors   : in out Version.Ref_Format.String_Vectors.Vector);
   --  git's merge_abort: delete NOTES_MERGE_PARTIAL and NOTES_MERGE_REF and
   --  empty the worktree (the directory itself stays). Each failure adds
   --  git's error line to Errors.

end Version.Notes_Merge;
