with Ada.Directories;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.History;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Revisions;

package body Version.Subtree.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   --  A main repository with a foreign one grafted in at "vendor/lib", built
   --  by git itself, so the fixture is exactly what `git subtree add` writes.
   procedure Build_Fixture (Root : String) is
      Dates : constant String :=
        "export GIT_AUTHOR_DATE=""1000000000 +0000"" "
        & "GIT_COMMITTER_DATE=""1000000000 +0000""; ";
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@t");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Version.Git_Fixtures.Run
        (Root,
         Dates
         & "mkdir lib && cd lib && git init -q . "
         & "&& git config user.email t@t && git config user.name T "
         & "&& echo one > f.txt && git add -A && git commit -q -m 'lib c1' "
         & "&& echo two > f.txt && git commit -q -a -m 'lib c2'");
      Version.Git_Fixtures.Run
        (Root,
         Dates
         & "echo app > app.txt && git add -A && git commit -q -m 'app c1' "
         & "&& git subtree add -q --prefix=vendor/lib ./lib main "
         & "&& echo three > vendor/lib/f.txt "
         & "&& git commit -q -a -m 'local sub edit'");
   end Build_Fixture;

   --  `subtree split` reuses the foreign repository's own commits wherever a
   --  parent already carries the identical subtree, and copies the rest with
   --  their author and committer intact.  The result here is the lib history
   --  with one commit on top -- exactly what `git subtree split` produces.
   procedure Split_Rebuilds_Subtree_History
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Build_Fixture (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Lib_Tip : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~1^2");

         Updated : Boolean;

         Tip : constant Version.Objects.Hex_Object_Id :=
           Version.Subtree.Split
             (Repo    => Repo,
              Prefix  => "vendor/lib",
              Branch  => "libsplit",
              Updated => Updated);

         Parents : constant Version.History.Commit_Id_Vectors.Vector :=
           Version.History.Parent_Commits (Repo, Tip);
      begin
         Assert (not Updated, "the branch did not exist yet");

         --  The split tip carries the subtree's content at the root: the
         --  tree of HEAD's "vendor/lib", lifted out of the prefix.
         Assert
           (Version.Objects.To_String
              (Version.Objects.Commit_Tree_Id
                 (Version.Objects.Read_Object (Repo, Tip)))
            = Version.Subtree.Subtree_Tree_Id
                (Repo, Version.Revisions.Resolve_Commit (Repo, "HEAD"),
                 "vendor/lib"),
            "the split tip's tree must be the prefix's tree");

         --  Its single parent is the foreign repository's own tip, reused
         --  rather than copied.
         Assert (Natural (Parents.Length) = 1,
                 "split tip must have exactly one parent, got"
                 & Parents.Length'Image);
         Assert
           (Version.Objects.To_String (Parents.First_Element)
            = Version.Objects.To_String (Lib_Tip),
            "the split must reuse the foreign tip "
            & Version.Objects.To_String (Lib_Tip) & ", got "
            & Version.Objects.To_String (Parents.First_Element));

         Assert
           (Version.Refs.Ref_Exists (Repo, "refs/heads/libsplit"),
            "split -b must write the branch");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Split_Rebuilds_Subtree_History;

   --  Splitting twice in a row is idempotent: the second run finds the joins
   --  the first left behind and returns the same tip.
   procedure Split_Is_Idempotent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Build_Fixture (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Updated : Boolean;

         First : constant Version.Objects.Hex_Object_Id :=
           Version.Subtree.Split (Repo, "vendor/lib", Updated => Updated);

         Second : constant Version.Objects.Hex_Object_Id :=
           Version.Subtree.Split (Repo, "vendor/lib", Updated => Updated);
      begin
         Assert
           (Version.Objects.To_String (First)
            = Version.Objects.To_String (Second),
            "a second split must return the same tip: "
            & Version.Objects.To_String (First) & " vs "
            & Version.Objects.To_String (Second));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Split_Is_Idempotent;

   --  A prefix that is not in the tree is not something to split.
   procedure Split_Requires_The_Prefix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Build_Fixture (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Updated : Boolean;
         Ignored : Version.Objects.Hex_Object_Id;
      begin
         Ignored := Version.Subtree.Split (Repo, "nowhere", Updated => Updated);
         pragma Unreferenced (Ignored);
      exception
         when others =>
            Raised := True;
      end;

      Assert (Raised, "splitting an absent prefix must be refused");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Split_Requires_The_Prefix;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Split_Rebuilds_Subtree_History'Access,
         "Subtree: split reuses the foreign commits and copies the rest");
      Register_Routine
        (T, Split_Is_Idempotent'Access,
         "Subtree: a second split returns the same tip");
      Register_Routine
        (T, Split_Requires_The_Prefix'Access,
         "Subtree: split refuses a prefix that is not there");
   end Register_Tests;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Subtree");
   end Name;

end Version.Subtree.Tests;
