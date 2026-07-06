with Version.Objects;
with Version.Repository;

--  `git format-patch`: render a commit as an mbox "From " record (email-format
--  patch file) that `git am` (and Version.Am) can apply. No email is sent.
package Version.Format_Patch is

   function Patch_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Number    : Positive := 1;
      Total     : Positive := 1)
      return String;
   --  The mbox text for one commit: a "From <sha> Mon Sep 17 ..." line, From:/
   --  Date: (RFC2822, author date) / Subject: "[PATCH n/m]" headers, the commit
   --  body, then the unified diff against the first parent and a signature.

end Version.Format_Patch;
