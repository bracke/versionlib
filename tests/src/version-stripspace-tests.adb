with AUnit.Assertions;
with AUnit.Test_Cases;

package body Version.Stripspace.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Default_Cleanup
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  Trailing whitespace stripped, blank runs collapsed, edges trimmed.
      Assert
        (Clean ("a  " & LF & LF & LF & "b" & LF & LF)
         = "a" & LF & LF & "b" & LF,
         "default collapses blanks and strips trailing whitespace");
      Assert (Clean ("x") = "x" & LF, "a non-empty result is newline-ended");
      Assert (Clean ("") = "", "empty input yields empty output");
      Assert (Clean (LF & LF & LF) = "", "all-blank input yields empty output");
   end Default_Cleanup;

   procedure Strip_Comments_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Clean
           ("# c" & LF & "text" & LF & "# d" & LF, Strip_Comments)
         = "text" & LF,
         "comment lines are removed");
      Assert
        (Clean ("  # kept" & LF & "text" & LF, Strip_Comments)
         = "  # kept" & LF & "text" & LF,
         "an indented '#' is not a comment");
   end Strip_Comments_Mode;

   procedure Comment_Lines_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Clean ("hello" & LF & LF & "world" & LF, Comment_Lines)
         = "# hello" & LF & "#" & LF & "# world" & LF,
         "each line is commented; blank lines become a bare '#'");
      Assert (Clean ("", Comment_Lines) = "", "empty input stays empty");
   end Comment_Lines_Mode;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Default_Cleanup'Access, "stripspace default cleanup");
      Register_Routine
        (T, Strip_Comments_Mode'Access, "stripspace --strip-comments");
      Register_Routine
        (T, Comment_Lines_Mode'Access, "stripspace --comment-lines");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Stripspace");
   end Name;

end Version.Stripspace.Tests;
