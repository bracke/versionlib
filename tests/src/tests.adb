with AUnit.Reporter.Text;
with AUnit.Run;
with All_Suites;

procedure Tests is
   procedure Runner is new AUnit.Run.Test_Runner (All_Suites.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
begin
   Runner (Reporter);
end Tests;