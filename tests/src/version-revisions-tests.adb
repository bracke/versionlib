with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Git_Fixtures;
with Version.Objects; use Version.Objects;
with Version.Repository;
with Version.Test_Support;

package body Version.Revisions.Tests is

   use AUnit.Assertions;

   function Contains (Text, Fragment : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Text, Fragment) /= 0;
   end Contains;

   procedure Create_Three_Commits (Root : String) is
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Version.Git_Fixtures.Run (Root, "git branch -M master");
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "one" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt && git commit -m one");
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Version.Git_Fixtures.Run (Root, "git tag v1.0");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt && git commit -m two");

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"),
         "three" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt && git commit -m three");
   end Create_Three_Commits;

   function Read_First_Line (Path : String) return String is
      Text : constant String := Version.Test_Support.Read_Text_File (Path);
      Stop : Natural := Text'First;
   begin
      while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
         Stop := Stop + 1;
      end loop;

      if Stop = Text'First then
         return "";
      elsif Stop > Text'Last then
         return Text;
      else
         return Text (Text'First .. Stop - 1);
      end if;
   end Read_First_Line;

   procedure Create_Loose_Object_Name
     (Root : String;
      Id   : Version.Objects.Hex_Object_Id)
   is
      Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Root, ".git/objects"),
           To_String (Id) (1 .. 2));
   begin
      Ada.Directories.Create_Path (Dir);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Dir, To_String (Id) (3 .. 40)),
         "placeholder");
   end Create_Loose_Object_Name;

   procedure Resolve_Head_Branch_Tag_And_Full_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Create_Three_Commits (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo       : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id    : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
         Head_Text  : constant String := Read_First_Line (Version.Test_Support.Join (Root, ".git/refs/heads/master"));
         Branch_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "feature");
         Tag_Id     : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "v1.0");
      begin
         Assert (To_String (Head_Id) = Head_Text, "HEAD did not resolve to current commit");
         Assert (Version.Revisions.Resolve_Commit (Repo, To_String (Head_Id)) = Head_Id,
                 "full object id did not resolve to itself");
         Assert (Branch_Id = Tag_Id, "branch and tag at first commit should match");
         Assert (Version.Revisions.Resolve_Commit (Repo, "refs/heads/feature") = Branch_Id,
                 "explicit branch ref did not resolve");
         Assert (Version.Revisions.Resolve_Commit (Repo, "refs/tags/v1.0") = Tag_Id,
                 "explicit tag ref did not resolve");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Head_Branch_Tag_And_Full_Id;

   procedure Resolve_Abbrev_Parents_And_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Create_Three_Commits (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
         Parent_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD^");
         Grand_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD~2");
         Prefix    : constant String := To_String (Head_Id) (1 .. 8);
         Tree_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Tree (Repo, "HEAD^{tree}");
         Tree_Obj  : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Tree_Id);
      begin
         Assert (Version.Revisions.Resolve_Commit (Repo, Prefix) = Head_Id,
                 "unique loose abbreviation did not resolve");
         Assert (Parent_Id /= Head_Id, "HEAD^ should resolve to parent");
         Assert (Version.Revisions.Resolve_Commit (Repo, "HEAD^1") = Parent_Id,
                 "HEAD^1 should resolve to the same first parent as HEAD^");
         Assert (Version.Revisions.Resolve_Commit (Repo, "HEAD~0") = Head_Id,
                 "HEAD~0 should resolve to HEAD");
         Assert (Grand_Id = Version.Revisions.Resolve_Commit (Repo, "v1.0"),
                 "HEAD~2 should resolve to first commit");
         Assert (Version.Objects.Kind (Tree_Obj) = Version.Objects.Tree_Object,
                 "HEAD^{tree} did not resolve to a tree");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Abbrev_Parents_And_Tree;

   procedure Reject_Unknown_Revision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Id   : Version.Objects.Object_Id_Storage;
      begin
         Id := Version.Revisions.Resolve_Commit (Repo, "does-not-exist");
         Assert (False, "unexpected revision resolved: " & To_String (Id));
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := Contains (Ada.Exceptions.Exception_Message (E), "unknown revision");
      end;

      Assert (Raised, "unknown revision should raise Data_Error");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Reject_Unknown_Revision;

   procedure Reject_Ambiguous_Abbreviation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Create_Loose_Object_Name
        (Root, Version.Objects.To_Object_Id ("abcd000000000000000000000000000000000001"));
      Create_Loose_Object_Name
        (Root, Version.Objects.To_Object_Id ("abcd000000000000000000000000000000000002"));
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Id   : Version.Objects.Object_Id_Storage;
      begin
         Id := Version.Revisions.Resolve (Repo, "abcd");
         Assert (False, "unexpected ambiguous revision resolved: " & To_String (Id));
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := Contains (Ada.Exceptions.Exception_Message (E), "ambiguous revision");
      end;

      Assert (Raised, "ambiguous abbreviation should raise Data_Error");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Reject_Ambiguous_Abbreviation;

   procedure Commitish_Rejects_Blob
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo    : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Tree (Repo, "HEAD");
         Items   : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo, Tree_Id);
         Blob_Id : constant Version.Objects.Object_Id_Storage := Items.First_Element.Id;
         Id      : Version.Objects.Object_Id_Storage;
      begin
         Id := Version.Revisions.Resolve_Commit (Repo, To_String (Blob_Id));
         Assert (False, "blob resolved as commit: " & To_String (Id));
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := Contains (Ada.Exceptions.Exception_Message (E), "object is not a commit");
      end;

      Assert (Raised, "commitish blob resolution should raise Data_Error");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Commitish_Rejects_Blob;

   procedure Resolve_Brace_Suffixes_And_Treeish
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Create_Three_Commits (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo        : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id     : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD");
         Commit_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "HEAD^{commit}");
         Tree_Id     : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Tree (Repo, "HEAD");
         Tree_Id_2   : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Tree (Repo, "HEAD^{tree}");
         Peeled_Tag  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "v1.0^{}");
         Direct_Tag  : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, "v1.0");
      begin
         Assert (Commit_Id = Head_Id, "HEAD^{commit} should preserve commit id");
         Assert (Tree_Id = Tree_Id_2, "HEAD and HEAD^{tree} should resolve to same treeish id");
         Assert (Peeled_Tag = Direct_Tag, "lightweight tag ^{} should preserve target id");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Brace_Suffixes_And_Treeish;

   procedure Reject_Invalid_Suffix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Id   : Version.Objects.Object_Id_Storage;
      begin
         Id := Version.Revisions.Resolve (Repo, "HEAD^{blob}");
         Assert (False, "unexpected invalid suffix resolved: " & To_String (Id));
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := Contains (Ada.Exceptions.Exception_Message (E), "invalid revision suffix");
      end;

      Assert (Raised, "invalid brace suffix should raise Data_Error");

      Raised := False;
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Id   : Version.Objects.Object_Id_Storage;
      begin
         Id := Version.Revisions.Resolve (Repo, "HEAD^bogus");
         Assert (False, "unexpected invalid parent suffix resolved: " & To_String (Id));
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := Contains (Ada.Exceptions.Exception_Message (E), "invalid revision suffix");
      end;

      Assert (Raised, "invalid parent suffix should raise Data_Error before traversal");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Reject_Invalid_Suffix;

   --  `<rev>:<path>` peels the rev to a tree and looks up the path: a blob id,
   --  a nested blob, a subtree id, and empty path -> the tree itself; a
   --  ^/~ prefix and a missing path are also exercised.
   procedure Resolve_Rev_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "rootf"), "ROOT" & Character'Val (10));
      Ada.Directories.Create_Path (Version.Test_Support.Join (Root, "sub"));
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "sub/a.txt"), "AA" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add -A && git commit -m c1");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         --  `<rev>:<path>` matches `git rev-parse` for a root blob, a nested
         --  blob, a subtree, and the empty-path tree.
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse HEAD:rootf)"" = """
            & To_String (Version.Revisions.Resolve (Repo, "HEAD:rootf")) & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse HEAD:sub/a.txt)"" = """
            & To_String (Version.Revisions.Resolve (Repo, "HEAD:sub/a.txt"))
            & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse HEAD:sub)"" = """
            & To_String (Version.Revisions.Resolve (Repo, "HEAD:sub")) & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse HEAD:)"" = """
            & To_String (Version.Revisions.Resolve (Repo, "HEAD:")) & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse HEAD^{tree})"" = """
            & To_String (Version.Revisions.Resolve (Repo, "HEAD:")) & """");

         --  A path missing from the tree raises.
         declare
            Id : Version.Objects.Object_Id_Storage;
         begin
            Id := Version.Revisions.Resolve (Repo, "HEAD:nope");
            Assert (False, "missing path should not resolve: " & To_String (Id));
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
         Assert (Raised, "`<rev>:<missing>` must raise Data_Error");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Rev_Path;

   --  Leading-colon syntax: `:path` / `:0:path` (index blob) and `:/regex`
   --  (youngest commit reachable from any ref whose message matches).
   procedure Resolve_Leading_Colon
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f"), "hello" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f && git commit -m 'first apple'");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "f"), "world" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add f && git commit -m 'second banana'");
      --  A staged-but-uncommitted blob lives only in the index.
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "g"), "staged" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add g");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Raised : Boolean := False;
      begin
         --  `:g` and `:0:g` are the index blob.
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse :g)"" = """
            & To_String (Version.Revisions.Resolve (Repo, ":g")) & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse :0:g)"" = """
            & To_String (Version.Revisions.Resolve (Repo, ":0:g")) & """");

         --  `:/regex` finds the youngest commit whose message matches.
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse :/apple)"" = """
            & To_String (Version.Revisions.Resolve (Repo, ":/apple")) & """");
         Version.Git_Fixtures.Run
           (Root,
            "test ""$(git rev-parse :/banana)"" = """
            & To_String (Version.Revisions.Resolve (Repo, ":/banana")) & """");

         --  A path absent from the index raises.
         begin
            declare
               Id : constant Version.Objects.Object_Id_Storage :=
                 Version.Revisions.Resolve (Repo, ":nosuch");
            begin
               Assert (False, "index miss should not resolve: " & To_String (Id));
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
         Assert (Raised, "`:<missing>` must raise Data_Error");

         Raised := False;
         begin
            declare
               Id : constant Version.Objects.Object_Id_Storage :=
                 Version.Revisions.Resolve (Repo, ":/zzznomatch");
            begin
               Assert (False, "no message match should not resolve: "
                       & To_String (Id));
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
         Assert (Raised, "`:/<no-match>` must raise Data_Error");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Resolve_Leading_Colon;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Resolve_Head_Branch_Tag_And_Full_Id'Access,
         "Revisions: resolve HEAD, branch, tag, and full id");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Resolve_Abbrev_Parents_And_Tree'Access,
         "Revisions: resolve abbreviation, parents, and tree");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Reject_Unknown_Revision'Access,
         "Revisions: unknown revision rejected");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Reject_Ambiguous_Abbreviation'Access,
         "Revisions: ambiguous abbreviation rejected");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Commitish_Rejects_Blob'Access,
         "Revisions: commitish rejects blob");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Resolve_Brace_Suffixes_And_Treeish'Access,
         "Revisions: brace suffixes and treeish resolution");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Reject_Invalid_Suffix'Access,
         "Revisions: invalid suffix rejected");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Resolve_Rev_Path'Access,
         "Revisions: <rev>:<path> resolves tree-path entries");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Resolve_Leading_Colon'Access,
         "Revisions: :path / :N:path / :/regex resolve like git");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Revisions");
   end Name;

end Version.Revisions.Tests;
