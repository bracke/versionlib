with AUnit.Test_Cases;

package Version.Hash.Tests is

   type Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding procedure Register_Tests
     (T : in out Test_Case);

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String;

end Version.Hash.Tests;
