with AUnit.Assertions;
with AUnit.Test_Cases;

package body Version.Ref_Names.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Check_Ref_Format_Grammar
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  Valid names (git check-ref-format returns 0).
      Assert (Is_Valid_Check_Ref_Format ("heads/main"), "two-level ok");
      Assert (Is_Valid_Check_Ref_Format ("refs/heads/main"), "refs ok");
      Assert (Is_Valid_Check_Ref_Format ("refs/heads/@"), "@ component ok");
      Assert (Is_Valid_Check_Ref_Format ("refs/heads./x"),
              "component ending '.' is ok");
      Assert (Is_Valid_Check_Ref_Format ("refs/heads/x.locky"),
              ".locky suffix ok");

      --  Invalid names.
      Assert (not Is_Valid_Check_Ref_Format ("main"), "one level rejected");
      Assert (Is_Valid_Check_Ref_Format ("main", Allow_Onelevel => True),
              "one level ok with allow-onelevel");
      Assert (not Is_Valid_Check_Ref_Format ("@"), "bare @ rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/.hidden"),
              "leading dot component rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo..bar"),
              "double dot rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo.lock"),
              ".lock suffix rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo."),
              "trailing dot rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo bar"),
              "space rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo~1"),
              "tilde rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo@{1}"),
              "@{ rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads//foo"),
              "empty component rejected");
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/foo/"),
              "trailing slash rejected");
   end Check_Ref_Format_Grammar;

   procedure Refspec_Pattern_And_Normalize
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Valid_Check_Ref_Format ("refs/heads/*"),
              "'*' rejected without refspec-pattern");
      Assert (Is_Valid_Check_Ref_Format
                ("refs/heads/*", Refspec_Pattern => True),
              "single '*' ok with refspec-pattern");
      Assert (not Is_Valid_Check_Ref_Format
                ("refs/heads/**", Refspec_Pattern => True),
              "double '*' rejected");

      Assert (Normalize_Ref_Format ("refs/heads//foo") = "refs/heads/foo",
              "collapses double slash");
      Assert (Normalize_Ref_Format ("/refs/heads/foo") = "refs/heads/foo",
              "drops leading slash");
      Assert (Normalize_Ref_Format ("refs/heads/foo///bar")
              = "refs/heads/foo/bar",
              "collapses slash runs");
   end Refspec_Pattern_And_Normalize;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Check_Ref_Format_Grammar'Access,
         "Is_Valid_Check_Ref_Format matches git's grammar");
      Register_Routine
        (T, Refspec_Pattern_And_Normalize'Access,
         "refspec-pattern glob and --normalize");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Ref_Names");
   end Name;

end Version.Ref_Names.Tests;
