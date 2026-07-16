with AUnit;
with Version.Temp_Fixture;

package Version.Attributes.Tests is

   type Test_Case is new Version.Temp_Fixture.Test_Case with null record;

   overriding procedure Register_Tests
     (T : in out Test_Case);

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String;

end Version.Attributes.Tests;
