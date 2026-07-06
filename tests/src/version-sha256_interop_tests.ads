with AUnit;
with Version.Temp_Fixture;

--  End-to-end SHA-256 interop tests: they drive the library against real
--  repositories and cross-check with the system `git` (both directions —
--  git reading version's objects and version reading git's).
package Version.Sha256_Interop_Tests is

   type Test_Case is new Version.Temp_Fixture.Test_Case with null record;

   overriding procedure Register_Tests
     (T : in out Test_Case);

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String;

end Version.Sha256_Interop_Tests;
