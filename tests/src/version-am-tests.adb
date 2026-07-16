with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Am.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   LF : constant Character := Character'Val (10);

   function Contains (Haystack, Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Haystack, Needle) /= 0);

   procedure Reconstructs_Commit_From_Git_Patch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email me@here");
      Version.Git_Fixtures.Run (Root, "git config user.name ""Me Here""");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"), "l1" & LF & "l2" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("first");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"),
         "l1" & LF & "l2" & LF & "l3" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "g.txt"), "extra" & LF);
      Version.Git_Fixtures.Run (Root, "git add -A");
      Version.Git_Fixtures.Run
        (Root,
         "GIT_AUTHOR_NAME='Pat Author' GIT_AUTHOR_EMAIL=pat@ex.com "
         & "GIT_AUTHOR_DATE='2020-01-02T03:04:05 +0000' "
         & "git commit -q -m 'second commit'");

      Version.Git_Fixtures.Run
        (Root, "git format-patch -1 HEAD --stdout > c2.mbox");
      Version.Git_Fixtures.Run (Root, "git reset -q --hard HEAD~1");

      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Patch : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (Root, "c2.mbox"));
      begin
         Version.Am.Apply_Mailbox (Repo, Patch);

         --  Working tree restored.
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "f.txt"))
            = "l1" & LF & "l2" & LF & "l3",
            "am must restore the modified file");
         Version.Git_Fixtures.Run (Root, "test -e g.txt");

         --  New commit preserves the patch authorship and subject.
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo)));
            Body_Text : constant String := Version.Objects.Content (Obj);
         begin
            Assert (Contains (Body_Text, "author Pat Author <pat@ex.com>"),
                    "am must preserve the patch author");
            Assert
              (Version.Objects.Commit_Message_First_Line (Obj)
               = "second commit",
               "am must preserve the commit subject");
         end;
      end;
   end Reconstructs_Commit_From_Git_Patch;

   procedure Conflict_Continue_And_Abort
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email me@here");
      Version.Git_Fixtures.Run (Root, "git config user.name ""Me Here""");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"),
         "A" & LF & "B" & LF & "C" & LF);
      Version.Git_Fixtures.Run (Root, "git add f.txt");
      Version.Write.Save ("base");

      --  A patch that changes line B, captured then rolled back.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"),
         "A" & LF & "B-feature" & LF & "C" & LF);
      Version.Git_Fixtures.Run (Root, "git commit -q -am feature");
      Version.Git_Fixtures.Run
        (Root, "git format-patch -1 HEAD --stdout > feat.mbox");
      Version.Git_Fixtures.Run (Root, "git reset -q --hard HEAD~1");

      --  Diverge line B on the current branch so the patch conflicts.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f.txt"),
         "A" & LF & "B-main" & LF & "C" & LF);
      Version.Git_Fixtures.Run (Root, "git commit -q -am main-change");

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Orig   : constant String := Version.Refs.Current_Commit_Id (Repo);
         Patch  : constant String :=
           Version.Files.Read_Binary_File
             (Version.Test_Support.Join (Root, "feat.mbox"));
         Raised : Boolean := False;
      begin
         begin
            Version.Am.Apply_Mailbox (Repo, Patch);
         exception
            when Version.Am.Am_Conflict =>
               Raised := True;
         end;
         Assert (Raised, "a conflicting patch must raise Am_Conflict");
         Assert (Version.Am.In_Progress (Repo),
                 "the session must be left in progress");

         --  Resolve and continue.
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Root, "f.txt"),
            "A" & LF & "B-resolved" & LF & "C" & LF);
         Version.Git_Fixtures.Run (Root, "git add f.txt");
         Version.Am.Continue (Repo);

         Assert (not Version.Am.In_Progress (Repo),
                 "--continue must finish the session");
         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Root, "f.txt"))
            = "A" & LF & "B-resolved" & LF & "C",
            "the resolved content is committed");
         Assert (Version.Refs.Current_Commit_Id (Repo) /= Orig,
                 "--continue advances HEAD past the resolved patch");
      end;
   end Conflict_Continue_And_Abort;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Reconstructs_Commit_From_Git_Patch'Access,
         "Am: applies a git format-patch and preserves author and subject");
      Register_Routine
        (T, Conflict_Continue_And_Abort'Access,
         "Am: a conflicting patch stops the session and --continue resumes it");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Am");
   end Name;

end Version.Am.Tests;
