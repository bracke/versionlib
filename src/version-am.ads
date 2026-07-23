with Version.Repository;

--  `git am`: apply a series of patches from an mbox (as produced by
--  format-patch), committing each with its recorded authorship. No email is
--  involved; the mbox is just the patch container. A patch that does not apply
--  leaves an interrupted session under `.git/rebase-apply` that is resolved
--  with Continue / Skip / Abort_Am.
package Version.Am is

   Am_Conflict : exception;
   --  Raised by Apply_Mailbox / Continue / Skip when a patch fails to apply.
   --  The session is left in progress (`.git/rebase-apply`) for the user to
   --  resolve and then Continue, Skip, or Abort_Am. The message is git's
   --  "Patch failed at <NNNN> <subject>" line, which git prints to stdout.

   Am_Empty : exception;
   --  Raised when a mail carries a commit message but no diff (an empty patch).
   --  git stops with "Patch is empty." and leaves the session in progress so
   --  it can be resumed with --allow-empty / --skip / --abort.

   Format_Detection_Failed : exception;
   --  Raised when the input is not a recognisable mailbox or patch at all.
   --  git reports "Patch format detection failed." and applies nothing.

   --  What `am` does with a mail that has no diff, git's `--empty=<mode>`:
   --  Stop (the default) halts with "Patch is empty."; Drop skips it silently
   --  bar a "Skipping:" line; Keep records it as an empty commit.
   type Empty_Action is (Stop, Drop, Keep_Empty);

   --  git's per-session flags. Quiet silences the "Applying: <subject>" line
   --  git prints for each patch; Signoff appends a Signed-off-by trailer;
   --  Keep leaves the subject's "[PATCH]" prefix in place;
   --  Committer_Date_Is_Author_Date dates the commit from the patch rather
   --  than from now; and Empty selects the diff-less-mail behaviour.
   type Am_Options is record
      Quiet   : Boolean := False;
      Signoff : Boolean := False;
      Keep    : Boolean := False;
      Committer_Date_Is_Author_Date : Boolean := False;
      Empty   : Empty_Action := Stop;
   end record;

   procedure Apply_Mailbox
     (Repo    : Version.Repository.Repository_Handle;
      Mailbox : String;
      Options : Am_Options := (others => <>));
   --  Start a new am session: split Mailbox into one-commit records, then apply
   --  and commit each with the patch's recorded author and message. Raises
   --  Am_Conflict (leaving the session in progress) on the first patch that
   --  does not apply.

   procedure Continue
     (Repo : Version.Repository.Repository_Handle);
   --  `git am --continue`: commit the resolved (staged) current patch using its
   --  recorded authorship, then resume applying the remaining patches.

   procedure Skip
     (Repo : Version.Repository.Repository_Handle);
   --  `git am --skip`: discard the current patch (reset to HEAD) and resume.

   procedure Abort_Am
     (Repo : Version.Repository.Repository_Handle);
   --  `git am --abort`: reset HEAD, index and working tree to where the session
   --  started and remove the session state.

   procedure Quit
     (Repo : Version.Repository.Repository_Handle);
   --  `git am --quit`: remove the session state but leave HEAD, index and the
   --  working tree untouched (no reset), unlike Abort_Am.

   function Current_Patch
     (Repo : Version.Repository.Repository_Handle;
      Diff_Only : Boolean) return String;
   --  `git am --show-current-patch[=raw|diff]`: the mail of the patch that
   --  stopped the session (raw, the default) or just its diff (Diff_Only).

   function In_Progress
     (Repo : Version.Repository.Repository_Handle) return Boolean;
   --  True when an am session is interrupted (`.git/rebase-apply` exists).

end Version.Am;
