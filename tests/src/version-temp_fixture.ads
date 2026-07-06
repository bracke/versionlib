with AUnit.Test_Cases;
with Ada.Strings.Unbounded;

package Version.Temp_Fixture is

   type Test_Case is abstract new AUnit.Test_Cases.Test_Case with private;

   overriding procedure Set_Up
     (T : in out Test_Case);

   overriding procedure Tear_Down
     (T : in out Test_Case);

   function Root
     (T : Test_Case)
      return String;

private

   type Test_Case is abstract new AUnit.Test_Cases.Test_Case with record
      Root_Path : Ada.Strings.Unbounded.Unbounded_String;
      Start_Dir : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Version.Temp_Fixture;