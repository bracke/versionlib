with Ada.Environment_Variables;
with AUnit.Reporter.Text;
with AUnit.Run;
with All_Suites;

procedure Tests is
   procedure Runner is new AUnit.Run.Test_Runner (All_Suites.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
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
   Runner (Reporter);
end Tests;