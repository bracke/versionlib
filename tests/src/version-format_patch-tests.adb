with Version.Objects;
with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Init;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Format_Patch.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function Contains (Haystack, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Haystack, Needle) /= 0);

   procedure Patch_Has_Headers_And_Diff
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email a@b.c");
      Version.Git_Fixtures.Run (Root, "git config user.name ""A U Thor""");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "l1" & LF & "l2" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("first commit");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"),
         "l1" & LF & "l2" & LF & "l3" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("second commit");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Patch : constant String :=
           Version.Format_Patch.Patch_For_Commit (Repo, Head, 1, 1);
      begin
         Assert (Patch'Length > 6
                 and then Patch (Patch'First .. Patch'First + 4) = "From ",
                 "patch must begin with an mbox From line");
         Assert (Contains (Patch, "From " & To_String (Head)),
                 "From line must carry the commit id");
         Assert (Contains (Patch, "From: A U Thor <a@b.c>"),
                 "patch must carry the author identity");
         Assert (Contains (Patch, "Subject: [PATCH] second commit"),
                 "patch subject must be the commit subject");
         Assert (Contains (Patch, "@@"),
                 "patch must contain a hunk header");
         Assert (Contains (Patch, LF & "+l3" & LF),
                 "patch must contain the added line");
         Assert (Contains (Patch, LF & "-- " & LF),
                 "patch must end with an mbox signature separator");
      end;
   end Patch_Has_Headers_And_Diff;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Patch_Has_Headers_And_Diff'Access,
         "Format_Patch: mbox record has headers, subject, and diff");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Format_Patch");
   end Name;

end Version.Format_Patch.Tests;
