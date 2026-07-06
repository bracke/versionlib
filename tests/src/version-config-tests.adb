with Ada.Directories;
with Ada.IO_Exceptions;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Repository;
with Version.Init;
with Version.Test_Support;

package body Version.Config.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Replace_Read_Remove_Section
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      function Contains
        (Items   : Version.Config.Config_Entry_Vectors.Vector;
         Section : String;
         Key     : String;
         Value   : String) return Boolean is
      begin
         if Items.Is_Empty then
            return False;
         end if;

         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry :=
                 Items.Element (I);
            begin
               if To_String (Item.Section) = Section
                 and then To_String (Item.Key) = Key
                 and then To_String (Item.Value) = Value
               then
                  return True;
               end if;
            end;
         end loop;

         return False;
      end Contains;

   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   => To_Unbounded_String ("/tmp/source")));

         Version.Config.Replace_Section
           (Repo => Repo, Section => "remote ""origin""", Entries => Entries);

         Assert
           (Contains
              (Version.Config.Read_All (Repo),
               "remote ""origin""",
               "url",
               "/tmp/source"),
            "config must contain replaced section entry");

         Entries.Clear;

         Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   => To_Unbounded_String ("/tmp/other")));

         Version.Config.Replace_Section
           (Repo => Repo, Section => "remote ""origin""", Entries => Entries);

         declare
            Items : constant Version.Config.Config_Entry_Vectors.Vector :=
              Version.Config.Read_All (Repo);
         begin
            Assert
              (Contains (Items, "remote ""origin""", "url", "/tmp/other"),
               "config replace must overwrite section");

            Assert
              (not Contains (Items, "remote ""origin""", "url", "/tmp/source"),
               "config replace must remove old section entry");
         end;

         Version.Config.Remove_Section
           (Repo => Repo, Section => "remote ""origin""");

         Assert
           (not Contains
                  (Version.Config.Read_All (Repo),
                   "remote ""origin""",
                   "url",
                   "/tmp/other"),
            "config remove must delete section");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Replace_Read_Remove_Section;

   procedure Config_List_Text_Is_Stable_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         User_Entries   : Version.Config.Config_Entry_Vectors.Vector;
         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
         Branch_Entries : Version.Config.Config_Entry_Vectors.Vector;

      begin
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("name"),
               Value   => To_Unbounded_String ("Ada User")));
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("email"),
               Value   => To_Unbounded_String ("ada@example.invalid")));
         Version.Config.Replace_Section
           (Repo => Repo, Section => "user", Entries => User_Entries);

         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         Branch_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("branch ""main"""),
               Key     => To_Unbounded_String ("remote"),
               Value   => To_Unbounded_String ("origin")));
         Branch_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("branch ""main"""),
               Key     => To_Unbounded_String ("merge"),
               Value   => To_Unbounded_String ("refs/heads/main")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "branch ""main""",
            Entries => Branch_Entries);

         declare
            Before : constant String := Version.Config.List_Text (Repo);
            After  : constant String := Version.Config.List_Text (Repo);
         begin
            Assert
              (Before = After,
               "config list must be read-only and deterministic");
            Assert
              (Version.Config.Config_Entry_Name
                 ((Section => To_Unbounded_String ("remote ""origin"""),
                   Key     => To_Unbounded_String ("url"),
                   Value   => To_Unbounded_String ("x")))
               = "remote.origin.url",
               "quoted config subsections must render as section.subsection.key");
            Assert
              (Before
               = "core.repositoryformatversion=0"
                 & Character'Val (10)
                 & "core.filemode=true"
                 & Character'Val (10)
                 & "core.bare=false"
                 & Character'Val (10)
                 & "core.logallrefupdates=true"
                 & Character'Val (10)
                 & "user.name=Ada User"
                 & Character'Val (10)
                 & "user.email=ada@example.invalid"
                 & Character'Val (10)
                 & "remote.origin.url=https://example.invalid/repo.git"
                 & Character'Val (10)
                 & "branch.main.remote=origin"
                 & Character'Val (10)
                 & "branch.main.merge=refs/heads/main"
                 & Character'Val (10),
               "config list must render stable local entries in section.key=value form");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_List_Text_Is_Stable_And_Read_Only;

   procedure Config_Keys_Text_Is_Stable_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         User_Entries   : Version.Config.Config_Entry_Vectors.Vector;
         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
         Branch_Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("name"),
               Value   => To_Unbounded_String ("Ada User")));
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("email"),
               Value   => To_Unbounded_String ("ada@example.invalid")));
         Version.Config.Replace_Section
           (Repo => Repo, Section => "user", Entries => User_Entries);

         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         Branch_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("branch ""main"""),
               Key     => To_Unbounded_String ("remote"),
               Value   => To_Unbounded_String ("origin")));
         Branch_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("branch ""main"""),
               Key     => To_Unbounded_String ("merge"),
               Value   => To_Unbounded_String ("refs/heads/main")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "branch ""main""",
            Entries => Branch_Entries);

         declare
            Before : constant String := Version.Config.List_Text (Repo);
            Keys   : constant String := Version.Config.Keys_Text (Repo);
         begin
            Assert
              (Keys
               = "core.repositoryformatversion"
                 & Character'Val (10)
                 & "core.filemode"
                 & Character'Val (10)
                 & "core.bare"
                 & Character'Val (10)
                 & "core.logallrefupdates"
                 & Character'Val (10)
                 & "user.name"
                 & Character'Val (10)
                 & "user.email"
                 & Character'Val (10)
                 & "remote.origin.url"
                 & Character'Val (10)
                 & "branch.main.remote"
                 & Character'Val (10)
                 & "branch.main.merge"
                 & Character'Val (10),
               "config keys must render stable local entries as section.key lines without values");
            Assert
              (Version.Config.List_Text (Repo) = Before,
               "config keys must be read-only");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Keys_Text_Is_Stable_And_Read_Only;

   procedure Config_Get_Value_Is_Stable_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         User_Entries   : Version.Config.Config_Entry_Vectors.Vector;
         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("name"),
               Value   => To_Unbounded_String ("Ada User")));
         Version.Config.Replace_Section
           (Repo => Repo, Section => "user", Entries => User_Entries);

         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         declare
            Before : constant String := Version.Config.List_Text (Repo);
         begin
            Assert
              (Version.Config.Get_Value (Repo, "user.name") = "Ada User",
               "config get must return the selected scalar value");
            Assert
              (Version.Config.Get_Text (Repo, "remote.origin.url")
               = "https://example.invalid/repo.git" & Character'Val (10),
               "config get text must print exactly one value line");
            Assert
              (Version.Config.Get_Value (Repo, "REMOTE.ORIGIN.URL")
               = "https://example.invalid/repo.git",
               "config get must resolve rendered dotted names case-insensitively");
            Assert
              (Version.Config.List_Text (Repo) = Before,
               "config get must be read-only");
         end;

         begin
            declare
               Ignored : constant String :=
                 Version.Config.Get_Value (Repo, "core.editor");
            begin
               Assert (False, "missing config key must fail: " & Ignored);
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Get_Value_Is_Stable_And_Read_Only;

   procedure Config_Has_Key_Is_Quiet_Predicate_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         declare
            Before : constant String := Version.Config.List_Text (Repo);
         begin
            Assert
              (Version.Config.Has_Key (Repo, "remote.origin.url"),
               "config has must return True for an existing dotted key");
            Assert
              (Version.Config.Has_Key (Repo, "REMOTE.ORIGIN.URL"),
               "config has must be case-insensitive like config get");
            Assert
              (not Version.Config.Has_Key (Repo, "remote.origin.fetch"),
               "config has must return False for a missing key");
            Assert
              (Version.Config.List_Text (Repo) = Before,
               "config has must be read-only");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Has_Key_Is_Quiet_Predicate_And_Read_Only;

   procedure Config_Unset_Key_Removes_Only_Selected_Key
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         User_Entries   : Version.Config.Config_Entry_Vectors.Vector;
         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("name"),
               Value   => To_Unbounded_String ("Ada User")));
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("email"),
               Value   => To_Unbounded_String ("ada@example.invalid")));
         Version.Config.Replace_Section
           (Repo => Repo, Section => "user", Entries => User_Entries);

         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("fetch"),
               Value   =>
                 To_Unbounded_String ("+refs/heads/*:refs/remotes/origin/*")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         Version.Config.Unset_Key (Repo, "remote.origin.url");

         Assert
           (not Version.Config.Has_Key (Repo, "remote.origin.url"),
            "config unset must remove the selected key");
         Assert
           (Version.Config.Get_Value (Repo, "remote.origin.fetch")
            = "+refs/heads/*:refs/remotes/origin/*",
            "config unset must preserve sibling keys in the same subsection");
         Assert
           (Version.Config.Get_Value (Repo, "user.name") = "Ada User",
            "config unset must preserve unrelated sections");

         begin
            Version.Config.Unset_Key (Repo, "remote.origin.url");
            Assert (False, "unsetting a missing config key must fail");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Unset_Key_Removes_Only_Selected_Key;

   procedure Config_Set_Key_Updates_And_Creates_Local_Keys
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         User_Entries   : Version.Config.Config_Entry_Vectors.Vector;
         Remote_Entries : Version.Config.Config_Entry_Vectors.Vector;
      begin
         User_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("user"),
               Key     => To_Unbounded_String ("name"),
               Value   => To_Unbounded_String ("Ada User")));
         Version.Config.Replace_Section
           (Repo => Repo, Section => "user", Entries => User_Entries);

         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("url"),
               Value   =>
                 To_Unbounded_String ("https://example.invalid/repo.git")));
         Remote_Entries.Append
           (Version.Config.Config_Entry'
              (Section => To_Unbounded_String ("remote ""origin"""),
               Key     => To_Unbounded_String ("fetch"),
               Value   =>
                 To_Unbounded_String ("+refs/heads/*:refs/remotes/origin/*")));
         Version.Config.Replace_Section
           (Repo    => Repo,
            Section => "remote ""origin""",
            Entries => Remote_Entries);

         Version.Config.Set_Key
           (Repo, "remote.origin.url", "https://example.invalid/other.git");

         Assert
           (Version.Config.Get_Value (Repo, "remote.origin.url")
            = "https://example.invalid/other.git",
            "config set must update an existing quoted-subsection key");
         Assert
           (Version.Config.Get_Value (Repo, "remote.origin.fetch")
            = "+refs/heads/*:refs/remotes/origin/*",
            "config set must preserve sibling keys");
         Assert
           (Version.Config.Get_Value (Repo, "user.name") = "Ada User",
            "config set must preserve unrelated sections");

         Version.Config.Set_Key (Repo, "remote.origin.tagOpt", "--no-tags");

         Assert
           (Version.Config.Get_Value (Repo, "remote.origin.tagOpt")
            = "--no-tags",
            "config set must add missing keys to existing subsections");
         Assert
           (Version.Config.Keys_Text (Repo)
            = "core.repositoryformatversion"
              & Character'Val (10)
              & "core.filemode"
              & Character'Val (10)
              & "core.bare"
              & Character'Val (10)
              & "core.logallrefupdates"
              & Character'Val (10)
              & "user.name"
              & Character'Val (10)
              & "remote.origin.url"
              & Character'Val (10)
              & "remote.origin.fetch"
              & Character'Val (10)
              & "remote.origin.tagOpt"
              & Character'Val (10),
            "config set must keep deterministic flattened key order");

         Version.Config.Set_Key (Repo, "branch.main.remote", "origin");

         Assert
           (Version.Config.Get_Value (Repo, "branch.main.remote") = "origin",
            "config set must create missing quoted-subsection entries");

         begin
            Version.Config.Set_Key
              (Repo, "core.bad", "bad" & Character'Val (10) & "value");
            Assert (False, "unsafe config values must be rejected");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Set_Key_Updates_And_Creates_Local_Keys;

   procedure Config_Worktree_Config_Overrides_Common
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      LF  : constant Character := Character'Val (10);
      HT  : constant Character := Character'Val (9);
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Git_Dir : constant String := Version.Test_Support.Join (Root, ".git");
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Git_Dir, "config"),
         "[core]" & LF & HT & "repositoryformatversion = 1" & LF
         & "[user]" & LF & HT & "name = CommonName" & LF
         & HT & "email = common@example.com" & LF
         & "[extensions]" & LF & HT & "worktreeConfig = true" & LF);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Git_Dir, "config.worktree"),
         "[user]" & LF & HT & "name = WorktreeName" & LF);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Config.Get_Value (Repo, "user.name") = "WorktreeName",
            "config.worktree must override the common config");
         Assert
           (Version.Config.Get_Value (Repo, "user.email")
            = "common@example.com",
            "keys absent from config.worktree fall back to the common config");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Config_Worktree_Config_Overrides_Common;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Config_Worktree_Config_Overrides_Common'Access,
         "Config: worktreeConfig layers config.worktree over common config");

      Register_Routine
        (T,
         Replace_Read_Remove_Section'Access,
         "Config: replace read remove section");

      Register_Routine
        (T,
         Config_List_Text_Is_Stable_And_Read_Only'Access,
         "Config: list text is stable and read-only");

      Register_Routine
        (T,
         Config_Keys_Text_Is_Stable_And_Read_Only'Access,
         "Config: keys text is stable and read-only");

      Register_Routine
        (T,
         Config_Get_Value_Is_Stable_And_Read_Only'Access,
         "Config: get value is stable and read-only");

      Register_Routine
        (T,
         Config_Has_Key_Is_Quiet_Predicate_And_Read_Only'Access,
         "Config: has key is quiet predicate and read-only");

      Register_Routine
        (T,
         Config_Unset_Key_Removes_Only_Selected_Key'Access,
         "Config: unset key removes only selected key");

      Register_Routine
        (T,
         Config_Set_Key_Updates_And_Creates_Local_Keys'Access,
         "Config: set key updates and creates local keys");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Config");
   end Name;

end Version.Config.Tests;
