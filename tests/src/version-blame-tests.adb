with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;
with Version.Write;

package body Version.Blame.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Attributes_Lines
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "l1" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c1");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "l1" & LF & "l2" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c2");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         C1 : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1");
         C2 : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Lines : constant Version.Blame.Blame_Vectors.Vector :=
           Version.Blame.Blame_File (Repo, C2, "f.txt");
      begin
         Assert (Natural (Lines.Length) = 2, "two lines blamed");
         Assert (To_String (Lines.Element (1).Text) = "l1"
                 and then Lines.Element (1).Commit = C1,
                 "first line attributed to the introducing commit c1");
         Assert (To_String (Lines.Element (2).Text) = "l2"
                 and then Lines.Element (2).Commit = C2,
                 "second line attributed to c2");
      end;
   end Attributes_Lines;

   --  Adding a second copy of an existing line: the new copy must be blamed to
   --  the adding commit, not merged with the original by content (which the
   --  old set-membership blame did). Verifies position-aware line tracking.
   procedure Tracks_Added_Duplicate_Line
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "x" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c1");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "x" & LF & "x" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("c2");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         C1    : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1");
         C2    : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
         Lines : constant Version.Blame.Blame_Vectors.Vector :=
           Version.Blame.Blame_File (Repo, C2, "f.txt");
      begin
         Assert (Natural (Lines.Length) = 2, "two lines blamed");
         Assert (Lines.Element (1).Commit = C1,
                 "the original line is blamed to c1");
         Assert (Lines.Element (2).Commit = C2,
                 "the added duplicate line is blamed to c2 (not merged by "
                 & "content)");
      end;
   end Tracks_Added_Duplicate_Line;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Attributes_Lines'Access,
         "Blame: attributes each line to its introducing commit");
      Register_Routine
        (T, Tracks_Added_Duplicate_Line'Access,
         "Blame: an added duplicate line is tracked by position, not content");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Blame");
   end Name;

end Version.Blame.Tests;
