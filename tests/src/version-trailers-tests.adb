with AUnit.Assertions;
with AUnit.Test_Cases;

package body Version.Trailers.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function One (S : String) return String_Vectors.Vector is
      V : String_Vectors.Vector;
   begin
      V.Append (S);
      return V;
   end One;

   procedure Appends_To_Existing_Block
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Input : constant String :=
        "subject" & LF & LF & "body" & LF & LF & "Signed-off-by: A" & LF;
   begin
      Assert
        (Interpret (Input, One ("Reviewed-by: B"))
         = "subject" & LF & LF & "body" & LF & LF
           & "Signed-off-by: A" & LF & "Reviewed-by: B" & LF,
         "trailer appended to the existing block");
   end Appends_To_Existing_Block;

   procedure Opens_New_Block
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  A subject-only message gets a fresh trailer paragraph.
      Assert
        (Interpret ("subject" & LF, One ("Helped-by: D"))
         = "subject" & LF & LF & "Helped-by: D" & LF,
         "new trailer block opened after a blank line");
      --  A sole trailer-looking paragraph is the subject, not a block.
      Assert
        (Interpret ("Signed-off-by: A" & LF, One ("X: 1"))
         = "Signed-off-by: A" & LF & LF & "X: 1" & LF,
         "the first paragraph is never a trailer block");
   end Opens_New_Block;

   procedure Normalises_Separator
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Input : constant String := "subject" & LF & LF & "Signed-off-by: A" & LF;
   begin
      Assert
        (Interpret (Input, One ("ack=E"))
         = Input & "ack: E" & LF,
         "'=' separator normalises to ': '");
      Assert
        (Interpret (Input, One ("Fixes:"))
         = Input & "Fixes: " & LF,
         "empty value keeps the ': ' separator");
   end Normalises_Separator;

   procedure Only_Trailers_And_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Interpret
           ("s" & LF & LF & "b" & LF & LF & "Signed-off-by: A" & LF
            & "Acked-by: B" & LF,
            Only_Trailers => True)
         = "Signed-off-by: A" & LF & "Acked-by: B" & LF,
         "only-trailers extracts the block");
      --  --parse folds continuation lines.
      Assert
        (Interpret
           ("s" & LF & LF & "b" & LF & LF & "fold: a" & LF & " b" & LF,
            Only_Trailers => True, Only_Input => True, Unfold => True)
         = "fold: a b" & LF,
         "parse unfolds continuation lines");
   end Only_Trailers_And_Parse;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Appends_To_Existing_Block'Access,
         "Interpret appends into an existing trailer block");
      Register_Routine
        (T, Opens_New_Block'Access,
         "Interpret opens a new trailer block when needed");
      Register_Routine
        (T, Normalises_Separator'Access,
         "Interpret normalises the trailer separator");
      Register_Routine
        (T, Only_Trailers_And_Parse'Access,
         "Interpret supports --only-trailers and --parse");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Trailers");
   end Name;

end Version.Trailers.Tests;
