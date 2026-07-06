with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;

package body Version.Pathspec.Tests is

   use AUnit.Assertions;

   overriding procedure Set_Up
     (T : in out Test_Case)
   is
   begin
      --  Create the temp dir and save the caller's working directory.
      Version.Temp_Fixture.Set_Up (Version.Temp_Fixture.Test_Case (T));
      --  Make it a repository and enter it so Pathspec.Matches can open it.
      Version.Git_Fixtures.Run (T.Root, "git init -q");
      Ada.Directories.Set_Directory (T.Root);
   end Set_Up;

   procedure Assert_Matches
     (Spec : String;
      Path : String;
      Msg  : String)
   is
      Item : constant Version.Pathspec.Pathspec_Item :=
        Version.Pathspec.Parse (Spec);
   begin
      Assert (Version.Pathspec.Matches (Item, Path), Msg);
   end Assert_Matches;

   procedure Assert_Not_Matches
     (Spec : String;
      Path : String;
      Msg  : String)
   is
      Item : constant Version.Pathspec.Pathspec_Item :=
        Version.Pathspec.Parse (Spec);
   begin
      Assert (not Version.Pathspec.Matches (Item, Path), Msg);
   end Assert_Not_Matches;

   procedure Literal_Exact_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("src/main.adb", "src/main.adb", "literal file must match itself");
      Assert_Not_Matches ("src/main.adb", "src/other.adb", "literal file must not match sibling");
   end Literal_Exact_File;

   procedure Literal_Directory_Selects_Descendants
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("src/", "src/a.adb", "trailing slash directory must match child");
      Assert_Matches ("src", "src/nested/a.adb", "literal directory name must match descendant candidate");
      Assert_Not_Matches ("src/", "other/a.adb", "directory path must not match unrelated tree");
   end Literal_Directory_Selects_Descendants;

   procedure Star_Glob_Basename
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("*.adb", "main.adb", "basename glob must match root file");
      Assert_Matches ("*.adb", "src/main.adb", "basename glob must match nested file basename");
      Assert_Not_Matches ("*.adb", "src/main.ads", "basename glob must reject wrong suffix");
   end Star_Glob_Basename;

   procedure Question_Glob
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("file?.txt", "dir/file1.txt", "question must match one basename char");
      Assert_Not_Matches ("file?.txt", "dir/file10.txt", "question must not match two chars");
   end Question_Glob;

   procedure Slash_Glob_One_Level
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("src/*.adb", "src/main.adb", "slash glob must match one level");
      Assert_Not_Matches ("src/*.adb", "src/nested/main.adb", "single star must not cross slash");
   end Slash_Glob_One_Level;

   procedure Recursive_Glob
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches ("src/**/*.adb", "src/main.adb", "recursive glob must allow zero directory levels");
      Assert_Matches ("src/**/*.adb", "src/nested/main.adb", "recursive glob must cross slash");
   end Recursive_Glob;

   procedure Magic_Forms
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Matches (":(top)README.md", "README.md", "top magic must parse");
      Assert_Matches (":/README.md", "README.md", "short top magic must parse");
      Assert_Matches
        (":(top,literal)README*", "README*",
         "combined top and literal magic must parse");
      Assert_Matches (":(literal)src/*.adb", "src/*.adb", "literal magic must disable glob");
      Assert_Not_Matches (":(literal)src/*.adb", "src/main.adb", "literal magic must not glob");
      Assert_Matches (":(glob)src/**/*.adb", "src/nested/main.adb", "glob magic must enable glob");
      Assert_Matches (":(top,glob)*.md", "README.md", "top glob must match root file");
      Assert_Not_Matches
        (":(top,glob)*.md", "docs/README.md",
         "top glob must not match nested basename");
   end Magic_Forms;

   procedure Exclusion_Semantics
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Items : Version.Pathspec.Pathspec_Vectors.Vector;
      Only_Exclusion : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Pathspec.Append_Parse (Items, "*.adb");
      Version.Pathspec.Append_Parse (Items, ":!generated/");
      Assert (Version.Pathspec.Matches_Any (Items, "src/main.adb"), "positive glob should select non-excluded file");
      Assert (not Version.Pathspec.Matches_Any (Items, "generated/main.adb"), "exclude must remove matched path");

      Version.Pathspec.Append_Parse (Only_Exclusion, ":^generated/");
      Assert
        (Version.Pathspec.Matches_Any (Only_Exclusion, "src/main.adb"),
         "only exclusion starts from all candidates");
      Assert
        (not Version.Pathspec.Matches_Any
           (Only_Exclusion, "generated/main.adb"),
         "only exclusion removes excluded candidates");

      Only_Exclusion.Clear;
      Version.Pathspec.Append_Parse (Only_Exclusion, ":(exclude)generated/");
      Assert
        (not Version.Pathspec.Matches_Any
           (Only_Exclusion, "generated/main.adb"),
         "long exclude magic must remove excluded candidates");
   end Exclusion_Semantics;

   procedure Rejects_Backslash_Pathspecs_With_Stable_Diagnostic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      procedure Assert_Backslash_Rejected (Spec, Original : String) is
         Raised : Boolean := False;
      begin
         begin
            declare
               Item : constant Version.Pathspec.Pathspec_Item :=
                 Version.Pathspec.Parse (Spec);
               pragma Unreferenced (Item);
            begin
               null;
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Pathspec.Backslash_Separator_Diagnostic (Original),
                  "backslash pathspec diagnostic must remain stable");
         end;

         Assert (Raised, "backslash pathspec must be rejected");
      end Assert_Backslash_Rejected;
   begin
      Assert_Backslash_Rejected ("src\main.adb", "src\main.adb");
      Assert_Backslash_Rejected
        (":(literal)src\main.adb", ":(literal)src\main.adb");
      Assert_Backslash_Rejected (":/src\main.adb", ":/src\main.adb");
   end Rejects_Backslash_Pathspecs_With_Stable_Diagnostic;

   procedure Rejects_Invalid_Pathspecs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      procedure Assert_Rejected (Spec, Expected : String) is
         Raised : Boolean := False;
      begin
         begin
            declare
               Item : constant Version.Pathspec.Pathspec_Item :=
                 Version.Pathspec.Parse (Spec);
               pragma Unreferenced (Item);
            begin
               null;
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E) = Expected,
                  "pathspec diagnostic must remain stable for " & Spec);
         end;

         Assert (Raised, "invalid pathspec must be rejected: " & Spec);
      end Assert_Rejected;
   begin
      Assert_Rejected
        ("", Version.Pathspec.Empty_Pathspec_Diagnostic);
      Assert_Rejected
        (":(icase)a.txt", Version.Pathspec.Unknown_Magic_Diagnostic ("icase"));
      declare
         Attr_Item : constant Version.Pathspec.Pathspec_Item :=
           Version.Pathspec.Parse (":(attr:generated)a.txt");
      begin
         Assert
           (Version.Pathspec.To_Text (Attr_Item) = ":(attr:generated)a.txt",
            "attr pathspec magic must round-trip");
      end;
      Assert_Rejected
        (":(from-file:paths.txt)a.txt",
         Version.Pathspec.Unknown_Magic_Diagnostic ("from-file:paths.txt"));
      Assert_Rejected
        ("../x", Version.Pathspec.Traversal_Component_Diagnostic ("../x"));
      Assert_Rejected
        ("a/../x", Version.Pathspec.Traversal_Component_Diagnostic ("a/../x"));
      Assert_Rejected
        ("./x", Version.Pathspec.Current_Directory_Component_Diagnostic ("./x"));
      Assert_Rejected
        (".git/config", Version.Pathspec.Git_Dir_Component_Diagnostic (".git/config"));
      Assert_Rejected
        ("a//b", Version.Pathspec.Empty_Component_Diagnostic ("a//b"));
      Assert_Rejected
        (":(literal", Version.Pathspec.Malformed_Magic_Diagnostic (":(literal"));
      Assert_Rejected
        (":(top,)README.md", Version.Pathspec.Empty_Magic_Diagnostic);
      Assert_Rejected
        (":/", Version.Pathspec.Empty_Pathspec_Diagnostic (":/"));
      Assert_Rejected
        ("/tmp/a.txt", Version.Pathspec.Absolute_Pathspec_Diagnostic ("/tmp/a.txt"));
      Assert_Rejected
        ("C:tmp", Version.Pathspec.Absolute_Pathspec_Diagnostic ("C:tmp"));
      Assert_Rejected
        ("src" & Character'Val (0) & "main.adb",
         Version.Pathspec.NUL_Diagnostic);
      Assert_Rejected
        ("src" & Character'Val (1) & "main.adb",
         Version.Pathspec.Control_Character_Diagnostic);
   end Rejects_Invalid_Pathspecs;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine (T, Literal_Exact_File'Access,
        "Pathspec: literal exact file");
      AUnit.Test_Cases.Registration.Register_Routine (T, Literal_Directory_Selects_Descendants'Access,
        "Pathspec: literal directory selects descendants");
      AUnit.Test_Cases.Registration.Register_Routine (T, Star_Glob_Basename'Access,
        "Pathspec: star glob basename");
      AUnit.Test_Cases.Registration.Register_Routine (T, Question_Glob'Access,
        "Pathspec: question glob");
      AUnit.Test_Cases.Registration.Register_Routine (T, Slash_Glob_One_Level'Access,
        "Pathspec: slash glob one level");
      AUnit.Test_Cases.Registration.Register_Routine (T, Recursive_Glob'Access,
        "Pathspec: recursive glob");
      AUnit.Test_Cases.Registration.Register_Routine (T, Magic_Forms'Access,
        "Pathspec: top/literal/glob magic");
      AUnit.Test_Cases.Registration.Register_Routine (T, Exclusion_Semantics'Access,
        "Pathspec: exclusion semantics");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Rejects_Backslash_Pathspecs_With_Stable_Diagnostic'Access,
         "Pathspec: backslash rejection diagnostic");
      AUnit.Test_Cases.Registration.Register_Routine (T, Rejects_Invalid_Pathspecs'Access,
        "Pathspec: invalid pathspec rejection");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Pathspec");
   end Name;

end Version.Pathspec.Tests;
