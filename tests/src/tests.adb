with Ada.Command_Line;
with AUnit;
with Ada.Environment_Variables;
with AUnit.Reporter.Text;
with AUnit.Run;
with All_Suites;

--  AUnit's plain Test_Runner reports success however many assertions
--  failed, so a build server ticks a job green over a failing suite.
--  The outcome is carried in the exit status here instead.
procedure Tests is
   use type AUnit.Status;

   function Runner is new AUnit.Run.Test_Runner_With_Status (All_Suites.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
   Status   : AUnit.Status;
begin
   --  Run hermetically: now that Version.Config reads git's full system/global
   --  config stack, keep the developer's ambient ~/.gitconfig and
   --  /etc/gitconfig out of the picture so config-dependent behaviour is
   --  reproducible. The fixtures' real git still needs init.defaultBranch=main
   --  (many assume it), which we inject via GIT_CONFIG_COUNT — git honours it,
   --  while Version.Config does not read that channel, so version's own config
   --  view stays clean. Tests that need global config set their own
   --  GIT_CONFIG_GLOBAL.
   Ada.Environment_Variables.Set ("GIT_CONFIG_NOSYSTEM", "1");
   Ada.Environment_Variables.Set ("GIT_CONFIG_GLOBAL", "/dev/null");
   Ada.Environment_Variables.Clear ("GIT_CONFIG_SYSTEM");
   Ada.Environment_Variables.Set ("GIT_CONFIG_COUNT", "1");
   Ada.Environment_Variables.Set ("GIT_CONFIG_KEY_0", "init.defaultBranch");
   Ada.Environment_Variables.Set ("GIT_CONFIG_VALUE_0", "main");
   Status := Runner (Reporter);

   if Status /= AUnit.Success then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Tests;