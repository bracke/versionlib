with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Test_Support;

package body Version.Apply.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   procedure Configure_Repo (Root : String) is
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_Repo;

   procedure Modify_Create_Delete
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "l1" & LF & "l2" & LF & "l3" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "del.txt"), "gone" & LF);
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Git_Fixtures.Run (Root, "git commit -qm base");

      --  Produce a real git diff covering modify, create, and delete.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "l1" & LF & "l2-mod" & LF & "l3" & LF & "l4" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "new.txt"), "new" & LF);
      Version.Git_Fixtures.Run (Root, "rm del.txt");
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Git_Fixtures.Run
        (Root, "git diff --cached HEAD > change.patch");
      Version.Git_Fixtures.Run (Root, "git reset -q --hard HEAD");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Patch : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (Root, "change.patch"));
      begin
         Version.Apply.Apply_Patch (Repo, Patch);

         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt"))
            = "l1" & LF & "l2-mod" & LF & "l3" & LF & "l4",
            "apply must produce the modified file content");
         Version.Git_Fixtures.Run (Root, "test -e new.txt");
         Version.Git_Fixtures.Run (Root, "test ! -e del.txt");
      end;
   end Modify_Create_Delete;

   procedure Rejects_Context_Mismatch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Bad  : constant String :=
        "--- a/a.txt" & LF & "+++ b/a.txt" & LF
        & "@@ -1 +1 @@" & LF & "-WRONG" & LF & "+new" & LF;
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "orig" & LF);
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Git_Fixtures.Run (Root, "git commit -qm base");

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         begin
            Version.Apply.Apply_Patch (Repo, Bad);
         exception
            when others =>
               Raised := True;
         end;
         Assert (Raised, "apply must reject a patch whose context mismatches");
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt")) = "orig",
            "rejected apply must not modify the file");
      end;
   end Rejects_Context_Mismatch;

   procedure Reverse_Strip_And_Rename
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Configure_Repo (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "one" & LF & "two" & LF);
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Git_Fixtures.Run (Root, "git commit -qm base");

      --  A modify patch: apply forward, then -R restores the original.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "one" & LF & "TWO" & LF);
      Version.Git_Fixtures.Run (Root, "git diff > mod.patch");
      Version.Git_Fixtures.Run (Root, "git checkout -- a.txt");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Patch : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (Root, "mod.patch"));
      begin
         Version.Apply.Apply_Patch (Repo, Patch);
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt"))
            = "one" & LF & "TWO",
            "forward apply modifies the file");
         Version.Apply.Apply_Patch
           (Repo, Patch, (Reverse_Patch => True, others => <>));
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "a.txt"))
            = "one" & LF & "two",
            "-R apply restores the original content");
      end;

      --  A rename patch: a.txt -> b.txt.
      Version.Git_Fixtures.Run (Root, "git mv a.txt b.txt");
      Version.Git_Fixtures.Run (Root, "git diff --cached -M > ren.patch");
      Version.Git_Fixtures.Run (Root, "git reset -q --hard HEAD");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Patch : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (Root, "ren.patch"));
      begin
         Version.Apply.Apply_Patch (Repo, Patch);
         Version.Git_Fixtures.Run (Root, "test -e b.txt");
         Version.Git_Fixtures.Run (Root, "test ! -e a.txt");
      end;
   end Reverse_Strip_And_Rename;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Modify_Create_Delete'Access,
         "Apply: applies a git diff (modify, create, delete)");
      Register_Routine
        (T, Rejects_Context_Mismatch'Access,
         "Apply: rejects a context mismatch without mutation");
      Register_Routine
        (T, Reverse_Strip_And_Rename'Access,
         "Apply: -R reverse round-trip and rename patches");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Apply");
   end Name;

end Version.Apply.Tests;
