with Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;

with GNAT.OS_Lib;

with Version.Archive;
with Version.Branch;
with Version.Compression;
with Version.Clone;
with Version.Files;
with Version.Hash;
with Version.Refs;
with Version.Repository;
with Version.Restore;
with Version.Write;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Config;
with Version.Init;
with Version.Objects;
with Version.Path_Safety;
with Version.Ref_Names;
with Version.Remotes;
with Version.Test_Support;
with Version.Transport;

package body Version.Security.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Assert_Data_Error
     (Raised  : Boolean;
      Message : String)
   is
   begin
      Assert (Raised, Message);
   end Assert_Data_Error;

   function Raw_Id (Id : Version.Objects.Hex_Object_Id) return String is
      Result : String (1 .. 20);
      Pos    : Positive := To_String (Id)'First;

      function Nibble (C : Character) return Natural is
      begin
         if C in '0' .. '9' then
            return Character'Pos (C) - Character'Pos ('0');
         elsif C in 'a' .. 'f' then
            return Character'Pos (C) - Character'Pos ('a') + 10;
         elsif C in 'A' .. 'F' then
            return Character'Pos (C) - Character'Pos ('A') + 10;
         else
            raise Ada.IO_Exceptions.Data_Error with "invalid object id hex digit";
         end if;
      end Nibble;
   begin
      for I in Result'Range loop
         declare
            V : constant Natural :=
              Nibble (To_String (Id) (Pos)) * 16 + Nibble (To_String (Id) (Pos + 1));
         begin
            Result (I) := Character'Val (V);
            Pos := Pos + 2;
         end;
      end loop;

      return Result;
   end Raw_Id;

   function Write_Raw_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String)
      return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);
      Raw : constant String := Header & Content;
      Id  : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
   begin
      Version.Files.Write_Binary_File
        (Path    => Version.Objects.Loose_Object_Path (Repo, Id),
         Content => Version.Compression.Deflate_Zlib (Raw));
      return Id;
   end Write_Raw_Object;

   procedure Reject_Restore_Path_Traversal
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Safe_Relative_Path
           ("../evil",
            "restore path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "path traversal must be rejected");
   end Reject_Restore_Path_Traversal;

   procedure Reject_Checkout_Path_Inside_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Path_Safety.Require_Safe_Relative_Path
           (".git/config",
            "checkout path");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "checkout path inside .git must be rejected");
   end Reject_Checkout_Path_Inside_Git;

   procedure Reject_Branch_Name_With_Dot_Dot
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Ref_Names.Require_Branch_Name ("feature/../main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "branch name with .. must be rejected");
   end Reject_Branch_Name_With_Dot_Dot;

   procedure Reject_Branch_Name_Ending_Lock
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Ref_Names.Require_Branch_Name ("main.lock");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "branch name ending .lock must be rejected");
   end Reject_Branch_Name_Ending_Lock;

   procedure Reject_Tag_Name_With_Newline
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Ref_Names.Require_Tag_Name
           ("v1" & Character'Val (10) & "x");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "tag name with newline must be rejected");
   end Reject_Tag_Name_With_Newline;

   procedure Reject_Windows_Reserved_Ref_Component
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Version.Ref_Names.Is_Valid_Branch_Name ("CON"),
         "Windows reserved branch component must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Tag_Name ("release/NUL.txt"),
         "Windows reserved tag component with extension must be rejected");
      Assert
        (not Version.Ref_Names.Is_Valid_Ref_Name ("refs/remotes/origin/AUX"),
         "Windows reserved remote-tracking component must be rejected");
   end Reject_Windows_Reserved_Ref_Component;

   procedure Reject_Remote_Name_With_Traversal
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Ref_Names.Require_Remote_Name ("../origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "remote name traversal must be rejected");
   end Reject_Remote_Name_With_Traversal;

   procedure Reject_Remote_URL_With_Newline
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      begin
         Version.Remotes.Add_Remote
           (Name => "origin",
            Url  => "../repo" & Character'Val (10) & "[alias]");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, "remote URL newline must be rejected");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Reject_Remote_URL_With_Newline;

   procedure Reject_Config_Scalar_Injection
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Config.Require_Config_Scalar
           ("x" & Character'Val (10) & "[alias]",
            "remote url");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "config scalar injection must be rejected");
   end Reject_Config_Scalar_Injection;

   procedure Reject_Malformed_Object_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Version.Objects.Is_Valid_Hex_Object_Id ("not-an-object-id"),
         "malformed object id must be rejected before conversion");
   end Reject_Malformed_Object_Id;

   procedure Reject_Unknown_URL_Scheme
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Transport.Require_Supported_Url ("ftp://example.invalid/repo.git");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert_Data_Error (Raised, "unknown URL scheme must be rejected");
   end Reject_Unknown_URL_Scheme;

   procedure Hostile_Tree_Path_Does_Not_Write_Outside_Repo
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root         : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir      : constant String := Ada.Directories.Current_Directory;
      Hostile_Name : constant String := Ada.Directories.Simple_Name (Root) & "_evil";
      Hostile_Path : constant String := "../" & Hostile_Name;
      Outside      : constant String := Version.Files.Join (Root, Hostile_Path);
      Raised       : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "hostile");
         Tree_Content : constant String :=
           "100644 " & Hostile_Path & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object
             (Repo    => Repo,
              Kind    => "tree",
              Content => Tree_Content);
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile tree");
      begin
         Version.Refs.Atomic_Write_Ref
           (Path      =>
              Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "refs/heads"),
                 "main"),
            Object_Id => Commit_Id);

         begin
            Version.Restore.Restore_Working_Tree (Repo);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

      Assert_Data_Error (Raised, "hostile tree path must be rejected");
      Assert
        (not Ada.Directories.Exists (Outside),
         "hostile tree path must not write outside repository");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Hostile_Tree_Path_Does_Not_Write_Outside_Repo;

   procedure Hostile_Tree_Dot_Git_Path_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "hostile config");
         Tree_Content : constant String :=
           "100644 .git/config" & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object
             (Repo    => Repo,
              Kind    => "tree",
              Content => Tree_Content);
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile dotgit tree");
      begin
         Version.Refs.Atomic_Write_Ref
           (Path      =>
              Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "refs/heads"),
                 "main"),
            Object_Id => Commit_Id);

         begin
            Version.Restore.Restore_Working_Tree (Repo);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, "hostile .git tree path must be rejected");
      Assert
        (not Ada.Directories.Exists (Version.Files.Join (Root, ".git/config.lock")),
         "hostile .git tree path must not create git-dir side effects");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Hostile_Tree_Dot_Git_Path_Rejected;

   procedure Hostile_Tree_Absolute_Path_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "hostile absolute");
         Tree_Content : constant String :=
           "100644 /tmp/version-hostile" & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object
             (Repo    => Repo,
              Kind    => "tree",
              Content => Tree_Content);
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile absolute tree");
      begin
         Version.Refs.Atomic_Write_Ref
           (Path      =>
              Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "refs/heads"),
                 "main"),
            Object_Id => Commit_Id);

         begin
            Version.Restore.Restore_Working_Tree (Repo);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, "hostile absolute tree path must be rejected");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Hostile_Tree_Absolute_Path_Rejected;

   procedure Reject_Additional_Hostile_Path_Components
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      procedure Expect_Rejected (Path : String; Label : String) is
         Raised : Boolean := False;
      begin
         begin
            Version.Path_Safety.Require_Safe_Relative_Path
              (Path,
               "hostile path");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert_Data_Error (Raised, Label & " must be rejected");
      end Expect_Rejected;
   begin
      Expect_Rejected ("a/../../x", "nested parent traversal");
      Expect_Rejected (".git", "literal .git directory");
      Expect_Rejected (".git/hooks/post-checkout", "hook path inside .git");
      Expect_Rejected ("a//b", "empty path component");
      Expect_Rejected ("a/", "trailing slash path");
      Expect_Rejected ("C:/x", "Windows drive absolute path");
      Expect_Rejected ("..\x", "backslash parent traversal");
   end Reject_Additional_Hostile_Path_Components;

   procedure Expect_Hostile_Tree_Restore_Rejected
     (Root          : String;
      Entry_Path    : String;
      Assertion_Tag : String)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
      Sentinel : constant String := Version.Files.Join (Root, "safe-sentinel.txt");
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Files.Write_Binary_File (Sentinel, "keep");

      declare
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "hostile tree payload");
         Tree_Content : constant String :=
           "100644 " & Entry_Path & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object
             (Repo    => Repo,
              Kind    => "tree",
              Content => Tree_Content);
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile tree");
      begin
         Version.Refs.Atomic_Write_Ref
           (Path      =>
              Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "refs/heads"),
                 "main"),
            Object_Id => Commit_Id);

         begin
            Version.Restore.Restore_Working_Tree (Repo);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, Assertion_Tag & " must be rejected");
      Assert
        (Version.Files.Read_Binary_File (Sentinel) = "keep",
         Assertion_Tag & " must not mutate existing working-tree files");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Expect_Hostile_Tree_Restore_Rejected;

   procedure Hostile_Tree_Nested_Traversal_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Tree_Restore_Rejected
        (Root,
         "safe/../../escape.txt",
         "nested tree traversal");
   end Hostile_Tree_Nested_Traversal_Rejected;

   procedure Hostile_Tree_Dot_Git_Directory_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Tree_Restore_Rejected
        (Root,
         ".git",
         "literal .git tree entry");
   end Hostile_Tree_Dot_Git_Directory_Rejected;

   procedure Hostile_Tree_Dot_Git_Hook_Path_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Tree_Restore_Rejected
        (Root,
         ".git/hooks/post-checkout",
         "hook path inside .git tree entry");
   end Hostile_Tree_Dot_Git_Hook_Path_Rejected;

   procedure Hostile_Tree_Empty_Component_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Tree_Restore_Rejected
        (Root,
         "a//b",
         "empty tree path component");
   end Hostile_Tree_Empty_Component_Rejected;

   procedure Hostile_Tree_Trailing_Slash_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Tree_Restore_Rejected
        (Root,
         "bad/",
         "trailing slash tree path");
   end Hostile_Tree_Trailing_Slash_Rejected;

   procedure Hostile_Archive_Tree_Entry_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Version.Files.Join (Root, "hostile.tar");
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo    : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "archive hostile payload");
         Tree_Content : constant String :=
           "100644 ../archive-escape" & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object
             (Repo    => Repo,
              Kind    => "tree",
              Content => Tree_Content);
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile archive tree");
      begin
         Version.Refs.Atomic_Write_Ref
           (Path      =>
              Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Git_Dir (Repo), "refs/heads"),
                 "main"),
            Object_Id => Commit_Id);

         begin
            Version.Archive.Create
              (Repo,
               "HEAD",
               Output,
               Version.Archive.Tar_Format);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, "archive must reject hostile tree entry names");
      Assert
        (not Ada.Directories.Exists (Output),
         "archive rejection must not leave output archive behind");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Hostile_Archive_Tree_Entry_Rejected;

   procedure Stale_Lock_Blocks_Ref_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      Version.Files.Write_Binary_File
        (Path    =>
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Root, ".git"), "refs/heads"),
              "blocked.lock"),
         Content => "stale");

      begin
         Version.Branch.Create_Branch
           (Name      => "blocked",
            Commit_Id => "0000000000000000000000000000000000000000");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert_Data_Error (Raised, "stale lock must block ref update");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stale_Lock_Blocks_Ref_Update;

   procedure Current_Directory_Restored_After_Failed_Clone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Bin     : constant String := Version.Files.Join (Root, "bin");
      Fake_Ssh : constant String := Version.Files.Join (Bin, "ssh");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("PATH");
      Old_Path : constant String :=
        (if Old_Path_Exists then Ada.Environment_Variables.Value ("PATH") else "");
      Raised  : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Fake_Ssh, "#!/bin/sh" & Character'Val (10) & "exit 7" & Character'Val (10));
      GNAT.OS_Lib.Set_Executable (Fake_Ssh);
      Ada.Environment_Variables.Set
        ("PATH", Bin & GNAT.OS_Lib.Path_Separator & Old_Path);

      begin
         Version.Clone.Clone
           (Source => "ssh://example.invalid/repo.git",
            Target => Version.Files.Join (Root, "clone"));
      exception
         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Assert_Data_Error
        (Raised,
         "failed SSH clone should raise deterministic Use_Error");
      Assert
        (Ada.Directories.Current_Directory = Old_Dir,
         "failed clone must restore current directory");

      if Old_Path_Exists then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;
   exception
      when others =>
         if Old_Path_Exists then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         else
            Ada.Environment_Variables.Clear ("PATH");
         end if;
         raise;
   end Current_Directory_Restored_After_Failed_Clone;

   procedure Valid_Nested_Names_Still_Work
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Ref_Names.Is_Valid_Branch_Name ("feature/x"),
         "nested branch name should remain valid");
      Assert
        (Version.Ref_Names.Is_Valid_Tag_Name ("release/v1.0"),
         "nested tag name should remain valid");
      Assert
        (Version.Ref_Names.Is_Valid_Ref_Name ("refs/remotes/origin/main"),
         "remote tracking ref should remain valid");
   end Valid_Nested_Names_Still_Work;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Reject_Restore_Path_Traversal'Access,
                        "Security: reject restore path traversal");
      Register_Routine (T, Reject_Checkout_Path_Inside_Git'Access,
                        "Security: reject checkout path inside .git");
      Register_Routine (T, Reject_Branch_Name_With_Dot_Dot'Access,
                        "Security: reject branch name with ..");
      Register_Routine (T, Reject_Branch_Name_Ending_Lock'Access,
                        "Security: reject branch name ending .lock");
      Register_Routine (T, Reject_Tag_Name_With_Newline'Access,
                        "Security: reject tag name with newline");
      Register_Routine (T, Reject_Windows_Reserved_Ref_Component'Access,
                        "Security: reject Windows reserved ref components");
      Register_Routine (T, Reject_Remote_Name_With_Traversal'Access,
                        "Security: reject remote name slash traversal");
      Register_Routine (T, Reject_Remote_URL_With_Newline'Access,
                        "Security: reject remote URL with newline");
      Register_Routine (T, Reject_Config_Scalar_Injection'Access,
                        "Security: reject tracking config injection");
      Register_Routine (T, Reject_Malformed_Object_Id'Access,
                        "Security: reject malformed object id before conversion");
      Register_Routine (T, Reject_Unknown_URL_Scheme'Access,
                        "Security: unknown URL scheme rejected");
      Register_Routine (T, Hostile_Tree_Path_Does_Not_Write_Outside_Repo'Access,
                        "Security: hostile tree path does not write outside repo");
      Register_Routine (T, Hostile_Tree_Dot_Git_Path_Rejected'Access,
                        "Security: hostile .git tree path rejected");
      Register_Routine (T, Hostile_Tree_Absolute_Path_Rejected'Access,
                        "Security: hostile absolute tree path rejected");
      Register_Routine (T, Reject_Additional_Hostile_Path_Components'Access,
                        "Security: reject additional hostile path components");
      Register_Routine (T, Hostile_Tree_Nested_Traversal_Rejected'Access,
                        "Security: hostile nested tree traversal rejected");
      Register_Routine (T, Hostile_Tree_Dot_Git_Directory_Rejected'Access,
                        "Security: hostile .git directory tree path rejected");
      Register_Routine (T, Hostile_Tree_Dot_Git_Hook_Path_Rejected'Access,
                        "Security: hostile .git hook tree path rejected");
      Register_Routine (T, Hostile_Tree_Empty_Component_Rejected'Access,
                        "Security: hostile empty tree path component rejected");
      Register_Routine (T, Hostile_Tree_Trailing_Slash_Rejected'Access,
                        "Security: hostile trailing slash tree path rejected");
      Register_Routine (T, Hostile_Archive_Tree_Entry_Rejected'Access,
                        "Security: hostile archive tree entry rejected");
      Register_Routine (T, Stale_Lock_Blocks_Ref_Update'Access,
                        "Security: stale lock blocks ref update");
      Register_Routine (T, Current_Directory_Restored_After_Failed_Clone'Access,
                        "Security: current directory restored after failed clone");
      Register_Routine (T, Valid_Nested_Names_Still_Work'Access,
                        "Security: valid nested names still work");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Security");
   end Name;

end Version.Security.Tests;
