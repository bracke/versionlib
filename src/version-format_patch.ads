with Version.Objects;
with Version.Repository;
with Version.History;

--  `git format-patch`: render a commit as an mbox "From " record (email-format
--  patch file) that `git am` (and Version.Am) can apply. No email is sent.
package Version.Format_Patch is

   --  Numbering of the "[PATCH n/m]" subject tag: Auto is git's default (a
   --  bare "[PATCH]" for a lone patch, "[PATCH n/m]" for a series); On forces
   --  the "n/m" even for a single patch (-n/--numbered), Off suppresses it
   --  (-N/--no-numbered).
   type Numbering_Mode is (Auto, On, Off);

   function Patch_For_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Number       : Positive := 1;
      Total        : Positive := 1;
      Prefix       : String := "PATCH";
      Numbering    : Numbering_Mode := Auto;
      Reroll       : Natural := 0;
      Emit_Signature : Boolean := True;
      Signature    : String := "2.54.0";
      Context      : Natural := 3;
      Show_Summary : Boolean := True;
      Message_Id   : String := "";
      In_Reply_To  : String := "")
      return String;
   --  Message_Id (git's --thread) is this patch's id without the angle
   --  brackets, emitted as "Message-ID: <...>" right after the "From <sha>"
   --  line; In_Reply_To, when set, adds "In-Reply-To:" and "References:"
   --  headers naming the id this patch threads under.
   --  The mbox text for one commit: a "From <sha> Mon Sep 17 ..." line, From:/
   --  Date: (RFC2822, author date) / Subject: "[<prefix> [vN] n/m]" headers,
   --  the commit body, then the unified diff against the first parent and a
   --  "-- \n<signature>" trailer (omitted when Emit_Signature is False).
   --  Prefix is git's --subject-prefix ("PATCH" by default, "RFC PATCH" for
   --  --rfc); Reroll is -v<N>'s version number (0 = none).

   function Cover_Letter
     (Repo         : Version.Repository.Repository_Handle;
      Commits      : Version.History.Commit_Id_Vectors.Vector;
      Total        : Positive;
      Prefix       : String := "PATCH";
      Numbering    : Numbering_Mode := Auto;
      Reroll       : Natural := 0;
      Context      : Natural := 3;
      Show_Summary : Boolean := True)
      return String
     with Pre => not Commits.Is_Empty;
   --  git's `--cover-letter` message 0: a "From <tip>" line, the committer's
   --  From:/Date:, a "[<prefix> [vN] 0/Total] *** SUBJECT HERE ***" subject and
   --  a "*** BLURB HERE ***" body, then the series shortlog (grouped by author)
   --  and the cumulative diffstat from the base (the oldest commit's first
   --  parent) to the tip. Commits is the series oldest first; Total is the
   --  patch count. The trailing blank line separating the cover from the first
   --  patch is the caller's to add, as between any two mbox messages.

end Version.Format_Patch;
