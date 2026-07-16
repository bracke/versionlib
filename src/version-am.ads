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
   --  resolve and then Continue, Skip, or Abort_Am.

   procedure Apply_Mailbox
     (Repo    : Version.Repository.Repository_Handle;
      Mailbox : String);
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

   function In_Progress
     (Repo : Version.Repository.Repository_Handle) return Boolean;
   --  True when an am session is interrupted (`.git/rebase-apply` exists).

end Version.Am;
