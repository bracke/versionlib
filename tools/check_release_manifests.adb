with Ada.Command_Line;
with Ada.Text_IO;

with Project_Tools.Alire_Manifests.Validation;
with Project_Tools.Files;

--  Validate versionlib's own development manifest: it must keep the intentional
--  local path pins for its sibling dependencies (those pins are stripped for
--  publication). Independent of the version (CLI) crate.
procedure Check_Release_Manifests is
   package Validation renames Project_Tools.Alire_Manifests.Validation;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_release_manifests");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Validation.Require_Workspace_Pin ("alire.toml", "httpclient", "../HttpClient");
   Validation.Require_Workspace_Pin ("alire.toml", "zlib", "../zlib");
   Validation.Require_Workspace_Pin ("alire.toml", "i18n", "../i18n");
   Validation.Require_Workspace_Pin ("alire.toml", "ssh_lib", "../sshlib");
   Project_Tools.Files.Require_Contains
     ("alire.toml",
      "gnat_native = ""=15.2.1""",
      "root manifest must pin gnat_native = ""=15.2.1""");
   Project_Tools.Files.Require_Contains
     ("tests/alire.toml",
      "gnat_native = ""=15.2.1""",
      "tests manifest must pin gnat_native = ""=15.2.1""");
   Project_Tools.Files.Require_Contains
     ("tools/alire.toml",
      "gnat_native = ""=15.2.1""",
      "tools manifest must pin gnat_native = ""=15.2.1""");

   Ada.Text_IO.Put_Line ("release manifest checks passed");
exception
   when Program_Error =>
      null;  -- a Require_* helper already set the failure exit status
end Check_Release_Manifests;
