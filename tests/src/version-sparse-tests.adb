with Ada.Directories;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Containers; use Ada.Containers;

with Version.Branch;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Pathspec;
with Version.Repository;
with Version.Restore;
with Version.Staging;

with Version.Status;
with Version.Test_Support;
with Version.Write;

package body Version.Sparse.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Create_File (Root : String; Path : String; Content : String) is
      Full : constant String := Version.Test_Support.Join (Root, Path);
   begin
      Version.Files.Create_Parent_Directories (Full);
      Version.Test_Support.Write_Text_File (Full, Content);
   end Create_File;

   function Prepare_Repo
     (T : in out AUnit.Test_Cases.Test_Case'Class)
      return Version.Repository.Repository_Handle
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Create_File (Root, "README.md", "readme" & Character'Val (10));
      Create_File (Root, "src/main.adb", "src" & Character'Val (10));
      Create_File (Root, "docs/manual.md", "docs" & Character'Val (10));
      Create_File (Root, "tests/test.adb", "test" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add .");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("initial");
      return Version.Repository.Open;
   end Prepare_Repo;

   function Contains_Change
     (Items : Version.Status.File_Change_Vectors.Vector; Path : String)
      return Boolean is
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if To_String (Items.Element (I).Path) = Path then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Change;

   function Sparse_Items return Version.Sparse.String_Vectors.Vector is
      Items : Version.Sparse.String_Vectors.Vector;
   begin
      Items.Append ("src/");
      Items.Append ("README.md");
      return Items;
   end Sparse_Items;

   procedure Set_Writes_File_And_List_Reads_Patterns
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Assert
           (Ada.Directories.Exists (Path),
            "sparse-checkout file should exist");
         declare
            Config_Text : constant String :=
              Version.Test_Support.Read_Text_File
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "config"));
         begin
            Assert (Config_Text'Length > 0, "config should be readable");
            Assert
              (Ada.Strings.Fixed.Index (Config_Text, "sparseCheckout = true")
               /= 0,
               "core.sparseCheckout should be enabled");
         end;
         declare
            Texts : constant Version.Sparse.String_Vectors.Vector :=
              Version.Sparse.Pattern_Texts (Repo);
         begin
            Assert
              (Natural (Texts.Length) = 2,
               "two sparse patterns should be listed");
            Assert
              (Texts.Element (0) = "src/",
               "first pattern should be preserved");
            Assert
              (Texts.Element (1) = "README.md",
               "second pattern should be preserved");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Set_Writes_File_And_List_Reads_Patterns;

   procedure Set_Deduplicates_Patterns_Preserving_First_Order
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Items   : Version.Sparse.String_Vectors.Vector;
   begin
      Items.Append ("src/");
      Items.Append ("README.md");
      Items.Append ("src/");
      Items.Append ("README.md");
      Items.Append ("docs/");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Items);
         declare
            Texts : constant Version.Sparse.String_Vectors.Vector :=
              Version.Sparse.Pattern_Texts (Repo);
         begin
            Assert
              (Natural (Texts.Length) = 3,
               "duplicate sparse patterns should be omitted");
            Assert
              (Texts.Element (0) = "src/",
               "first unique sparse pattern should be src/");
            Assert
              (Texts.Element (1) = "README.md",
               "second unique sparse pattern should be README.md");
            Assert
              (Texts.Element (2) = "docs/",
               "later unique sparse pattern should be retained");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Set_Deduplicates_Patterns_Preserving_First_Order;

   procedure Checkout_Materializes_Included_Paths_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);

         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "README.md")),
            "README should be materialized");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "src/main.adb")),
            "src file should be materialized");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "docs/manual.md")),
            "docs file should be omitted by sparse checkout");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "tests/test.adb")),
            "tests file should be omitted by sparse checkout");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Checkout_Materializes_Included_Paths_Only;

   procedure Status_Ignores_Excluded_Tracked_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);
         declare
            S : constant Version.Status.Status_Result :=
              Version.Status.Current_Status;
         begin
            Assert
              (S.Changes.Is_Empty,
               "sparse-excluded tracked paths should not be deleted");
            Assert
              (S.Staged.Is_Empty, "sparse checkout should not stage changes");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Ignores_Excluded_Tracked_Paths;

   procedure Included_Missing_File_Reports_Deleted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);
         Ada.Directories.Delete_File
           (Version.Test_Support.Join (Root, "src/main.adb"));
         declare
            S : constant Version.Status.Status_Result :=
              Version.Status.Current_Status;
         begin
            Assert
              (Natural (S.Changes.Length) = 1,
               "one included deletion should be reported");
            Assert
              (To_String (S.Changes.Element (0).Path) = "src/main.adb",
               "included deleted path should be src/main.adb");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Included_Missing_File_Reports_Deleted;

   procedure Disable_Restores_Full_Working_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);
         Version.Sparse.Disable (Repo);
         Version.Restore.Restore_Working_Tree (Repo);

         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "README.md")),
            "README should remain after disable");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "src/main.adb")),
            "src should remain after disable");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "docs/manual.md")),
            "docs should be restored after disable");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "tests/test.adb")),
            "tests should be restored after disable");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Disable_Restores_Full_Working_Tree;

   procedure Branch_Switch_Respects_Sparse_Patterns
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Branch.Create_Branch ("feature");
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);
         Version.Branch.Switch_Branch ("feature");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "src/main.adb")),
            "included path should survive branch switch");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "docs/manual.md")),
            "excluded path should remain omitted after branch switch");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Switch_Respects_Sparse_Patterns;

   procedure Untracked_Outside_Sparse_Cone_Is_Hidden
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);
         Create_File
           (Root,
            "docs/local-note.txt",
            "outside sparse" & Character'Val (10));
         Create_File
           (Root, "src/local-note.txt", "inside sparse" & Character'Val (10));

         declare
            S : constant Version.Status.Status_Result :=
              Version.Status.Current_Status;
         begin
            Assert
              (not Contains_Change (S.Untracked, "docs/local-note.txt"),
               "untracked file outside sparse cone should be hidden");
            Assert
              (Contains_Change (S.Untracked, "src/local-note.txt"),
               "untracked file inside sparse cone should be reported");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Untracked_Outside_Sparse_Cone_Is_Hidden;

   procedure Glob_Pattern_Includes_Matching_Files
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items   : Version.Sparse.String_Vectors.Vector;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Items.Append ("*.md");
         Version.Sparse.Set_From_Strings (Repo, Items);
         Version.Restore.Restore_Working_Tree (Repo);

         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "README.md")),
            "root markdown file should match sparse glob");
         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "docs/manual.md")),
            "nested markdown file basename should match sparse glob");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "src/main.adb")),
            "non-matching source file should be omitted");
         Assert
           (Version.Status.Current_Status.Changes.Is_Empty,
            "glob sparse checkout should still be status-clean");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Glob_Pattern_Includes_Matching_Files;

   procedure Disable_Removes_File_And_Config_Flag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Sparse.Disable (Repo);

         --  git keeps .git/info/sparse-checkout on disable and only clears the
         --  config flag.
         Assert
           (Ada.Directories.Exists (Path),
            "sparse-checkout file should be kept on disable (git parity)");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "sparse checkout should report disabled");
         declare
            Config_Text : constant String :=
              Version.Test_Support.Read_Text_File
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "config"));
         begin
            Assert
              (Ada.Strings.Fixed.Index (Config_Text, "sparseCheckout = false")
               /= 0,
               "core.sparseCheckout should be disabled");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Disable_Removes_File_And_Config_Flag;

   procedure Included_Query_Respects_Configured_Patterns
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);

         Assert
           (Version.Sparse.Included (Repo, "README.md"),
            "literal file pattern should include the file");
         Assert
           (Version.Sparse.Included (Repo, "src/main.adb"),
            "literal directory pattern should include descendants");
         Assert
           (not Version.Sparse.Included (Repo, "docs/manual.md"),
            "unmatched tracked path should be sparse-excluded");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Included_Query_Respects_Configured_Patterns;

   procedure Empty_Sparse_Set_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Items   : Version.Sparse.String_Vectors.Vector;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         begin
            Version.Sparse.Set_From_Strings (Repo, Items);
            Assert (False, "empty sparse set should raise Data_Error");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Assert (True, "empty sparse set rejected");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Empty_Sparse_Set_Is_Rejected;

   procedure Empty_Sparse_File_Is_Not_Enabled
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Files.Create_Parent_Directories (Path);
         Version.Test_Support.Write_Text_File (Path, "");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "empty sparse-checkout file should not enable sparse mode");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Empty_Sparse_File_Is_Not_Enabled;

   procedure Exclusion_Only_Sparse_Set_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Items   : Version.Sparse.String_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Items.Append (":(exclude)docs/");

         begin
            Version.Sparse.Set_From_Strings (Repo, Items);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "exclusion-only sparse set should be rejected");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "failed exclusion-only sparse set must not enable sparse checkout");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Exclusion_Only_Sparse_Set_Is_Rejected;

   procedure Mixed_Include_And_Exclusion_Sparse_Set_Works
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items   : Version.Sparse.String_Vectors.Vector;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Items.Append ("*.md");
         Items.Append (":(exclude)docs/");
         Version.Sparse.Set_From_Strings (Repo, Items);
         Version.Restore.Restore_Working_Tree (Repo);

         Assert
           (Ada.Directories.Exists
              (Version.Test_Support.Join (Root, "README.md")),
            "positive sparse include should still materialize matching files");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "docs/manual.md")),
            "sparse exclusion should remove matching descendants");
         Assert
           (Version.Status.Current_Status.Changes.Is_Empty,
            "mixed sparse include/exclude checkout should be status-clean");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Mixed_Include_And_Exclusion_Sparse_Set_Works;

   procedure Explicit_Restore_Rejects_Sparse_Excluded_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Raised  : Boolean := False;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Restore.Restore_Working_Tree (Repo);

         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "docs/manual.md")),
            "excluded path should be absent before explicit restore");

         begin
            Version.Restore.Restore_Path ("docs/manual.md");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (Raised,
            "explicit restore should reject sparse-excluded working-tree paths");
         Assert
           (not Ada.Directories.Exists
                  (Version.Test_Support.Join (Root, "docs/manual.md")),
            "explicit restore must not materialize a sparse-excluded path");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Explicit_Restore_Rejects_Sparse_Excluded_Path;

   procedure Config_False_Disables_Existing_Sparse_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Git_Fixtures.Run
           (Version.Repository.Root_Path (Repo),
            "git config core.sparseCheckout false");

         Assert
           (Ada.Directories.Exists (Path),
            "sparse-checkout file should still exist for config-disabled test");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "core.sparseCheckout=false should disable sparse mode even with patterns present");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_False_Disables_Existing_Sparse_File;

   procedure Sparse_File_Comments_Are_Ignored
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Files.Create_Parent_Directories (Path);
         Version.Test_Support.Write_Text_File
           (Path,
            "# sparse checkout comment"
            & Character'Val (10)
            & "src/"
            & Character'Val (10));

         declare
            Texts : constant Version.Sparse.String_Vectors.Vector :=
              Version.Sparse.Pattern_Texts (Repo);
         begin
            Assert
              (Natural (Texts.Length) = 1,
               "comment-only sparse lines should not be returned as patterns");
            Assert
              (Texts.Element (0) = "src/",
               "real sparse pattern should be preserved after comments");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Sparse_File_Comments_Are_Ignored;

   procedure Set_From_Pathspec_Vector_Preserves_Literal_Glob_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Items   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Items.Append (Version.Pathspec.Parse (":(literal)*"));
         Version.Sparse.Set (Repo, Items);

         declare
            Texts : constant Version.Sparse.String_Vectors.Vector :=
              Version.Sparse.Pattern_Texts (Repo);
         begin
            Assert
              (Natural (Texts.Length) = 1,
               "sparse set from parsed pathspec should write one pattern");
            Assert
              (Texts.Element (0) = ":(literal)*",
               "literal glob metacharacters must survive pathspec serialization");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Set_From_Pathspec_Vector_Preserves_Literal_Glob_Text;

   procedure Disabled_Sparse_Config_Does_Not_Parse_Bad_Pattern_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Files.Create_Parent_Directories (Path);
         Version.Test_Support.Write_Text_File
           (Path, "../outside" & Character'Val (10));
         Version.Git_Fixtures.Run
           (Version.Repository.Root_Path (Repo),
            "git config core.sparseCheckout false");

         Assert
           (not Version.Sparse.Enabled (Repo),
            "config-disabled sparse file should not enable sparse mode");
         Assert
           (Version.Status.Current_Status.Changes.Is_Empty,
            "status should not parse disabled sparse-checkout patterns");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Disabled_Sparse_Config_Does_Not_Parse_Bad_Pattern_File;

   procedure Quoted_Config_False_Disables_Sparse_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo        : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Config_Path : constant String :=
           Version.Files.Join (Version.Repository.Git_Dir (Repo), "config");
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Version.Test_Support.Write_Text_File
           (Config_Path,
            "[core]"
            & Character'Val (10)
            & Character'Val (9)
            & "sparseCheckout = ""false"""
            & Character'Val (10));

         Assert
           (not Version.Sparse.Enabled (Repo),
            "quoted core.sparseCheckout=false should disable sparse mode");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Quoted_Config_False_Disables_Sparse_Mode;

   procedure Sparse_Config_Update_Collapses_Duplicate_Keys
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo        : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Config_Path : constant String :=
           Version.Files.Join (Version.Repository.Git_Dir (Repo), "config");
      begin
         Version.Test_Support.Write_Text_File
           (Config_Path,
            "[core]"
            & Character'Val (10)
            & Character'Val (9)
            & "sparseCheckout = false"
            & Character'Val (10)
            & Character'Val (9)
            & "sparsecheckout = no"
            & Character'Val (10)
            & Character'Val (9)
            & "repositoryformatversion = 0"
            & Character'Val (10));

         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);

         declare
            Config_Text : constant String :=
              Version.Test_Support.Read_Text_File (Config_Path);
            --  Match the exact key ("sparseCheckout =") so the sibling
            --  "sparseCheckoutCone =" key does not count as a duplicate.
            First_Key   : constant Natural :=
              Ada.Strings.Fixed.Index (Config_Text, "sparseCheckout =");
            Second_Key  : Natural := 0;
         begin
            if First_Key /= 0 then
               Second_Key :=
                 Ada.Strings.Fixed.Index
                   (Source  => Config_Text,
                    Pattern => "sparseCheckout =",
                    From    => First_Key + 1);
            end if;

            Assert (First_Key /= 0, "sparse config key should be written");
            Assert
              (Second_Key = 0,
               "duplicate sparse config keys should be collapsed");
            Assert
              (Ada.Strings.Fixed.Index
                 (Config_Text, "repositoryformatversion = 0")
               /= 0,
               "other core config keys should be preserved");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Sparse_Config_Update_Collapses_Duplicate_Keys;

   procedure Sparse_Checkout_Directory_Is_Treated_As_Disabled
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo  : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path  : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
         Texts : Version.Sparse.String_Vectors.Vector;
      begin
         Version.Files.Create_Parent_Directories
           (Version.Files.Join (Path, "child"));
         Ada.Directories.Create_Path (Version.Files.To_Native_Path (Path));

         Texts := Version.Sparse.Pattern_Texts (Repo);
         Assert
           (Texts.Is_Empty,
            "sparse-checkout directory should not be returned as pattern text");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "sparse-checkout directory should not enable sparse mode");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Sparse_Checkout_Directory_Is_Treated_As_Disabled;

   procedure Exclusion_Only_Manual_Sparse_File_Is_Not_Enabled
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
      begin
         Version.Files.Create_Parent_Directories (Path);
         Version.Test_Support.Write_Text_File
           (Path,
            ":!docs/"
            & Character'Val (10)
            & ":(exclude)tests/"
            & Character'Val (10));

         Assert
           (Version.Sparse.Pattern_Texts (Repo).Length = 2,
            "manual exclusion-only sparse file should still be readable");
         Assert
           (not Version.Sparse.Enabled (Repo),
            "manual exclusion-only sparse file must not enable sparse mode");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Exclusion_Only_Manual_Sparse_File_Is_Not_Enabled;

   procedure Status_Text_Reports_Disabled_And_Enabled
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Assert
           (Version.Sparse.Status_Text (Repo)
            = "disabled" & Character'Val (10),
            "sparse status should report disabled by default");

         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         Assert
           (Version.Sparse.Status_Text (Repo) = "enabled" & Character'Val (10),
            "sparse status should report enabled after sparse set");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Text_Reports_Disabled_And_Enabled;

   procedure Status_Text_Is_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
      begin
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);
         declare
            Config_Path   : constant String :=
              Version.Files.Join (Version.Repository.Git_Dir (Repo), "config");
            Sparse_Path   : constant String :=
              Version.Files.Join
                (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
            Config_Before : constant String :=
              Version.Test_Support.Read_Text_File (Config_Path);
            Sparse_Before : constant String :=
              Version.Test_Support.Read_Text_File (Sparse_Path);
            Text          : constant String :=
              Version.Sparse.Status_Text (Repo);
         begin
            Assert
              (Text = "enabled" & Character'Val (10),
               "sparse status helper should return enabled text");
            Assert
              (Version.Test_Support.Read_Text_File (Config_Path)
               = Config_Before,
               "sparse status must not mutate config");
            Assert
              (Version.Test_Support.Read_Text_File (Sparse_Path)
               = Sparse_Before,
               "sparse status must not mutate sparse-checkout file");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Status_Text_Is_Read_Only;

   procedure Cone_Set_Writes_Git_Patterns_And_Includes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      LF      : constant Character := Character'Val (10);
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Root : constant String := Version.Repository.Root_Path (Repo);
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "info/sparse-checkout");
         Dirs : Version.Sparse.String_Vectors.Vector;
      begin
         --  Add a nested structure: a parent directory with a target subtree
         --  and a sibling subtree.
         Create_File (Root, "a/f.txt", "af" & LF);
         Create_File (Root, "a/deep/g.txt", "ad" & LF);
         Create_File (Root, "a/other/h.txt", "ao" & LF);
         Version.Git_Fixtures.Run (Root, "git add .");
         Version.Write.Save ("nested");

         Dirs.Append ("src");
         Version.Sparse.Set_Cone (Repo, Dirs);

         Assert (Version.Sparse.Cone_Mode (Repo), "cone mode must be enabled");
         Assert
           (Version.Test_Support.Read_Text_File (Path)
            = "/*" & LF & "!/*/" & LF & "/src/",
            "cone set must write git's cone patterns");
         Assert
           (Version.Sparse.Included (Repo, "README.md"),
            "top-level file is included by the cone");
         Assert
           (Version.Sparse.Included (Repo, "src/main.adb"),
            "a file under the recursive directory is included");
         Assert
           (not Version.Sparse.Included (Repo, "docs/manual.md"),
            "a file outside the cone is excluded");

         --  Nested cone: the ancestor's own files stay, its sibling subtree
         --  goes, and the target subtree is included recursively.
         declare
            Nested : Version.Sparse.String_Vectors.Vector;
            Leaves : Version.Sparse.String_Vectors.Vector;
         begin
            Nested.Append ("a/deep");
            Version.Sparse.Set_Cone (Repo, Nested);

            Assert
              (Version.Test_Support.Read_Text_File (Path)
               = "/*" & LF & "!/*/" & LF & "/a/" & LF & "!/a/*/" & LF
                 & "/a/deep/",
               "nested cone set writes ancestor navigation patterns");
            Assert
              (Version.Sparse.Included (Repo, "a/f.txt"),
               "a parent directory's own files are kept");
            Assert
              (Version.Sparse.Included (Repo, "a/deep/g.txt"),
               "the recursive target subtree is included");
            Assert
              (not Version.Sparse.Included (Repo, "a/other/h.txt"),
               "a sibling subtree of the parent is excluded");

            Leaves := Version.Sparse.Cone_Recursive_Directories (Repo);
            Assert
              (Leaves.Length = 1
               and then Leaves.Element (Leaves.First_Index) = "a/deep",
               "list reports only the recursive leaf directory");
         end;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cone_Set_Writes_Git_Patterns_And_Includes;

   procedure Skip_Worktree_Bits_Reflect_Sparse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Prepare_Repo (T);
         Dirs : Version.Sparse.String_Vectors.Vector;

         function Entry_Skip (P : String) return Boolean is
            Items : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Version.Staging.Load (Repo);
         begin
            for I in Items.First_Index .. Items.Last_Index loop
               if To_String (Items.Element (I).Path) = P then
                  return Items.Element (I).Skip_Worktree;
               end if;
            end loop;
            return False;
         end Entry_Skip;
      begin
         Dirs.Append ("src");
         Version.Sparse.Set_Cone (Repo, Dirs);
         Version.Restore.Restore_Working_Tree (Repo);
         Version.Restore.Apply_Sparse_Skip_Worktree (Repo);

         Assert
           (not Entry_Skip ("src/main.adb"),
            "an included path must not be skip-worktree");
         Assert
           (Entry_Skip ("docs/manual.md"),
            "a sparse-excluded path must be skip-worktree");
         Assert
           (Entry_Skip ("tests/test.adb"),
            "every sparse-excluded path is skip-worktree");

         --  git requires the round-tripped bits to survive a plain reload.
         Assert
           (Entry_Skip ("docs/manual.md"),
            "skip-worktree survives an index reload");

         Version.Restore.Clear_Skip_Worktree (Repo);
         Assert
           (not Entry_Skip ("docs/manual.md"),
            "Clear_Skip_Worktree removes every skip-worktree bit");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Skip_Worktree_Bits_Reflect_Sparse;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Cone_Set_Writes_Git_Patterns_And_Includes'Access,
         "Sparse cone set writes git patterns and cone inclusion");
      Register_Routine
        (T,
         Skip_Worktree_Bits_Reflect_Sparse'Access,
         "Sparse skip-worktree bits reflect the pattern set");
      Register_Routine
        (T,
         Set_Writes_File_And_List_Reads_Patterns'Access,
         "Sparse set writes file and list reads patterns");
      Register_Routine
        (T,
         Set_Deduplicates_Patterns_Preserving_First_Order'Access,
         "Sparse set deduplicates patterns preserving first order");
      Register_Routine
        (T,
         Checkout_Materializes_Included_Paths_Only'Access,
         "Sparse checkout materializes included paths only");
      Register_Routine
        (T,
         Status_Ignores_Excluded_Tracked_Paths'Access,
         "Sparse status ignores excluded tracked paths");
      Register_Routine
        (T,
         Included_Missing_File_Reports_Deleted'Access,
         "Sparse included missing file reports deleted");
      Register_Routine
        (T,
         Disable_Restores_Full_Working_Tree'Access,
         "Sparse disable restores full working tree");
      Register_Routine
        (T,
         Branch_Switch_Respects_Sparse_Patterns'Access,
         "Sparse branch switch respects patterns");
      Register_Routine
        (T,
         Untracked_Outside_Sparse_Cone_Is_Hidden'Access,
         "Sparse hides untracked files outside sparse cone");
      Register_Routine
        (T,
         Glob_Pattern_Includes_Matching_Files'Access,
         "Sparse glob pattern includes matching files");
      Register_Routine
        (T,
         Disable_Removes_File_And_Config_Flag'Access,
         "Sparse disable keeps pattern file, clears config flag");
      Register_Routine
        (T,
         Included_Query_Respects_Configured_Patterns'Access,
         "Sparse included query respects configured patterns");
      Register_Routine
        (T,
         Empty_Sparse_Set_Is_Rejected'Access,
         "Sparse empty set is rejected");
      Register_Routine
        (T,
         Empty_Sparse_File_Is_Not_Enabled'Access,
         "Sparse empty file does not enable sparse mode");
      Register_Routine
        (T,
         Exclusion_Only_Sparse_Set_Is_Rejected'Access,
         "Sparse exclusion-only set is rejected");
      Register_Routine
        (T,
         Mixed_Include_And_Exclusion_Sparse_Set_Works'Access,
         "Sparse include plus exclusion set works");
      Register_Routine
        (T,
         Explicit_Restore_Rejects_Sparse_Excluded_Path'Access,
         "Sparse explicit restore rejects excluded paths");
      Register_Routine
        (T,
         Config_False_Disables_Existing_Sparse_File'Access,
         "Sparse config false disables existing sparse file");
      Register_Routine
        (T,
         Sparse_File_Comments_Are_Ignored'Access,
         "Sparse file comments are ignored");
      Register_Routine
        (T,
         Set_From_Pathspec_Vector_Preserves_Literal_Glob_Text'Access,
         "Sparse set preserves literal glob pathspec text");
      Register_Routine
        (T,
         Disabled_Sparse_Config_Does_Not_Parse_Bad_Pattern_File'Access,
         "Sparse disabled config does not parse bad pattern file");
      Register_Routine
        (T,
         Quoted_Config_False_Disables_Sparse_Mode'Access,
         "Sparse quoted config false disables mode");
      Register_Routine
        (T,
         Sparse_Config_Update_Collapses_Duplicate_Keys'Access,
         "Sparse config update collapses duplicate keys");
      Register_Routine
        (T,
         Sparse_Checkout_Directory_Is_Treated_As_Disabled'Access,
         "Sparse checkout directory is treated as disabled");
      Register_Routine
        (T,
         Exclusion_Only_Manual_Sparse_File_Is_Not_Enabled'Access,
         "Sparse manual exclusion-only file does not enable mode");
      Register_Routine
        (T,
         Status_Text_Reports_Disabled_And_Enabled'Access,
         "Sparse status text reports disabled and enabled");
      Register_Routine
        (T,
         Status_Text_Is_Read_Only'Access,
         "Sparse status text is read-only");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Sparse");
   end Name;

end Version.Sparse.Tests;
