with Version.Repository;

--  `git am`: apply a series of patches from an mbox (as produced by
--  format-patch), committing each with its recorded authorship. No email is
--  involved; the mbox is just the patch container.
package Version.Am is

   procedure Apply_Mailbox
     (Repo    : Version.Repository.Repository_Handle;
      Mailbox : String);
   --  Split Mailbox into one-commit "From " records and, for each, apply the
   --  diff to the working tree and index and create a commit on the current
   --  branch using the patch's author (name/email/date) and message.
   --  Raises Ada.IO_Exceptions.Data_Error if a patch does not apply.

end Version.Am;
