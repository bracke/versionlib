with Version.Objects;
with Version.Repository;

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
      Show_Summary : Boolean := True)
      return String;
   --  The mbox text for one commit: a "From <sha> Mon Sep 17 ..." line, From:/
   --  Date: (RFC2822, author date) / Subject: "[<prefix> [vN] n/m]" headers,
   --  the commit body, then the unified diff against the first parent and a
   --  "-- \n<signature>" trailer (omitted when Emit_Signature is False).
   --  Prefix is git's --subject-prefix ("PATCH" by default, "RFC PATCH" for
   --  --rfc); Reroll is -v<N>'s version number (0 = none).

end Version.Format_Patch;
