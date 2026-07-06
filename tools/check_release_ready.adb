with Ada.Command_Line;
with Ada.Text_IO;

with Project_Tools.Processes;

--  Self-contained release preflight for the versionlib crate: build the
--  library, build and run its AUnit suite, and run versionlib's own
--  verification checks. Runs from the versionlib crate root and does not
--  depend on the version (CLI) crate.
procedure Check_Release_Ready is
   procedure Step (Label, Command : String) is
   begin
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("==> " & Label);
      if Project_Tools.Processes.Run_Shell (Command) /= 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "versionlib release preflight failed during " & Label);
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
         raise Program_Error;
      end if;
   end Step;
begin
   if Ada.Command_Line.Argument_Count /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "usage: check_release_ready");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Step ("check release manifests", "tools/bin/check_release_manifests");
   Step ("build versionlib", "alr build");
   Step ("build test suite",
         "cd tests && alr exec -- gprbuild -P versionlib_tests.gpr");
   Step ("run test suite", "./tests/bin/tests");
   Step ("check ref write policy", "tools/bin/check_ref_write_policy");
   Step ("check version metadata", "tools/bin/check_version_metadata");
   Step ("check test-scope completeness",
         "tools/bin/check_test_scope_completeness");
   Step ("check documentation coherence",
         "tools/bin/check_documentation_coherence");

   Ada.Text_IO.Put_Line ("versionlib release preflight passed");
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
exception
   when Program_Error =>
      null;  -- a step already set the failure exit status
end Check_Release_Ready;
