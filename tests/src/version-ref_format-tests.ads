with AUnit;
with AUnit.Test_Cases;

package Version.Ref_Format.Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding procedure Register_Tests
     (T : in out Test_Case);

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String;

end Version.Ref_Format.Tests;
