with Version.Objects;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;


with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Ref_Transaction;
with Version.Remotes.Test_Hooks;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;

package body Version.Remotes.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   Prune_Hook_Path : Unbounded_String;
   Prune_Hook_Text : Unbounded_String;

   procedure Advance_Prune_Tracking_Ref is
   begin
      Version.Test_Support.Write_Text_File
        (To_String (Prune_Hook_Path), To_String (Prune_Hook_Text));
   end Advance_Prune_Tracking_Ref;

   procedure Add_And_List_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);

      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "/tmp/source-repo");

      declare
         Items : constant Version.Remotes.Remote_Vectors.Vector :=
           Version.Remotes.List_Remotes;
      begin
         Assert
           (Natural (Items.Length) = 1,
            "remote list must contain one remote");

         Assert
           (Ada.Strings.Unbounded.To_String
              (Items.Element (Items.First_Index).Name) = "origin",
            "remote name mismatch");

         Assert
           (Ada.Strings.Unbounded.To_String
              (Items.Element (Items.First_Index).Url) = "/tmp/source-repo",
            "remote url mismatch");
      end;

      Version.Git_Fixtures.Run
        (Root,
         "git config --get remote.origin.url | grep '^/tmp/source-repo$'");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_And_List_Remote;

   procedure Add_Remote_Rejects_Duplicate (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);

      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
      (Name => "origin",
         Url  => "/tmp/source-one");

      begin
         Version.Remotes.Add_Remote
         (Name => "origin",
            Url  => "/tmp/source-two");

      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
      (Raised,
         "remote add must reject duplicate remote name");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_Remote_Rejects_Duplicate;

   procedure Delete_Remote_Rejects_Missing
   (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);

      Ada.Directories.Set_Directory (Root);

      begin
         Version.Remotes.Delete_Remote ("origin");

      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
      (Raised,
         "remote delete must reject missing remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Delete_Remote_Rejects_Missing;

   procedure Remote_List_Text_Is_Stable_And_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");
      Version.Remotes.Add_Remote
        (Name => "backup",
         Url  => "ssh://example.invalid/project.git");

      declare
         Before : constant String := Version.Remotes.List_Text;
         After  : constant String := Version.Remotes.List_Text;

         Line : constant String :=
           Version.Remotes.Remote_Line
             (Version.Remotes.Remote'
                (Name => Ada.Strings.Unbounded.To_Unbounded_String ("origin"),
                 Url  => Ada.Strings.Unbounded.To_Unbounded_String
                   ("https://example.invalid/project.git")));
      begin
         Assert
           (Line = "origin" & Character'Val (9)
            & "https://example.invalid/project.git",
            "remote line must use stable tab-separated name/url form");

         Assert
           (Before = After,
            "remote list text must be read-only and deterministic");

         Assert
           (Before =
              "origin" & Character'Val (9)
              & "https://example.invalid/project.git" & Character'Val (10)
              & "backup" & Character'Val (9)
              & "ssh://example.invalid/project.git" & Character'Val (10),
            "remote list must render configured remotes in stable tab-separated form");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_List_Text_Is_Stable_And_Read_Only;

   procedure Remote_Get_Url_Prints_Only_Selected_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");
      Version.Remotes.Add_Remote
        (Name => "backup",
         Url  => "ssh://example.invalid/project.git");

      Assert
        (Version.Remotes.Get_Url ("origin") =
         "https://example.invalid/project.git",
         "remote get-url must return the selected remote URL only");

      Assert
        (Version.Remotes.Get_Url_Text ("backup") =
         "ssh://example.invalid/project.git" & Character'Val (10),
         "remote get-url text must be URL plus newline only");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Get_Url_Prints_Only_Selected_Url;

   procedure Remote_Get_Url_Rejects_Missing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Url : constant String := Version.Remotes.Get_Url ("origin");
         begin
            Assert (Url = "", "missing remote lookup must not return a value");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remote get-url must reject a missing remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Get_Url_Rejects_Missing;

   procedure Remote_Get_Url_Is_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");

      declare
         Before : constant String := Version.Remotes.List_Text;
         Url    : constant String := Version.Remotes.Get_Url ("origin");
         After  : constant String := Version.Remotes.List_Text;
      begin
         Assert
           (Url = "https://example.invalid/project.git",
            "remote get-url must return the configured URL");

         Assert
           (Before = After,
            "remote get-url must not mutate remote configuration");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Get_Url_Is_Read_Only;

   procedure Remote_Set_Url_Updates_Existing_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/old.git");

      Version.Remotes.Set_Url
        (Name => "origin",
         Url  => "https://example.invalid/new.git");

      Assert
        (Version.Remotes.Get_Url ("origin") =
         "https://example.invalid/new.git",
         "remote set-url must replace the selected remote URL");

      Assert
        (Version.Remotes.List_Text =
           "origin" & Character'Val (9)
           & "https://example.invalid/new.git" & Character'Val (10),
         "remote list must expose the updated URL only");

      Version.Git_Fixtures.Run
        (Root,
         "git config --get remote.origin.url | grep '^https://example.invalid/new.git$'");

      Version.Git_Fixtures.Run
        (Root,
         "git config --get remote.origin.fetch | grep '^+refs/heads/\*:refs/remotes/origin/\*$'");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Set_Url_Updates_Existing_Remote;

   procedure Remote_Set_Url_Rejects_Missing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         Version.Remotes.Set_Url
           (Name => "origin",
            Url  => "https://example.invalid/new.git");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remote set-url must reject a missing remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Set_Url_Rejects_Missing;

   procedure Remote_Set_Url_Does_Not_Create_New_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/origin.git");

      begin
         Version.Remotes.Set_Url
           (Name => "backup",
            Url  => "https://example.invalid/backup.git");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            null;
      end;

      Assert
        (Version.Remotes.List_Text =
           "origin" & Character'Val (9)
           & "https://example.invalid/origin.git" & Character'Val (10),
         "remote set-url must not create a new remote on failure");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Set_Url_Does_Not_Create_New_Remote;

   procedure Remote_Rename_Updates_Existing_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");

      Version.Remotes.Rename_Remote
        (Old_Name => "origin",
         New_Name => "upstream");

      Assert
        (Version.Remotes.Get_Url ("upstream") =
         "https://example.invalid/project.git",
         "remote rename must preserve the configured URL");

      Assert
        (Version.Remotes.List_Text =
           "upstream" & Character'Val (9)
           & "https://example.invalid/project.git" & Character'Val (10),
         "remote rename must expose only the new remote name");

      Version.Git_Fixtures.Run
        (Root,
         "git config --get remote.upstream.url | grep '^https://example.invalid/project.git$'");

      Version.Git_Fixtures.Run
        (Root,
         "test -z """"$(git config --get remote.origin.url)""""");

      Version.Git_Fixtures.Run
        (Root,
         "git config --get remote.upstream.fetch | grep '^+refs/heads/\*:refs/remotes/origin/\*$'");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Rename_Updates_Existing_Remote;

   procedure Remote_Rename_Rejects_Missing_Source
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         Version.Remotes.Rename_Remote
           (Old_Name => "origin",
            New_Name => "upstream");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remote rename must reject a missing source remote");

      Assert
        (Version.Remotes.List_Text = "",
         "remote rename failure must not create a destination remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Rename_Rejects_Missing_Source;

   procedure Remote_Rename_Rejects_Destination_Collision
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/origin.git");

      Version.Remotes.Add_Remote
        (Name => "upstream",
         Url  => "https://example.invalid/upstream.git");

      begin
         Version.Remotes.Rename_Remote
           (Old_Name => "origin",
            New_Name => "upstream");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remote rename must reject an existing destination remote");

      Assert
        (Version.Remotes.Get_Url ("origin") =
         "https://example.invalid/origin.git",
         "remote rename collision must preserve source remote");

      Assert
        (Version.Remotes.Get_Url ("upstream") =
         "https://example.invalid/upstream.git",
         "remote rename collision must preserve destination remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Rename_Rejects_Destination_Collision;

   procedure Remote_Exists_Returns_True_For_Configured_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");

      Assert
        (Version.Remotes.Remote_Exists ("origin"),
         "remote exists must return true for configured remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Exists_Returns_True_For_Configured_Remote;

   procedure Remote_Exists_Returns_False_For_Missing_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");

      Assert
        (not Version.Remotes.Remote_Exists ("upstream"),
         "remote exists must return false for missing remote");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Exists_Returns_False_For_Missing_Remote;

   procedure Remote_Exists_Rejects_Invalid_Name
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         if Version.Remotes.Remote_Exists ("bad..name") then
            null;
         end if;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "remote exists must reject invalid remote names");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Exists_Rejects_Invalid_Name;

   procedure Remote_Exists_Is_Read_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "https://example.invalid/project.git");

      declare
         Before : constant String := Version.Remotes.List_Text;
         Exists : constant Boolean := Version.Remotes.Remote_Exists ("origin");
         After  : constant String := Version.Remotes.List_Text;
      begin
         Assert (Exists, "remote exists must find the configured remote");
         Assert
           (Before = After,
            "remote exists must not mutate remote configuration");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Exists_Is_Read_Only;

   procedure Remote_Prune_Dry_Run_Reports_Stale_Local_Tracking_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local, ".git"), "refs"),
                 "remotes"),
              "origin");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Remote_Dir, "main"), Commit_Id);
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Remote_Dir, "stale"), Commit_Id);

         Assert
           (Version.Remotes.Prune_Dry_Run_Text ("origin") =
              "would prune origin/stale" & Character'Val (10),
            "remote prune --dry-run must report only stale remote-tracking refs");

         Assert
           (Version.Test_Support.Read_Text_File
              (Version.Test_Support.Join (Remote_Dir, "stale")) = Commit_Id,
            "remote prune --dry-run must not delete stale refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Reports_Stale_Local_Tracking_Refs;

   procedure Remote_Prune_Dry_Run_Reports_Stale_Packed_Refs_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Live_Local_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Stale_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
         Packed_Content : constant String :=
           "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
           Live_Local_Id & " refs/remotes/origin/main" & Character'Val (10) &
           Stale_Id & " refs/remotes/origin/stale" & Character'Val (10) &
           Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
           Unrelated_Id & " refs/tags/v1" & Character'Val (10);
      begin
         Version.Test_Support.Write_Text_File (Packed_Path, Packed_Content);

         declare
            Packed_Before : constant String :=
              Version.Files.Read_Binary_File (Packed_Path);
         begin
            Assert
              (Version.Remotes.Prune_Dry_Run_Text ("origin") =
                 "would prune origin/stale" & Character'Val (10),
               "remote prune --dry-run must report only stale packed refs");

            Assert
              (Version.Files.Read_Binary_File (Packed_Path) = Packed_Before,
               "remote prune --dry-run must preserve packed refs byte-for-byte");
         end;

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/main")
            = Live_Local_Id,
            "remote prune --dry-run must preserve live packed refs by branch name");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Reports_Stale_Packed_Refs_Without_Mutation;

   procedure Remote_Prune_Dry_Run_Rejects_Missing_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Unused : constant String :=
              Version.Remotes.Prune_Dry_Run_Text ("origin");
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "remote prune --dry-run must reject missing remotes");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Rejects_Missing_Remote;

   procedure Remote_Prune_Removes_Stale_Local_Tracking_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local, ".git"), "refs"),
                 "remotes"),
              "origin");
         Main_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "main");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File (Main_Path, Commit_Id);
         Version.Test_Support.Write_Text_File (Stale_Path, Commit_Id);

         Assert
           (Version.Remotes.Prune_Text ("origin") =
              "pruned origin/stale" & Character'Val (10),
            "remote prune must report deleted stale remote-tracking refs");

         Assert
           (Ada.Directories.Exists (Main_Path),
            "remote prune must preserve live remote-tracking refs");

         Assert
           (not Ada.Directories.Exists (Stale_Path),
            "remote prune must delete stale remote-tracking refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Removes_Stale_Local_Tracking_Refs;

   procedure Remote_Prune_Ignores_Malformed_Loose_Tracking_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local, ".git"), "refs"),
                 "remotes"),
              "origin");
         Main_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "main");
         Broken_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "broken");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File (Main_Path, Commit_Id);
         Version.Test_Support.Write_Text_File (Broken_Path, "not-an-object-id");

         Assert
           (Version.Remotes.Prune_Text ("origin") = "",
            "remote prune must not report malformed loose tracking refs as stale");

         Assert
           (Ada.Directories.Exists (Main_Path),
            "remote prune must preserve live remote-tracking refs");
         Assert
           (Version.Test_Support.Read_Text_File (Broken_Path) = "not-an-object-id",
            "remote prune must not rewrite malformed loose tracking refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Ignores_Malformed_Loose_Tracking_Refs;

   procedure Remote_Prune_Dry_Run_Ignores_Malformed_Loose_Tracking_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local, ".git"), "refs"),
                 "remotes"),
              "origin");
         Main_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "main");
         Broken_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "broken");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File (Main_Path, Commit_Id);
         Version.Test_Support.Write_Text_File (Broken_Path, "not-an-object-id");

         Assert
           (Version.Remotes.Prune_Dry_Run_Text ("origin") = "",
            "remote prune --dry-run must not report malformed loose tracking refs as stale");

         Assert
           (Ada.Directories.Exists (Main_Path),
            "remote prune --dry-run must preserve live remote-tracking refs");
         Assert
           (Version.Test_Support.Read_Text_File (Broken_Path) = "not-an-object-id",
            "remote prune --dry-run must not rewrite malformed loose tracking refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Ignores_Malformed_Loose_Tracking_Refs;

   procedure Remote_Prune_Rejects_Missing_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         declare
            Unused : constant String :=
              Version.Remotes.Prune_Text ("origin");
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "remote prune must reject missing remotes");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Rejects_Missing_Remote;

   procedure Remote_Prune_Removes_Stale_Packed_Remote_Tracking_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Raw_Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Commit_Id : constant String :=
           Raw_Commit_Id (Raw_Commit_Id'First .. Raw_Commit_Id'First + 39);
         Packed_Path : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join (Local, ".git"), "packed-refs");
      begin
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/main" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/stale" & Character'Val (10) &
            Commit_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
            Commit_Id & " refs/tags/v1" & Character'Val (10));

         Assert
           (Version.Remotes.Prune_Text ("origin") =
              "pruned origin/stale" & Character'Val (10),
            "remote prune must report stale packed remote-tracking refs");

         declare
            Packed_After : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/stale") = 0,
               "remote prune must remove stale packed remote-tracking refs");

            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/main") /= 0,
               "remote prune must preserve live packed remote-tracking refs");

            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/upstream/keep") /= 0,
               "remote prune must preserve unrelated packed remote-tracking refs");

            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/tags/v1") /= 0,
               "remote prune must preserve unrelated packed tag refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Removes_Stale_Packed_Remote_Tracking_Refs;

   procedure Remote_Prune_Dry_Run_Reports_Mixed_Loose_Packed_Duplicates_Once
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Loose_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Packed_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
              "origin");
         Live_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "main");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
         Packed_Content : constant String :=
           "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
           Packed_Id & " refs/remotes/origin/main" & Character'Val (10) &
           Packed_Id & " refs/remotes/origin/stale" & Character'Val (10) &
           Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
           Unrelated_Id & " refs/tags/v1" & Character'Val (10);
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Live_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Stale_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File (Packed_Path, Packed_Content);

         declare
            Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Version.Remotes.Prune_Dry_Run_Text ("origin") =
                 "would prune origin/stale" & Character'Val (10),
               "remote prune --dry-run must report duplicate loose/packed stale refs once");

            Assert
              (Version.Test_Support.Read_Text_File (Stale_Path) = Loose_Id,
               "remote prune --dry-run must preserve duplicate loose stale refs");
            Assert
              (Version.Test_Support.Read_Text_File (Packed_Path) = Packed_Before,
               "remote prune --dry-run must preserve duplicate packed refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Reports_Mixed_Loose_Packed_Duplicates_Once;

   procedure Remote_Prune_Removes_Mixed_Loose_Packed_Duplicates_Once
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Loose_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Packed_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
              "origin");
         Live_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "main");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Live_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Stale_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/main" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/stale" & Character'Val (10) &
            Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
            Unrelated_Id & " refs/tags/v1" & Character'Val (10));

         Assert
           (Version.Remotes.Prune_Text ("origin") =
              "pruned origin/stale" & Character'Val (10),
            "remote prune must report duplicate loose/packed stale refs once");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/main") = Loose_Id,
            "remote prune must preserve live duplicate loose/packed refs");
         Assert
           (not Ada.Directories.Exists (Stale_Path),
            "remote prune must remove duplicate loose stale refs");

         declare
            Packed_After : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/stale") = 0,
               "remote prune must remove duplicate packed stale refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, Packed_Id & " refs/remotes/origin/main") /= 0,
               "remote prune must preserve live duplicate packed refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/upstream/keep") /= 0,
               "remote prune must preserve unrelated packed remote refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/tags/v1") /= 0,
               "remote prune must preserve unrelated packed tag refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Removes_Mixed_Loose_Packed_Duplicates_Once;

   procedure Remote_Prune_Dry_Run_Reports_Nested_Loose_And_Packed_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "feature");
      begin
         Version.Test_Support.Make_Directory (Source_Heads_Dir);
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Source_Heads_Dir, "live"),
            Advertised_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Source_Heads_Dir, "packed-live"),
            Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Loose_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Packed_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Feature_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
                 "origin"),
              "feature");
         Live_Path : constant String :=
           Version.Test_Support.Join (Remote_Feature_Dir, "live");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Feature_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Remote_Feature_Dir);
         Version.Test_Support.Write_Text_File
           (Live_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Stale_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/feature/packed-live" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/feature/packed-stale" & Character'Val (10) &
            Unrelated_Id & " refs/remotes/upstream/feature/keep" & Character'Val (10) &
            Unrelated_Id & " refs/tags/v1" & Character'Val (10));

         Assert
           (Version.Remotes.Prune_Dry_Run_Text ("origin") =
              "would prune origin/feature/packed-stale" & Character'Val (10) &
              "would prune origin/feature/stale" & Character'Val (10),
            "remote prune --dry-run must report nested loose and packed stale refs");

         Assert
           (Version.Test_Support.Read_Text_File (Stale_Path) = Loose_Id,
            "remote prune --dry-run must preserve nested loose stale refs");
         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/feature/live")
            = Loose_Id,
            "remote prune --dry-run must preserve nested live loose refs");
         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/feature/packed-live")
            = Packed_Id,
            "remote prune --dry-run must preserve nested live packed refs");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Reports_Nested_Loose_And_Packed_Refs;

   procedure Remote_Prune_Removes_Nested_Loose_And_Packed_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "feature");
      begin
         Version.Test_Support.Make_Directory (Source_Heads_Dir);
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Source_Heads_Dir, "live"),
            Advertised_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Source_Heads_Dir, "packed-live"),
            Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Loose_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Packed_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Feature_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
                 "origin"),
              "feature");
         Live_Path : constant String :=
           Version.Test_Support.Join (Remote_Feature_Dir, "live");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Feature_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Remote_Feature_Dir);
         Version.Test_Support.Write_Text_File
           (Live_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Stale_Path, Loose_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/feature/packed-live" & Character'Val (10) &
            Packed_Id & " refs/remotes/origin/feature/packed-stale" & Character'Val (10) &
            Unrelated_Id & " refs/remotes/upstream/feature/keep" & Character'Val (10) &
            Unrelated_Id & " refs/tags/v1" & Character'Val (10));

         Assert
           (Version.Remotes.Prune_Text ("origin") =
              "pruned origin/feature/packed-stale" & Character'Val (10) &
              "pruned origin/feature/stale" & Character'Val (10),
            "remote prune must report nested loose and packed stale refs");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/feature/live")
            = Loose_Id,
            "remote prune must preserve nested live loose refs");
         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/feature/packed-live")
            = Packed_Id,
            "remote prune must preserve nested live packed refs");
         Assert
           (not Ada.Directories.Exists (Stale_Path),
            "remote prune must remove nested loose stale refs");

         declare
            Packed_After : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/feature/packed-stale") = 0,
               "remote prune must remove nested packed stale refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/feature/packed-live") /= 0,
               "remote prune must preserve nested packed live refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/upstream/feature/keep") /= 0,
               "remote prune must preserve unrelated nested packed remote refs");
            Assert
              (Ada.Strings.Fixed.Index (Packed_After, "refs/tags/v1") /= 0,
               "remote prune must preserve unrelated packed tag refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Removes_Nested_Loose_And_Packed_Refs;

   procedure Remote_Prune_Preserves_Live_Packed_Ref_With_Different_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String :=
           "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Live_Local_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Stale_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Unrelated_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Live_Local_Id & " refs/remotes/origin/main" & Character'Val (10) &
            Stale_Id & " refs/remotes/origin/stale" & Character'Val (10) &
            Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10));

         Assert
           (Version.Remotes.Prune_Text ("origin") =
              "pruned origin/stale" & Character'Val (10),
            "remote prune must report only stale packed refs");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/main")
            = Live_Local_Id,
            "remote prune must preserve live packed refs by branch name");

         declare
            Packed_After : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After,
                  Live_Local_Id & " refs/remotes/origin/main") /= 0,
               "remote prune must keep the original live packed ref id");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/origin/stale") = 0,
               "remote prune must remove only stale packed refs");
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/upstream/keep") /= 0,
               "remote prune must preserve unrelated packed refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Preserves_Live_Packed_Ref_With_Different_Id;

   procedure Remote_Prune_Packed_Lock_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Source, "git branch -M main");

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Raw_Commit_Id : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Source, ".git"), "refs"),
                    "heads"),
                 "main"));
         Commit_Id : constant String :=
           Raw_Commit_Id (Raw_Commit_Id'First .. Raw_Commit_Id'First + 39);
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
                 "origin"),
              "nested");
         Blocked_Lock : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale-b.lock");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/main" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/stale-a" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/nested/stale-b"
            & Character'Val (10) &
            Commit_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
            Commit_Id & " refs/tags/v1" & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Blocked_Lock, "locked" & Character'Val (10));

         declare
            Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            begin
               declare
                  Unused : constant String := Version.Remotes.Prune_Text ("origin");
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "remote prune packed lock failure must reject transaction");
            Assert
              (Version.Test_Support.Read_Text_File (Packed_Path) = Packed_Before,
               "remote prune packed lock failure must preserve packed refs");
            Assert
              (Ada.Directories.Exists (Blocked_Lock),
               "remote prune packed lock failure must preserve stale lock");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Packed_Lock_Failure_Is_Atomic;

   procedure Remote_Prune_Malformed_Remote_Packed_Refs_Does_Not_Mutate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Remote : constant String := Version.Test_Support.Join (Root, "remote");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Remote);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Remote);
      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Remote);

      declare
         Commit_Id : constant String := "1111111111111111111111111111111111111111";
         Local_Git_Dir : constant String :=
           Version.Test_Support.Join (Local, ".git");
         Remote_Git_Dir : constant String :=
           Version.Test_Support.Join (Remote, ".git");
         Local_Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local_Git_Dir, "refs"), "remotes"),
                 "origin"),
              "nested");
         Loose_Path : constant String :=
           Version.Test_Support.Join (Local_Remote_Dir, "stale");
         Local_Packed_Path : constant String :=
           Version.Test_Support.Join (Local_Git_Dir, "packed-refs");
         Remote_Packed_Path : constant String :=
           Version.Test_Support.Join (Remote_Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Local_Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Loose_Path, Commit_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Local_Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/packed-stale" & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Remote_Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            "not-a-valid-object refs/heads/main" & Character'Val (10));

         declare
            Local_Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Local_Packed_Path);
            Remote_Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Remote_Packed_Path);
         begin
            begin
               declare
                  Unused : constant String := Version.Remotes.Prune_Text ("origin");
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "remote prune must fail on malformed remote packed-refs");
            Assert
              (Ada.Directories.Exists (Loose_Path),
               "failed remote prune must preserve loose tracking refs");
            Assert
              (Version.Test_Support.Read_Text_File (Local_Packed_Path)
               = Local_Packed_Before,
               "failed remote prune must preserve local packed refs");
            Assert
              (Version.Test_Support.Read_Text_File (Remote_Packed_Path)
               = Remote_Packed_Before,
               "failed remote prune must preserve remote packed refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Malformed_Remote_Packed_Refs_Does_Not_Mutate;

   procedure Remote_Prune_Dry_Run_Malformed_Remote_Packed_Refs_Does_Not_Mutate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Remote : constant String := Version.Test_Support.Join (Root, "remote");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Remote);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Remote);
      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Remote);

      declare
         Commit_Id : constant String := "1111111111111111111111111111111111111111";
         Local_Git_Dir : constant String :=
           Version.Test_Support.Join (Local, ".git");
         Remote_Git_Dir : constant String :=
           Version.Test_Support.Join (Remote, ".git");
         Local_Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Local_Git_Dir, "refs"), "remotes"),
                 "origin"),
              "nested");
         Loose_Path : constant String :=
           Version.Test_Support.Join (Local_Remote_Dir, "stale");
         Local_Packed_Path : constant String :=
           Version.Test_Support.Join (Local_Git_Dir, "packed-refs");
         Remote_Packed_Path : constant String :=
           Version.Test_Support.Join (Remote_Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Local_Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Loose_Path, Commit_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Local_Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/packed-stale" & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Remote_Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            "not-a-valid-object refs/heads/main" & Character'Val (10));

         declare
            Local_Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Local_Packed_Path);
            Remote_Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Remote_Packed_Path);
         begin
            begin
               declare
                  Unused : constant String :=
                    Version.Remotes.Prune_Dry_Run_Text ("origin");
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "remote prune --dry-run must fail on malformed remote packed-refs");
            Assert
              (Ada.Directories.Exists (Loose_Path),
               "failed remote prune --dry-run must preserve loose tracking refs");
            Assert
              (Version.Test_Support.Read_Text_File (Local_Packed_Path)
               = Local_Packed_Before,
               "failed remote prune --dry-run must preserve local packed refs");
            Assert
              (Version.Test_Support.Read_Text_File (Remote_Packed_Path)
               = Remote_Packed_Before,
               "failed remote prune --dry-run must preserve remote packed refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Malformed_Remote_Packed_Refs_Does_Not_Mutate;

   procedure Remote_Prune_Discovery_Failure_Does_Not_Mutate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Broken_Remote : constant String := Version.Test_Support.Join (Root, "not-a-repo");
      Local         : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Broken_Remote);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Broken_Remote);

      declare
         Commit_Id : constant String := "1111111111111111111111111111111111111111";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
                 "origin"),
              "nested");
         Loose_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Loose_Path, Commit_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/packed-stale" & Character'Val (10));

         declare
            Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            begin
               declare
                  Unused : constant String := Version.Remotes.Prune_Text ("origin");
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
                  Raised := True;
            end;

            Assert (Raised, "remote prune must fail when remote discovery fails");

            Assert
              (Ada.Directories.Exists (Loose_Path),
               "failed remote prune must preserve loose remote-tracking refs");

            Assert
              (Version.Test_Support.Read_Text_File (Packed_Path) = Packed_Before,
               "failed remote prune must preserve packed-refs exactly");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Discovery_Failure_Does_Not_Mutate;

   procedure Remote_Prune_Dry_Run_Discovery_Failure_Does_Not_Mutate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Broken_Remote : constant String := Version.Test_Support.Join (Root, "not-a-repo");
      Local         : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Broken_Remote);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Broken_Remote);

      declare
         Commit_Id : constant String := "1111111111111111111111111111111111111111";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
                 "origin"),
              "nested");
         Loose_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Loose_Path, Commit_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Packed_Path,
            "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10) &
            Commit_Id & " refs/remotes/origin/packed-stale" & Character'Val (10));

         declare
            Packed_Before : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            begin
               declare
                  Unused : constant String :=
                    Version.Remotes.Prune_Dry_Run_Text ("origin");
               begin
                  null;
               end;
            exception
               when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
                  Raised := True;
            end;

            Assert
              (Raised,
               "remote prune --dry-run must fail when remote discovery fails");

            Assert
              (Ada.Directories.Exists (Loose_Path),
               "failed remote prune --dry-run must preserve loose remote-tracking refs");

            Assert
              (Version.Test_Support.Read_Text_File (Packed_Path) = Packed_Before,
               "failed remote prune --dry-run must preserve packed-refs exactly");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Dry_Run_Discovery_Failure_Does_Not_Mutate;



   procedure Remote_Prune_Rejects_Stale_Expected_Old
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String := "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Old_Id : constant String := "1111111111111111111111111111111111111111";
         New_Id : constant String := "2222222222222222222222222222222222222222";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
              "origin");
         Stale_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "stale");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Stale_Path, Old_Id & Character'Val (10));

         Prune_Hook_Path := To_Unbounded_String (Stale_Path);
         Prune_Hook_Text := To_Unbounded_String (New_Id & Character'Val (10));
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook
           (Advance_Prune_Tracking_Ref'Access);

         begin
            declare
               Unused : constant String := Version.Remotes.Prune_Text ("origin");
            begin
               null;
            end;
         exception
            when Error : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (Error)
                  = Version.Ref_Transaction.Expected_Old_Mismatch_Diagnostic
                      ("refs/remotes/origin/stale"),
                  "remote prune must report expected-old mismatch for stale delete");
         end;

         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);

         Assert
           (Raised,
            "remote prune must reject stale expected-old delete");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/stale") = New_Id,
            "expected-old mismatch must preserve concurrently advanced tracking ref");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Rejects_Stale_Expected_Old;

   procedure Remote_Prune_Expected_Old_Mismatch_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String := "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Changed_Old_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Unchanged_Old_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Changed_New_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Remote_Dir : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
              "origin");
         Changed_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "changed");
         Unchanged_Path : constant String :=
           Version.Test_Support.Join (Remote_Dir, "unchanged");
      begin
         Version.Test_Support.Make_Directory (Remote_Dir);
         Version.Test_Support.Write_Text_File
           (Changed_Path, Changed_Old_Id & Character'Val (10));
         Version.Test_Support.Write_Text_File
           (Unchanged_Path, Unchanged_Old_Id & Character'Val (10));

         Prune_Hook_Path := To_Unbounded_String (Changed_Path);
         Prune_Hook_Text := To_Unbounded_String (Changed_New_Id & Character'Val (10));
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook
           (Advance_Prune_Tracking_Ref'Access);

         begin
            declare
               Unused : constant String := Version.Remotes.Prune_Text ("origin");
            begin
               null;
            end;
         exception
            when Error : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (Error)
                  = Version.Ref_Transaction.Expected_Old_Mismatch_Diagnostic
                      ("refs/remotes/origin/changed"),
                  "remote prune must report the changed stale ref mismatch");
         end;

         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);

         Assert
           (Raised,
            "remote prune must reject multi-ref stale expected-old mismatch");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/changed")
            = Changed_New_Id,
            "expected-old mismatch must preserve the concurrently changed ref");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/unchanged")
            = Unchanged_Old_Id,
            "expected-old mismatch must preserve other stale refs atomically");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Expected_Old_Mismatch_Is_Atomic;

   procedure Remote_Prune_Packed_Expected_Old_Mismatch_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");
      Local  : constant String := Version.Test_Support.Join (Root, "local");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Local);

      Version.Init.Init (Source);

      declare
         Advertised_Id : constant String := "3333333333333333333333333333333333333333";
         Source_Heads : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "heads"),
              "main");
      begin
         Version.Test_Support.Write_Text_File
           (Source_Heads, Advertised_Id & Character'Val (10));
      end;

      Version.Init.Init (Local);
      Ada.Directories.Set_Directory (Local);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => Source);

      declare
         Changed_Old_Id : constant String :=
           "1111111111111111111111111111111111111111";
         Unchanged_Old_Id : constant String :=
           "2222222222222222222222222222222222222222";
         Changed_New_Id : constant String :=
           "4444444444444444444444444444444444444444";
         Unrelated_Id : constant String :=
           "5555555555555555555555555555555555555555";
         Git_Dir : constant String := Version.Test_Support.Join (Local, ".git");
         Packed_Path : constant String :=
           Version.Test_Support.Join (Git_Dir, "packed-refs");
         Packed_Header : constant String :=
           "# pack-refs with: peeled fully-peeled sorted" & Character'Val (10);
         Packed_Before : constant String :=
           Packed_Header &
           Changed_Old_Id & " refs/remotes/origin/changed" & Character'Val (10) &
           Unchanged_Old_Id & " refs/remotes/origin/unchanged" & Character'Val (10) &
           Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
           Unrelated_Id & " refs/tags/v1" & Character'Val (10);
         Packed_Advanced : constant String :=
           Packed_Header &
           Changed_New_Id & " refs/remotes/origin/changed" & Character'Val (10) &
           Unchanged_Old_Id & " refs/remotes/origin/unchanged" & Character'Val (10) &
           Unrelated_Id & " refs/remotes/upstream/keep" & Character'Val (10) &
           Unrelated_Id & " refs/tags/v1" & Character'Val (10);
      begin
         Version.Test_Support.Write_Text_File (Packed_Path, Packed_Before);

         Prune_Hook_Path := To_Unbounded_String (Packed_Path);
         Prune_Hook_Text := To_Unbounded_String (Packed_Advanced);
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook
           (Advance_Prune_Tracking_Ref'Access);

         begin
            declare
               Unused : constant String := Version.Remotes.Prune_Text ("origin");
            begin
               null;
            end;
         exception
            when Error : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (Error)
                  = Version.Ref_Transaction.Expected_Old_Mismatch_Diagnostic
                      ("refs/remotes/origin/changed"),
                  "remote prune must report the changed packed ref mismatch");
         end;

         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);

         Assert
           (Raised,
            "remote prune must reject packed stale expected-old mismatch");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/changed")
            = Changed_New_Id,
            "packed expected-old mismatch must preserve changed packed ref");

         Assert
           (Version.Refs.Resolve_Ref
              (Version.Repository.Open, "refs/remotes/origin/unchanged")
            = Unchanged_Old_Id,
            "packed expected-old mismatch must preserve other stale refs atomically");

         declare
            Packed_After : constant String :=
              Version.Test_Support.Read_Text_File (Packed_Path);
         begin
            Assert
              (Ada.Strings.Fixed.Index
                 (Packed_After, "refs/remotes/upstream/keep") /= 0,
               "packed expected-old mismatch must preserve unrelated remote refs");
            Assert
              (Ada.Strings.Fixed.Index (Packed_After, "refs/tags/v1") /= 0,
               "packed expected-old mismatch must preserve unrelated tag refs");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Remotes.Test_Hooks.Set_Prune_Before_Delete_Hook (null);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Prune_Packed_Expected_Old_Mismatch_Is_Atomic;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Add_And_List_Remote'Access,
         "Remotes: add and list");

      Register_Routine
         (T,
            Add_Remote_Rejects_Duplicate'Access,
            "Remotes: reject duplicate add");

      Register_Routine
         (T,
            Delete_Remote_Rejects_Missing'Access,
            "Remotes: reject missing delete");

      Register_Routine
        (T,
         Remote_List_Text_Is_Stable_And_Read_Only'Access,
         "Remotes: list text is stable and read-only");

      Register_Routine
        (T,
         Remote_Get_Url_Prints_Only_Selected_Url'Access,
         "Remotes: get-url prints only selected URL");

      Register_Routine
        (T,
         Remote_Get_Url_Rejects_Missing'Access,
         "Remotes: get-url rejects missing remote");

      Register_Routine
        (T,
         Remote_Get_Url_Is_Read_Only'Access,
         "Remotes: get-url is read-only");

      Register_Routine
        (T,
         Remote_Exists_Returns_True_For_Configured_Remote'Access,
         "Remotes: exists returns true for configured remote");

      Register_Routine
        (T,
         Remote_Exists_Returns_False_For_Missing_Remote'Access,
         "Remotes: exists returns false for missing remote");

      Register_Routine
        (T,
         Remote_Exists_Rejects_Invalid_Name'Access,
         "Remotes: exists rejects invalid name");

      Register_Routine
        (T,
         Remote_Exists_Is_Read_Only'Access,
         "Remotes: exists is read-only");

      Register_Routine
        (T,
         Remote_Set_Url_Updates_Existing_Remote'Access,
         "Remotes: set-url updates existing remote");

      Register_Routine
        (T,
         Remote_Set_Url_Rejects_Missing'Access,
         "Remotes: set-url rejects missing remote");

      Register_Routine
        (T,
         Remote_Set_Url_Does_Not_Create_New_Remote'Access,
         "Remotes: set-url does not create missing remote");

      Register_Routine
        (T,
         Remote_Rename_Updates_Existing_Remote'Access,
         "Remotes: rename updates existing remote");

      Register_Routine
        (T,
         Remote_Rename_Rejects_Missing_Source'Access,
         "Remotes: rename rejects missing source");

      Register_Routine
        (T,
         Remote_Rename_Rejects_Destination_Collision'Access,
         "Remotes: rename rejects destination collision");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Reports_Stale_Local_Tracking_Refs'Access,
         "Remotes: prune dry-run reports stale local tracking refs");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Reports_Stale_Packed_Refs_Without_Mutation'Access,
         "Remotes: prune dry-run reports stale packed refs without mutation");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Reports_Mixed_Loose_Packed_Duplicates_Once'Access,
         "Remotes: prune dry-run reports mixed loose packed duplicates once");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Reports_Nested_Loose_And_Packed_Refs'Access,
         "Remotes: prune dry-run reports nested loose and packed refs");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Rejects_Missing_Remote'Access,
         "Remotes: prune dry-run rejects missing remote");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Ignores_Malformed_Loose_Tracking_Refs'Access,
         "Remotes: prune dry-run ignores malformed loose tracking refs");

      Register_Routine
        (T,
         Remote_Prune_Removes_Stale_Local_Tracking_Refs'Access,
         "Remotes: prune removes stale local tracking refs");

      Register_Routine
        (T,
         Remote_Prune_Ignores_Malformed_Loose_Tracking_Refs'Access,
         "Remotes: prune ignores malformed loose tracking refs");

      Register_Routine
        (T,
         Remote_Prune_Removes_Stale_Packed_Remote_Tracking_Refs'Access,
         "Remotes: prune removes stale packed remote tracking refs");

      Register_Routine
        (T,
         Remote_Prune_Removes_Mixed_Loose_Packed_Duplicates_Once'Access,
         "Remotes: prune removes mixed loose packed duplicates once");

      Register_Routine
        (T,
         Remote_Prune_Removes_Nested_Loose_And_Packed_Refs'Access,
         "Remotes: prune removes nested loose and packed refs");

      Register_Routine
        (T,
         Remote_Prune_Preserves_Live_Packed_Ref_With_Different_Id'Access,
         "Remotes: prune preserves live packed ref with different id");

      Register_Routine
        (T,
         Remote_Prune_Packed_Lock_Failure_Is_Atomic'Access,
         "Remotes: prune packed lock failure is atomic");

      Register_Routine
        (T,
         Remote_Prune_Malformed_Remote_Packed_Refs_Does_Not_Mutate'Access,
         "Remotes: prune malformed remote packed refs does not mutate refs");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Malformed_Remote_Packed_Refs_Does_Not_Mutate'Access,
         "Remotes: prune dry-run malformed remote packed refs does not mutate refs");

      Register_Routine
        (T,
         Remote_Prune_Discovery_Failure_Does_Not_Mutate'Access,
         "Remotes: prune discovery failure does not mutate refs");

      Register_Routine
        (T,
         Remote_Prune_Dry_Run_Discovery_Failure_Does_Not_Mutate'Access,
         "Remotes: prune dry-run discovery failure does not mutate refs");



      Register_Routine
        (T,
         Remote_Prune_Rejects_Stale_Expected_Old'Access,
         "Remotes: prune rejects stale expected-old delete");

      Register_Routine
        (T,
         Remote_Prune_Expected_Old_Mismatch_Is_Atomic'Access,
         "Remotes: prune expected-old mismatch is atomic");

      Register_Routine
        (T,
         Remote_Prune_Packed_Expected_Old_Mismatch_Is_Atomic'Access,
         "Remotes: prune packed expected-old mismatch is atomic");

      Register_Routine
        (T,
         Remote_Prune_Rejects_Missing_Remote'Access,
         "Remotes: prune rejects missing remote");

   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Remotes");
   end Name;

end Version.Remotes.Tests;
