with AUnit.Assertions;

package body Version.Ref_Format.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Check (Ident, Modifier, Expected : String) is
   begin
      Assert
        (Version.Ref_Format.Git_Date (Ident, Modifier) = Expected,
         "Git_Date (""" & Ident & """, """ & Modifier & """) = """
         & Version.Ref_Format.Git_Date (Ident, Modifier)
         & """ /= """ & Expected & """");
   end Check;

   procedure Test_Git_Date
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  Vectors captured from `git for-each-ref --format='%(authordate...)'`.
      Check ("1600000000 +0200", "",           "Sun Sep 13 14:26:40 2020 +0200");
      Check ("1600000000 +0200", "iso",         "2020-09-13 14:26:40 +0200");
      Check ("1600000000 +0200", "iso-strict",  "2020-09-13T14:26:40+02:00");
      Check ("1600000000 +0200", "short",       "2020-09-13");
      Check ("1600000000 +0200", "unix",        "1600000000");
      Check ("1600000000 +0200", "raw",         "1600000000 +0200");

      Check ("1610000000 -0500", "",            "Thu Jan 7 01:13:20 2021 -0500");
      Check ("1610000000 -0500", "iso",         "2021-01-07 01:13:20 -0500");
      Check ("1610000000 -0500", "iso-strict",  "2021-01-07T01:13:20-05:00");

      Check ("1000000000 +0000", "",            "Sun Sep 9 01:46:40 2001 +0000");
      Check ("1000000000 +0000", "short",       "2001-09-09");
   end Test_Git_Date;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Test_Git_Date'Access, "Git_Date matches git date atoms");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Ref_Format");
   end Name;

end Version.Ref_Format.Tests;
