with AUnit;
with Version.Temp_Fixture;

package Version.Pathspec.Tests is

   --  Pathspec matching opens the surrounding repository to resolve
   --  .gitattributes, so each routine runs inside a throwaway git repo.
   type Test_Case is new Version.Temp_Fixture.Test_Case with null record;

   overriding procedure Set_Up
     (T : in out Test_Case);

   overriding procedure Register_Tests
     (T : in out Test_Case);

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String;

end Version.Pathspec.Tests;
