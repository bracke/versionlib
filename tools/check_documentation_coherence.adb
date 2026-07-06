with Ada.Command_Line;
with Ada.Text_IO;

with Project_Tools.Files;
with Project_Tools.Release_Checks;

--  Validate versionlib's own library documentation against its sources.
--  Covers the library-behavior docs that live in versionlib/docs and the
--  contracts they describe (rollback API, hooks, transports, archive,
--  repository format). Runs from the versionlib crate root.
procedure Check_Documentation_Coherence is
   procedure Require_File (Path : String) is
   begin
      Project_Tools.Files.Require_File (Path, "missing library doc: " & Path);
   end Require_File;

   procedure Require_Contains (Path, Needle, Message : String) is
   begin
      if not Project_Tools.Files.File_Contains (Path, Needle) then
         Project_Tools.Release_Checks.Fail (Message);
      end if;
   end Require_Contains;

   Hooks : constant array (Positive range <>) of access constant String :=
     [new String'("pre-commit"), new String'("commit-msg"),
      new String'("post-commit"), new String'("post-checkout"),
      new String'("pre-push")];
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_documentation_coherence");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   --  Library docs exist.
   Require_File ("docs/ARCHITECTURE.md");
   Require_File ("docs/REPOSITORY_FORMAT.md");
   Require_File ("docs/TRANSPORTS.md");
   Require_File ("docs/HOOKS.md");
   Require_File ("docs/MAINTENANCE.md");
   Require_File ("docs/PORTABILITY.md");
   Require_File ("docs/REF_TRANSACTION.md");
   Require_File ("docs/WORKTREES.md");
   Require_File ("docs/SUBMODULES.md");
   Require_File ("docs/ARCHIVE.md");
   Require_File ("docs/CONSTRAINTS.md");
   Require_File ("docs/EDGE_CASE_EXAMPLES.md");

   --  Rollback file-API boundary: documented and implemented.
   Require_Contains
     ("docs/ARCHITECTURE.md", "Version.Files.Rollback",
      "architecture docs missing rollback file API boundary");
   Require_Contains
     ("src/version-files-rollback.ads", "Rollback_Backup_Path",
      "rollback package spec missing backup path contract");

   --  Transport file-URL behavior.
   Require_Contains
     ("docs/TRANSPORTS.md", "%20",
      "transport docs missing file URL percent-decoding behavior");

   --  Hooks: each supported hook is both documented and implemented.
   for Hook of Hooks loop
      Require_Contains
        ("docs/HOOKS.md", Hook.all,
         "HOOKS.md does not document hook " & Hook.all);
      Require_Contains
        ("src/version-hooks.adb", "Name = """ & Hook.all & """",
         "implementation missing supported hook " & Hook.all);
   end loop;

   --  Archive format coverage.
   Require_Contains
     ("docs/ARCHIVE.md", "tar", "archive docs missing tar support");
   Require_Contains
     ("docs/ARCHIVE.md", "zip", "archive docs missing zip support");

   --  Unsupported scope is documented.
   Require_Contains
     ("docs/EDGE_CASE_EXAMPLES.md", "SHA-256",
      "edge-case docs do not mention SHA-256 unsupported scope");

   Ada.Text_IO.Put_Line ("documentation coherence checks passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;  -- a Require_* / Fail already set the failure exit status
end Check_Documentation_Coherence;
