with Ada.Directories;
with Ada.IO_Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Files;
with Version.Git_Fixtures;
with Version.Gitmodules;
with Version.Init;
with Version.Objects; use Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Remotes;
with Version.Sparse;
with Version.Staging;
with Version.Test_Support;
with Version.Write;
with Version.Worktrees;

package body Version.Submodules.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   Commit_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id
       ("1111111111111111111111111111111111111111");

   function Join (Left, Right : String) return String
   renames Version.Test_Support.Join;

   procedure Configure_User (Root : String) is
   begin
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_User;

   function Create_Submodule_Source
     (Root : String; Text : String) return Version.Objects.Hex_Object_Id
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Ada.Directories.Create_Path (Root);
      Version.Init.Init (Root);
      Configure_User (Root);
      Version.Test_Support.Write_Text_File
        (Join (Root, "payload.txt"), Text & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add payload.txt");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("submodule source");
      declare
         Commit : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Ada.Directories.Set_Directory (Old_Dir);
         return Version.Objects.To_Object_Id (Commit);
      end;
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Create_Submodule_Source;

   procedure Add_Gitlink
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
   is
      Entries : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Entries.Append
        (Version.Staging.Index_Entry'
           (Path => To_Unbounded_String ("deps/libfoo"),
            Id   => Id,
            Mode => To_Unbounded_String ("160000"),
            Stage => 0, Skip_Worktree => False));
      Version.Staging.Write (Repo => Repo, Entries => Entries);
   end Add_Gitlink;

   procedure Configure_Submodule (Root : String; Url : String) is
      Items : Version.Gitmodules.Submodule_Config_Vectors.Vector;
   begin
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String (Url)));
      Version.Gitmodules.Write (Root, Items);
   end Configure_Submodule;

   procedure Assert_Submodule_Update_Resolves_Relative_Url
     (Root       : String;
      Remote_Url : String;
      Relative   : String;
      Source     : String;
      Expected   : String)
   is
      Commit  : constant Version.Objects.Hex_Object_Id :=
        Create_Submodule_Source (Source, Expected);
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_Submodule (Root, Relative);
      Ada.Directories.Create_Path (Join (Root, "deps"));

      Ada.Directories.Set_Directory (Root);
      Version.Remotes.Add_Remote (Name => "origin", Url => Remote_Url);
      Add_Gitlink (Version.Repository.Open, Commit);
      Version.Submodules.Update (Version.Repository.Open, Recursive => False);

      Assert
        (Version.Test_Support.Read_Text_File
           (Join (Join (Root, "deps/libfoo"), "payload.txt"))
         = Expected,
         "relative submodule URL must resolve to the intended local repository");
      Version.Git_Fixtures.Run
        (Join (Root, "deps/libfoo"),
         "test ""$(git rev-parse HEAD)"" = """ & To_String (Commit) & """");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Assert_Submodule_Update_Resolves_Relative_Url;

   procedure Gitmodules_Parse_And_Write
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items     : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Read_Back : Version.Gitmodules.Submodule_Config_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("file:///tmp/libfoo.git")));

      Version.Gitmodules.Write (Root, Items);
      Read_Back := Version.Gitmodules.Read (Root);

      Assert
        (Natural (Read_Back.Length) = 1, ".gitmodules must contain one item");
      Assert
        (To_String (Read_Back.Element (Read_Back.First_Index).Path)
         = "deps/libfoo",
         ".gitmodules path should round-trip");
      Assert
        (To_String (Read_Back.Element (Read_Back.First_Index).Url)
         = "file:///tmp/libfoo.git",
         ".gitmodules url should round-trip");
   end Gitmodules_Parse_And_Write;

   procedure Gitmodules_Rejects_Duplicate_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Root, ".gitmodules"),
         Content =>
           "[submodule ""a""]"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/libfoo"
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/a.git"
           & Character'Val (10)
           & "[submodule ""b""]"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/libfoo"
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/b.git"
           & Character'Val (10));

      begin
         declare
            Items :
              constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
                Version.Gitmodules.Read (Root);
         begin
            Assert
              (Natural (Items.Length) = 0,
               "duplicate parser should not return items");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "duplicate submodule path must be rejected");
   end Gitmodules_Rejects_Duplicate_Path;

   procedure Gitmodules_Normalizes_Path_Separators
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Root, ".gitmodules"),
         Content =>
           "[submodule ""deps/libfoo""]"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps\libfoo"
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/libfoo.git"
           & Character'Val (10));

      declare
         Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
           Version.Gitmodules.Read (Root);
      begin
         Assert
           (Natural (Items.Length) = 1,
            ".gitmodules parser should keep normalized item");
         Assert
           (To_String (Items.Element (Items.First_Index).Path) = "deps/libfoo",
            ".gitmodules parser should canonicalize submodule paths");
         Assert
           (Version.Gitmodules.Find_By_Path (Items, "deps\libfoo")
            /= Natural'Last,
            ".gitmodules path lookup should canonicalize input paths");
      end;
   end Gitmodules_Normalizes_Path_Separators;

   procedure Gitmodules_Reads_CRLF_And_Tab_Indented_Config
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Root, ".gitmodules"),
         Content =>
           "[submodule ""deps/libfoo""]"
           & Character'Val (13)
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/libfoo"
           & Character'Val (13)
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/libfoo.git"
           & Character'Val (13)
           & Character'Val (10));

      declare
         Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
           Version.Gitmodules.Read (Root);
      begin
         Assert
           (Natural (Items.Length) = 1,
            ".gitmodules parser should accept CRLF config files");
         Assert
           (To_String (Items.Element (Items.First_Index).Path) = "deps/libfoo",
            ".gitmodules parser should trim CR and tab indentation");
      end;
   end Gitmodules_Reads_CRLF_And_Tab_Indented_Config;

   procedure Gitmodules_Accepts_Semicolon_Comments
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Version.Init.Init (Root);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Root, ".gitmodules"),
         Content =>
           "; ordinary git-config comment"
           & Character'Val (10)
           & "[submodule ""deps/libfoo""]"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/libfoo"
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/libfoo.git"
           & Character'Val (10));

      declare
         Items : constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
           Version.Gitmodules.Read (Root);
      begin
         Assert
           (Natural (Items.Length) = 1,
            ".gitmodules parser should accept semicolon comments");
      end;
   end Gitmodules_Accepts_Semicolon_Comments;

   procedure Gitmodules_Rejects_Duplicate_Keys
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Root, ".gitmodules"),
         Content =>
           "[submodule ""deps/libfoo""]"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/libfoo"
           & Character'Val (10)
           & Character'Val (9)
           & "path = deps/other"
           & Character'Val (10)
           & Character'Val (9)
           & "url = file:///tmp/libfoo.git"
           & Character'Val (10));

      begin
         declare
            Items :
              constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
                Version.Gitmodules.Read (Root);
         begin
            Assert
              (Natural (Items.Length) = 0,
               "duplicate-key parser should not return items");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, ".gitmodules duplicate keys must be rejected");
   end Gitmodules_Rejects_Duplicate_Keys;

   procedure Gitmodules_Rejects_Control_Characters
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items  : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  =>
              To_Unbounded_String
                ("file:///tmp/libfoo.git" & Character'Val (9) & "x")));

      begin
         Version.Gitmodules.Write (Root, Items);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         ".gitmodules writer must reject control characters in values");
   end Gitmodules_Rejects_Control_Characters;

   procedure Gitmodules_Write_Rejects_Config_Injection
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items  : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo""bad"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("file:///tmp/libfoo.git")));

      begin
         Version.Gitmodules.Write (Root, Items);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, ".gitmodules writer must reject section-name injection");
   end Gitmodules_Write_Rejects_Config_Injection;

   procedure Submodule_Update_Rejects_Relative_Url_Without_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items  : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Raised : Boolean := False;

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         begin
            Version.Submodules.Update (Repo, Recursive => False);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("../libfoo.git")));
      Version.Gitmodules.Write (Root, Items);

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert
        (Raised,
         "relative submodule URLs without a superproject remote must be rejected before mutation");
   end Submodule_Update_Rejects_Relative_Url_Without_Remote;

   procedure Submodule_Update_Rejects_Escaping_Relative_Url_With_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items  : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Raised : Boolean := False;

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Version.Remotes.Add_Remote
           (Name => "origin", Url => "git@example.com:group/super.git");

         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         begin
            Version.Submodules.Update (Repo, Recursive => False);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("../../../evil.git")));
      Version.Gitmodules.Write (Root, Items);

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert
        (Raised,
         "escaping relative submodule URLs must be rejected before mutation");
   end Submodule_Update_Rejects_Escaping_Relative_Url_With_Remote;

   procedure Submodule_Update_Resolves_Local_Dot_Dot_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String := Join (Join (Root, "remotes"), "super.git");
      Source : constant String := Join (Root, "libfoo.git");
   begin
      Ada.Directories.Create_Path (Join (Root, "remotes"));
      Assert_Submodule_Update_Resolves_Relative_Url
        (Root       => Root,
         Remote_Url => Remote,
         Relative   => "../libfoo.git",
         Source     => Source,
         Expected   => "local dotdot");
   end Submodule_Update_Resolves_Local_Dot_Dot_Relative_Url;

   procedure Submodule_Update_Resolves_File_Dot_Dot_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String :=
        "file://" & Join (Join (Root, "remotes"), "super.git");
      Source : constant String := Join (Root, "libfoo.git");
   begin
      Ada.Directories.Create_Path (Join (Root, "remotes"));
      Assert_Submodule_Update_Resolves_Relative_Url
        (Root       => Root,
         Remote_Url => Remote,
         Relative   => "../libfoo.git",
         Source     => Source,
         Expected   => "file dotdot");
   end Submodule_Update_Resolves_File_Dot_Dot_Relative_Url;

   procedure Submodule_Update_Resolves_Dot_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String := Join (Join (Root, "remotes"), "super.git");
      Source : constant String :=
        Join (Join (Join (Root, "remotes"), "deps"), "libfoo.git");
   begin
      Ada.Directories.Create_Path (Join (Root, "remotes"));
      Assert_Submodule_Update_Resolves_Relative_Url
        (Root       => Root,
         Remote_Url => Remote,
         Relative   => "./deps/libfoo.git",
         Source     => Source,
         Expected   => "local dot");
   end Submodule_Update_Resolves_Dot_Relative_Url;

   procedure Submodule_Resolver_Handles_Https_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "https://example.com/group/super.git")
         = "https://example.com/libfoo.git",
         "https relative submodule URLs must resolve against remote directory");
   end Submodule_Resolver_Handles_Https_Relative_Url;

   procedure Submodule_Resolver_Handles_Ssh_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "ssh://git@example.com/group/super.git")
         = "ssh://git@example.com/libfoo.git",
         "ssh:// relative submodule URLs must resolve against remote directory");
   end Submodule_Resolver_Handles_Ssh_Relative_Url;

   procedure Submodule_Resolver_Handles_Scp_Like_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "git@example.com:group/super.git")
         = "git@example.com:libfoo.git",
         "scp-like relative submodule URLs must resolve against remote directory");
   end Submodule_Resolver_Handles_Scp_Like_Relative_Url;

   procedure Submodule_Resolver_Handles_Deeper_Legal_Traversal
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../../shared/libfoo.git",
            Base_Url     => "ssh://git@example.com/company/group/super.git")
         = "ssh://git@example.com/shared/libfoo.git",
         "deeper legal relative traversal must remain inside the remote root");
   end Submodule_Resolver_Handles_Deeper_Legal_Traversal;

   procedure Submodule_Resolver_Rejects_Scp_Escape
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignored : constant String :=
              Version.Submodules.Resolve_Relative_Submodule_Url
                (Relative_Url => "../../evil.git",
                 Base_Url     => "git@example.com:group/super.git");
         begin
            Assert (Ignored'Length = 0, "unreachable resolved escaped URL");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "scp-like relative URL escape must be rejected");
   end Submodule_Resolver_Rejects_Scp_Escape;

   procedure Assert_Resolver_Raises
     (Relative_Url : String; Base_Url : String; Message : String)
   is
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignored : constant String :=
              Version.Submodules.Resolve_Relative_Submodule_Url
                (Relative_Url => Relative_Url, Base_Url => Base_Url);
         begin
            Assert (Ignored'Length = 0, "unreachable resolved URL");
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, Message);
   end Assert_Resolver_Raises;

   procedure Submodule_Resolver_Handles_Https_Base_Without_Git_Suffix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "https://example.com/group/super")
         = "https://example.com/libfoo.git",
         "https bases without .git suffix must resolve against remote directory");
   end Submodule_Resolver_Handles_Https_Base_Without_Git_Suffix;

   procedure Submodule_Resolver_Handles_Https_Base_With_Trailing_Slash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "https://example.com/group/super.git/")
         = "https://example.com/libfoo.git",
         "trailing slash on https base must not make the repo name a directory base");
   end Submodule_Resolver_Handles_Https_Base_With_Trailing_Slash;

   procedure Submodule_Resolver_Handles_Ssh_Base_Without_Git_Suffix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "ssh://git@example.com/group/super")
         = "ssh://git@example.com/libfoo.git",
         "ssh bases without .git suffix must resolve against remote directory");
   end Submodule_Resolver_Handles_Ssh_Base_Without_Git_Suffix;

   procedure Submodule_Resolver_Handles_Scp_Base_Without_Git_Suffix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "git@example.com:group/super")
         = "git@example.com:libfoo.git",
         "scp-like bases without .git suffix must resolve against remote directory");
   end Submodule_Resolver_Handles_Scp_Base_Without_Git_Suffix;

   procedure Submodule_Resolver_Normalizes_Dot_Then_Dot_Dot
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "./../libfoo.git",
            Base_Url     => "https://example.com/group/super.git")
         = "https://example.com/libfoo.git",
         "./../ relative URLs must normalize safely inside the remote root");
   end Submodule_Resolver_Normalizes_Dot_Then_Dot_Dot;

   procedure Submodule_Resolver_Rejects_Excessive_Traversal_By_Scheme
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Resolver_Raises
        (Relative_Url => "../../../evil.git",
         Base_Url     => "https://example.com/group/super.git",
         Message      => "excessive https traversal must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => "../../../evil.git",
         Base_Url     => "ssh://git@example.com/group/super.git",
         Message      => "excessive ssh traversal must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => "../../../../evil.git",
         Base_Url     => "file:///srv/git/group/super.git",
         Message      => "excessive file traversal must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => "../../../../evil.git",
         Base_Url     => "/srv/git/group/super.git",
         Message      => "excessive local traversal must be rejected");
   end Submodule_Resolver_Rejects_Excessive_Traversal_By_Scheme;

   procedure Submodule_Resolver_Rejects_Malformed_And_Empty_Bases
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Resolver_Raises
        (Relative_Url => "../libfoo.git",
         Base_Url     => "",
         Message      =>
           "empty base URL must be rejected for relative submodule URLs");
      Assert_Resolver_Raises
        (Relative_Url => "../libfoo.git",
         Base_Url     => "https://example.com",
         Message      => "pathless https base URL must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => "../libfoo.git",
         Base_Url     => "ssh://git@example.com",
         Message      => "pathless ssh base URL must be rejected");
   end Submodule_Resolver_Rejects_Malformed_And_Empty_Bases;

   procedure Gitmodules_Rejects_Malicious_Submodule_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Write_And_Expect_Rejection
        (Path_Text : String; Message : String)
      is
         Raised : Boolean := False;
      begin
         Version.Files.Write_Binary_File
           (Path    => Version.Files.Join (Root, ".gitmodules"),
            Content =>
              "[submodule ""bad""]"
              & Character'Val (10)
              & Character'Val (9)
              & "path = "
              & Path_Text
              & Character'Val (10)
              & Character'Val (9)
              & "url = file:///tmp/libfoo.git"
              & Character'Val (10));

         begin
            declare
               Items :
                 constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
                   Version.Gitmodules.Read (Root);
            begin
               Assert
                 (Natural (Items.Length) = 0,
                  "unsafe parser should not return items");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, Message);
      end Write_And_Expect_Rejection;
   begin
      Version.Init.Init (Root);
      Write_And_Expect_Rejection
        ("../escape", "escaping submodule path must be rejected");
      Write_And_Expect_Rejection
        ("/absolute", "absolute submodule path must be rejected");
      Write_And_Expect_Rejection
        (".git/hooks/post-checkout",
         "submodule path inside .git must be rejected");
   end Gitmodules_Rejects_Malicious_Submodule_Paths;

   procedure Submodule_Resolver_Handles_Backslash_Relative_Url
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => ".\deps\libfoo.git",
            Base_Url     => "https://example.com/group/super.git")
         = "https://example.com/group/deps/libfoo.git",
         "backslash relative URL separators must normalize before resolution");
   end Submodule_Resolver_Handles_Backslash_Relative_Url;

   procedure Submodule_Resolver_Rejects_Backslash_Escape
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Resolver_Raises
        (Relative_Url => "..\..\evil.git",
         Base_Url     => "git@example.com:group/super.git",
         Message      =>
           "backslash traversal must be treated as relative traversal");
   end Submodule_Resolver_Rejects_Backslash_Escape;

   procedure Submodule_Resolver_Rejects_Empty_Relative_Component
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Resolver_Raises
        (Relative_Url => "./deps//libfoo.git",
         Base_Url     => "https://example.com/group/super.git",
         Message      => "relative URL empty components must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => ".\deps\\libfoo.git",
         Base_Url     => "ssh://git@example.com/group/super.git",
         Message      => "backslash duplicate separators must be rejected");
   end Submodule_Resolver_Rejects_Empty_Relative_Component;

   procedure Submodule_Resolver_Rejects_Control_Characters
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Resolver_Raises
        (Relative_Url => "./deps" & Character'Val (10) & "libfoo.git",
         Base_Url     => "https://example.com/group/super.git",
         Message      =>
           "control characters in relative URLs must be rejected");
      Assert_Resolver_Raises
        (Relative_Url => "../libfoo.git",
         Base_Url     =>
           "https://example.com/group" & Character'Val (10) & "/super.git",
         Message      => "control characters in base URLs must be rejected");
   end Submodule_Resolver_Rejects_Control_Characters;

   procedure Submodule_Resolver_Handles_Ssh_Base_With_Port
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "../libfoo.git",
            Base_Url     => "ssh://git@example.com:2222/group/super.git")
         = "ssh://git@example.com:2222/libfoo.git",
         "ssh bases with explicit ports must preserve authority while resolving path");
   end Submodule_Resolver_Handles_Ssh_Base_With_Port;

   procedure Submodule_Resolver_Preserves_Absolute_Urls
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "https://example.com/other/libfoo.git",
            Base_Url     => "https://example.com/group/super.git")
         = "https://example.com/other/libfoo.git",
         "absolute https submodule URLs must not be rewritten");
      Assert
        (Version.Submodules.Resolve_Relative_Submodule_Url
           (Relative_Url => "git@example.com:other/libfoo.git",
            Base_Url     => "git@example.com:group/super.git")
         = "git@example.com:other/libfoo.git",
         "absolute scp-like submodule URLs must not be rewritten");
   end Submodule_Resolver_Preserves_Absolute_Urls;

   procedure Gitmodules_Rejects_More_Malicious_Submodule_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Write_And_Expect_Rejection
        (Path_Text : String; Message : String)
      is
         Raised : Boolean := False;
      begin
         Version.Files.Write_Binary_File
           (Path    => Version.Files.Join (Root, ".gitmodules"),
            Content =>
              "[submodule ""bad""]"
              & Character'Val (10)
              & Character'Val (9)
              & "path = "
              & Path_Text
              & Character'Val (10)
              & Character'Val (9)
              & "url = file:///tmp/libfoo.git"
              & Character'Val (10));

         begin
            declare
               Items :
                 constant Version.Gitmodules.Submodule_Config_Vectors.Vector :=
                   Version.Gitmodules.Read (Root);
            begin
               Assert
                 (Natural (Items.Length) = 0,
                  "unsafe parser should not return items");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, Message);
      end Write_And_Expect_Rejection;
   begin
      Version.Init.Init (Root);
      Write_And_Expect_Rejection
        ("a/../../escape", "nested escaping submodule path must be rejected");
      Write_And_Expect_Rejection
        ("deps//libfoo", "empty component submodule path must be rejected");
      Write_And_Expect_Rejection
        ("C:/escape", "Windows drive submodule path must be rejected");
      Write_And_Expect_Rejection
        ("..\escape", "backslash traversal submodule path must be rejected");
   end Gitmodules_Rejects_More_Malicious_Submodule_Paths;

   procedure Tree_Writer_Preserves_Gitlink_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         declare
            Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo, Entries);
            Flat    : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Flatten_Tree (Repo, Tree_Id);
         begin
            Assert (Natural (Flat.Length) = 1, "tree must contain gitlink");
            Assert
              (Flat.Element (Flat.First_Index).Kind
               = Version.Objects.Tree_Gitlink,
               "tree parser must expose gitlink kind");
            Assert
              (To_String (Flat.Element (Flat.First_Index).Mode) = "160000",
               "tree writer must preserve 160000 mode");
         end;
      end Check;

   begin
      Version.Init.Init (Root);
      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Tree_Writer_Preserves_Gitlink_Mode;

   procedure Stage_Submodule_Updates_Gitlink
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);
         Assert
           (Version.Submodules.Is_Submodule_Path (Repo, "deps/libfoo"),
            "gitlink index entry should be treated as submodule path");
         Assert
           (Version.Submodules.Gitlink_Commit (Repo, "deps/libfoo")
            = Commit_Id,
            "gitlink commit lookup should read index commit id");
      end Check;

   begin
      Version.Init.Init (Root);
      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Stage_Submodule_Updates_Gitlink;

   procedure Submodule_Public_APIs_Normalize_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         Assert
           (Version.Submodules.Is_Submodule_Path (Repo, "deps\libfoo"),
            "submodule path lookup should normalize separators");
         Assert
           (Version.Submodules.Gitlink_Commit (Repo, "deps\libfoo")
            = Commit_Id,
            "gitlink commit lookup should normalize separators");
      end Check;

   begin
      Version.Init.Init (Root);
      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Submodule_Public_APIs_Normalize_Path;

   procedure Submodule_Head_Resolves_Attached_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Git_Path : constant String := Version.Files.Join (Sub_Path, ".git");

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Submodules.Submodule_Head (Repo, "deps/libfoo")
            = Commit_Id,
            "submodule HEAD reader must resolve attached branch refs");
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Git_Path));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "HEAD"),
         Content => "ref: refs/heads/main" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "refs/heads/main"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Submodule_Head_Resolves_Attached_Ref;

   procedure Submodule_Head_Resolves_Tab_Separated_Attached_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Git_Path : constant String := Version.Files.Join (Sub_Path, ".git");

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Submodules.Submodule_Head (Repo, "deps/libfoo")
            = Commit_Id,
            "submodule HEAD reader should trim tab-separated refs");
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Git_Path));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "HEAD"),
         Content =>
           "ref:"
           & Character'Val (9)
           & "refs/heads/main"
           & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "refs/heads/main"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Submodule_Head_Resolves_Tab_Separated_Attached_Ref;

   procedure Submodule_Head_Resolves_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Admin    : constant String :=
        Version.Files.Join (Root, ".git/modules/deps/libfoo");

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Submodules.Submodule_Head (Repo, "deps/libfoo")
            = Commit_Id,
            "submodule HEAD reader must trim .git gitdir files");
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Sub_Path));
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Admin));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Sub_Path, ".git"),
         Content =>
           "gitdir:"
           & Character'Val (9)
           & Admin
           & " "
           & Character'Val (9)
           & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Admin, "HEAD"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Submodule_Head_Resolves_Gitdir_File;

   procedure Linked_Worktree_Update_Uses_Linked_Submodule_Admin
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Root & "-submodule-source";
      Work   : constant String := Root & "-linked";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commit  : constant Version.Objects.Hex_Object_Id :=
        Create_Submodule_Source (Source, "linked submodule");
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Configure_Submodule (Root, Source);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Join (Root, "deps")));

      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "git add .gitmodules");
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000 "
         & To_String (Commit) & " deps/libfoo");
      Version.Write.Save ("submodule gitlink");
      Version.Git_Fixtures.Run (Root, "git branch feature");
      Version.Worktrees.Add (Path => Work, Branch => "feature");

      declare
         Linked_Git_Dir : constant String :=
           Version.Repository.Resolve_Git_Dir (Work);
         Linked_Admin : constant String :=
           Join (Linked_Git_Dir, "modules/deps/libfoo");
         Primary_Admin : constant String :=
           Join (Root, ".git/modules/deps/libfoo");

         procedure Update_Linked is
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            Version.Submodules.Update (Repo, Recursive => False);
            Assert
              (Version.Submodules.Submodule_Head (Repo, "deps/libfoo") = Commit,
               "linked submodule update must resolve the checked-out commit");
         end Update_Linked;
      begin
         Version.Files.With_Directory (Work, Update_Linked'Access);

         Assert
           (Ada.Directories.Exists
              (Version.Files.To_Native_Path (Version.Files.Join (Linked_Admin, "HEAD"))),
            "linked submodule update must create admin storage under linked git dir");
         Assert
           (not Ada.Directories.Exists (Version.Files.To_Native_Path (Primary_Admin)),
            "linked submodule update must not create primary submodule admin storage");
      end;

      Version.Git_Fixtures.Run (Root, "git worktree remove --force '" & Work & "'");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         if Ada.Directories.Current_Directory /= Old_Dir then
            Ada.Directories.Set_Directory (Old_Dir);
         end if;
         raise;
   end Linked_Worktree_Update_Uses_Linked_Submodule_Admin;

   procedure Submodule_Head_Resolves_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Git_Path : constant String := Version.Files.Join (Sub_Path, ".git");

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert
           (Version.Submodules.Submodule_Head (Repo, "deps/libfoo")
            = Commit_Id,
            "submodule HEAD reader must resolve packed branch refs");
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Git_Path));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "HEAD"),
         Content => "ref: refs/heads/main" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "packed-refs"),
         Content =>
           "# pack-refs with: peeled fully-peeled sorted"
           & Character'Val (10)
           & To_String (Commit_Id)
           & " refs/heads/main"
           & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Submodule_Head_Resolves_Packed_Ref;

   procedure Submodule_Head_Rejects_Malformed_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Git_Path : constant String := Version.Files.Join (Sub_Path, ".git");
      Raised   : Boolean := False;

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         begin
            declare
               Ignored : constant String :=
                 Version.Submodules.Submodule_Head (Repo, "deps/libfoo");
            begin
               Assert (Ignored = "", "malformed packed ref must not resolve");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Git_Path));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "HEAD"),
         Content => "ref: refs/heads/main" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "packed-refs"),
         Content =>
           "# pack-refs with: peeled fully-peeled sorted"
           & Character'Val (10)
           & "not-a-valid-object refs/heads/main"
           & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert (Raised, "malformed submodule packed ref must raise Data_Error");
   end Submodule_Head_Rejects_Malformed_Packed_Ref;

   procedure Submodule_Head_Rejects_Unrelated_Malformed_Packed_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Git_Path : constant String := Version.Files.Join (Sub_Path, ".git");
      Raised   : Boolean := False;

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         begin
            declare
               Ignored : constant String :=
                 Version.Submodules.Submodule_Head (Repo, "deps/libfoo");
            begin
               Assert
                 (Ignored = "",
                  "unrelated malformed packed ref must not be ignored");
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Git_Path));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "HEAD"),
         Content => "ref: refs/heads/main" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Git_Path, "packed-refs"),
         Content =>
           "# pack-refs with: peeled fully-peeled sorted"
           & Character'Val (10)
           & To_String (Commit_Id) & " refs/heads/main" & Character'Val (10)
           & "not-a-valid-object refs/tags/bad"
           & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert
        (Raised,
         "unrelated malformed submodule packed ref must raise Data_Error");
   end Submodule_Head_Rejects_Unrelated_Malformed_Packed_Ref;

   procedure Submodule_Head_Rejects_Escaping_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      External : constant String :=
        Version.Files.Join (Root, "external-admin");
      Raised   : Boolean := False;

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : Unbounded_String;
      begin
         Head :=
           To_Unbounded_String
             (Version.Submodules.Submodule_Head (Repo, "deps/libfoo"));
         Assert (Length (Head) = 0, "escaping gitdir should not resolve");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Sub_Path));
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (External));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Sub_Path, ".git"),
         Content => "gitdir: ../../external-admin" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (External, "HEAD"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert (Raised, "submodule gitdir files must not escape .git/modules");
   end Submodule_Head_Rejects_Escaping_Gitdir_File;

   procedure Submodule_Head_Rejects_Normalized_Escaping_Gitdir
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      External : constant String :=
        Version.Files.Join (Root, ".git/external-admin");
      Escaping : constant String :=
        Version.Files.Join (Root, ".git/modules/../external-admin");
      Raised   : Boolean := False;

      procedure Check is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head : Unbounded_String;
      begin
         Head :=
           To_Unbounded_String
             (Version.Submodules.Submodule_Head (Repo, "deps/libfoo"));
         Assert (Length (Head) = 0, "escaping gitdir should not resolve");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end Check;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Sub_Path));
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (External));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Sub_Path, ".git"),
         Content => "gitdir: " & Escaping & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (External, "HEAD"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
      Assert
        (Raised,
         "absolute gitdir paths must be normalized before modules check");
   end Submodule_Head_Rejects_Normalized_Escaping_Gitdir;

   procedure Status_Resolves_Relative_Gitdir_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root     : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path : constant String := Version.Files.Join (Root, "deps/libfoo");
      Admin    : constant String :=
        Version.Files.Join (Root, ".git/modules/deps/libfoo");
      Items    : Version.Gitmodules.Submodule_Config_Vectors.Vector;

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         declare
            Found :
              constant Version.Submodules.Submodule_Status_Vectors.Vector :=
                Version.Submodules.Statuses (Repo);
         begin
            Assert
              (Natural (Found.Length) = 1,
               "relative gitdir submodule should be reported");
            Assert
              (Found.Element (Found.First_Index).Kind
               = Version.Submodules.Submodule_Clean,
               "relative gitdir submodule should resolve as clean");
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("file:///tmp/libfoo.git")));
      Version.Gitmodules.Write (Root, Items);

      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Sub_Path));
      Ada.Directories.Create_Path (Version.Files.To_Native_Path (Admin));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Sub_Path, ".git"),
         Content =>
           "gitdir: ../../.git/modules/deps/libfoo" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Admin, "HEAD"),
         Content => To_String (Commit_Id) & Character'Val (10));

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Status_Resolves_Relative_Gitdir_File;

   procedure Status_Ignores_Sparse_Excluded_Submodule
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root  : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Items : Version.Gitmodules.Submodule_Config_Vectors.Vector;

      procedure Check is
         Repo         : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries      : Version.Staging.Index_Entry_Vectors.Vector;
         Sparse_Items : Version.Sparse.String_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         Sparse_Items.Append ("src/");
         Version.Sparse.Set_From_Strings (Repo, Sparse_Items);

         declare
            Found :
              constant Version.Submodules.Submodule_Status_Vectors.Vector :=
                Version.Submodules.Statuses (Repo);
         begin
            Assert
              (Found.Is_Empty,
               "sparse-excluded submodules should not be reported missing");
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String ("file:///tmp/libfoo.git")));
      Version.Gitmodules.Write (Root, Items);

      Version.Files.With_Directory (Path => Root, Action => Check'Access);
   end Status_Ignores_Sparse_Excluded_Submodule;

   procedure Status_Display_Lines_Label_All_States
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Expected_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("1111111111111111111111111111111111111111");
      Actual_Id   : constant String :=
        "2222222222222222222222222222222222222222";

      function Item
        (Kind   : Version.Submodules.Submodule_Status_Kind;
         Path   : String;
         Actual : String := "") return Version.Submodules.Submodule_Status is
      begin
         return
           Version.Submodules.Submodule_Status'
             (Path     => To_Unbounded_String (Path),
              Expected => Expected_Id,
              Actual   => To_Unbounded_String (Actual),
              Kind     => Kind);
      end Item;
   begin
      Assert
        (Version.Submodules.Status_Kind_Label
           (Version.Submodules.Submodule_Missing)
         = "missing",
         "missing status label must remain stable");
      Assert
        (Version.Submodules.Status_Kind_Label
           (Version.Submodules.Submodule_Clean)
         = "clean",
         "clean status label must remain stable");
      Assert
        (Version.Submodules.Status_Kind_Label
           (Version.Submodules.Submodule_New_Commits)
         = "new commits",
         "new-commit status label must remain stable");
      Assert
        (Version.Submodules.Status_Kind_Label
           (Version.Submodules.Submodule_Dirty)
         = "dirty",
         "dirty status label must remain stable");

      Assert
        (Version.Submodules.Status_Line
           (Item (Version.Submodules.Submodule_Missing, "deps/libfoo"))
         = "-1111111111111111111111111111111111111111 deps/libfoo (missing)",
         "missing submodule status should explain missing checkout");
      Assert
        (Version.Submodules.Status_Line
           (Item
              (Version.Submodules.Submodule_Clean, "deps/libfoo", Actual_Id))
         = " 1111111111111111111111111111111111111111 deps/libfoo (clean)",
         "clean submodule status should be explicitly labelled");
      Assert
        (Version.Submodules.Status_Line
           (Item
              (Version.Submodules.Submodule_New_Commits,
               "deps/libfoo",
               Actual_Id))
         = "+2222222222222222222222222222222222222222 deps/libfoo "
           & "(new commits; expected 1111111111111111111111111111111111111111)",
         "advanced submodule status should show actual and expected commits");
      Assert
        (Version.Submodules.Status_Line
           (Item
              (Version.Submodules.Submodule_Dirty, "deps/libfoo", Actual_Id))
         = "!2222222222222222222222222222222222222222 deps/libfoo (dirty)",
         "dirty submodule status should be explicitly labelled");
   end Status_Display_Lines_Label_All_States;

   procedure Update_Missing_Commit_Does_Not_Rewrite_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root        : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Sub_Path    : constant String :=
        Version.Files.Join (Root, "deps/libfoo");
      Original_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ("2222222222222222222222222222222222222222");
      Items       : Version.Gitmodules.Submodule_Config_Vectors.Vector;
      Raised      : Boolean := False;

      procedure Check is
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Entries : Version.Staging.Index_Entry_Vectors.Vector;
      begin
         Entries.Append
           (Version.Staging.Index_Entry'
              (Path => To_Unbounded_String ("deps/libfoo"),
               Id   => Commit_Id,
               Mode => To_Unbounded_String ("160000"),
               Stage => 0, Skip_Worktree => False));
         Version.Staging.Write (Repo => Repo, Entries => Entries);

         begin
            Version.Submodules.Update (Repo, Recursive => False);
         exception
            when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
               Raised := True;
         end;
      end Check;
   begin
      Version.Init.Init (Root);
      Version.Init.Init (Sub_Path);
      Version.Files.Write_Binary_File
        (Path    => Version.Files.Join (Sub_Path, ".git/HEAD"),
         Content => To_String (Original_Id) & Character'Val (10));

      Items.Append
        (Version.Gitmodules.Submodule_Config'
           (Name => To_Unbounded_String ("deps/libfoo"),
            Path => To_Unbounded_String ("deps/libfoo"),
            Url  => To_Unbounded_String (Sub_Path)));
      Version.Gitmodules.Write (Root, Items);

      Version.Files.With_Directory (Path => Root, Action => Check'Access);

      Assert
        (Raised, "missing submodule commit should fail deterministically");
      Assert
        (Version.Files.Read_Binary_File
           (Version.Files.Join (Sub_Path, ".git/HEAD"))
         = To_String (Original_Id) & Character'Val (10),
         "failed submodule update must not rewrite HEAD before commit validation");
   end Update_Missing_Commit_Does_Not_Rewrite_Head;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Gitmodules_Parse_And_Write'Access,
         "Submodule: parse and write .gitmodules");
      Register_Routine
        (T,
         Gitmodules_Rejects_Duplicate_Path'Access,
         "Submodule: reject duplicate .gitmodules path");
      Register_Routine
        (T,
         Gitmodules_Normalizes_Path_Separators'Access,
         "Submodule: normalize .gitmodules paths");
      Register_Routine
        (T,
         Gitmodules_Reads_CRLF_And_Tab_Indented_Config'Access,
         "Submodule: parse CRLF .gitmodules files");
      Register_Routine
        (T,
         Gitmodules_Accepts_Semicolon_Comments'Access,
         "Submodule: parse semicolon .gitmodules comments");
      Register_Routine
        (T,
         Gitmodules_Rejects_Duplicate_Keys'Access,
         "Submodule: reject duplicate .gitmodules keys");
      Register_Routine
        (T,
         Gitmodules_Rejects_Control_Characters'Access,
         "Submodule: reject control characters in .gitmodules values");
      Register_Routine
        (T,
         Gitmodules_Write_Rejects_Config_Injection'Access,
         "Submodule: reject .gitmodules injection on write");
      Register_Routine
        (T,
         Submodule_Update_Rejects_Relative_Url_Without_Remote'Access,
         "Submodule: reject relative URL without remote");
      Register_Routine
        (T,
         Submodule_Update_Rejects_Escaping_Relative_Url_With_Remote'Access,
         "Submodule: reject escaping relative URL with remote");
      Register_Routine
        (T,
         Submodule_Update_Resolves_Local_Dot_Dot_Relative_Url'Access,
         "Submodule: resolve local ../ relative URL");
      Register_Routine
        (T,
         Submodule_Update_Resolves_File_Dot_Dot_Relative_Url'Access,
         "Submodule: resolve file:// ../ relative URL");
      Register_Routine
        (T,
         Submodule_Update_Resolves_Dot_Relative_Url'Access,
         "Submodule: resolve ./ relative URL");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Https_Relative_Url'Access,
         "Submodule: resolver handles https relative URL");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Ssh_Relative_Url'Access,
         "Submodule: resolver handles ssh relative URL");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Scp_Like_Relative_Url'Access,
         "Submodule: resolver handles scp-like relative URL");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Deeper_Legal_Traversal'Access,
         "Submodule: resolver handles deeper legal traversal");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Scp_Escape'Access,
         "Submodule: resolver rejects scp-like escape");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Https_Base_Without_Git_Suffix'Access,
         "Submodule: resolver handles https base without .git");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Https_Base_With_Trailing_Slash'Access,
         "Submodule: resolver handles https base trailing slash");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Ssh_Base_Without_Git_Suffix'Access,
         "Submodule: resolver handles ssh base without .git");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Scp_Base_Without_Git_Suffix'Access,
         "Submodule: resolver handles scp-like base without .git");
      Register_Routine
        (T,
         Submodule_Resolver_Normalizes_Dot_Then_Dot_Dot'Access,
         "Submodule: resolver normalizes dot then dotdot");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Excessive_Traversal_By_Scheme'Access,
         "Submodule: resolver rejects excessive traversal by scheme");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Malformed_And_Empty_Bases'Access,
         "Submodule: resolver rejects malformed and empty bases");
      Register_Routine
        (T,
         Gitmodules_Rejects_Malicious_Submodule_Paths'Access,
         "Submodule: reject malicious .gitmodules paths");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Backslash_Relative_Url'Access,
         "Submodule: resolver handles backslash relative URL");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Backslash_Escape'Access,
         "Submodule: resolver rejects backslash traversal URL");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Empty_Relative_Component'Access,
         "Submodule: resolver rejects empty relative URL components");
      Register_Routine
        (T,
         Submodule_Resolver_Rejects_Control_Characters'Access,
         "Submodule: resolver rejects control characters");
      Register_Routine
        (T,
         Submodule_Resolver_Handles_Ssh_Base_With_Port'Access,
         "Submodule: resolver handles ssh base with port");
      Register_Routine
        (T,
         Submodule_Resolver_Preserves_Absolute_Urls'Access,
         "Submodule: resolver preserves absolute URLs");
      Register_Routine
        (T,
         Gitmodules_Rejects_More_Malicious_Submodule_Paths'Access,
         "Submodule: reject additional malicious .gitmodules paths");
      Register_Routine
        (T,
         Tree_Writer_Preserves_Gitlink_Mode'Access,
         "Submodule: tree writer preserves gitlink mode");
      Register_Routine
        (T,
         Stage_Submodule_Updates_Gitlink'Access,
         "Submodule: gitlink lookup from index");
      Register_Routine
        (T,
         Submodule_Public_APIs_Normalize_Path'Access,
         "Submodule: public APIs normalize paths");
      Register_Routine
        (T,
         Submodule_Head_Resolves_Attached_Ref'Access,
         "Submodule: resolve attached HEAD ref");
      Register_Routine
        (T,
         Submodule_Head_Resolves_Tab_Separated_Attached_Ref'Access,
         "Submodule: resolve tab-separated HEAD ref");
      Register_Routine
        (T,
         Submodule_Head_Resolves_Gitdir_File'Access,
         "Submodule: resolve gitdir indirection");
      Register_Routine
        (T,
         Linked_Worktree_Update_Uses_Linked_Submodule_Admin'Access,
         "Submodule: linked update uses linked admin dir");
      Register_Routine
        (T,
         Submodule_Head_Resolves_Packed_Ref'Access,
         "Submodule: resolve packed branch ref");

      Register_Routine
        (T,
         Submodule_Head_Rejects_Malformed_Packed_Ref'Access,
         "Submodule: reject malformed packed branch ref");
      Register_Routine
        (T,
         Submodule_Head_Rejects_Unrelated_Malformed_Packed_Ref'Access,
         "Submodule: reject unrelated malformed packed ref");
      Register_Routine
        (T,
         Submodule_Head_Rejects_Escaping_Gitdir_File'Access,
         "Submodule: reject escaping gitdir file");
      Register_Routine
        (T,
         Submodule_Head_Rejects_Normalized_Escaping_Gitdir'Access,
         "Submodule: reject normalized escaping gitdir file");
      Register_Routine
        (T,
         Status_Resolves_Relative_Gitdir_File'Access,
         "Submodule: status resolves relative gitdir file");
      Register_Routine
        (T,
         Status_Ignores_Sparse_Excluded_Submodule'Access,
         "Submodule: status ignores sparse-excluded submodule");
      Register_Routine
        (T,
         Status_Display_Lines_Label_All_States'Access,
         "Submodule: status display labels all states");
      Register_Routine
        (T,
         Update_Missing_Commit_Does_Not_Rewrite_Head'Access,
         "Submodule: failed update preserves HEAD");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Submodules.Tests");
   end Name;

end Version.Submodules.Tests;
