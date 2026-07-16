with Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Worktrees;
with Version.Write;
with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Repository;
with Version.Test_Support;

package body Version.Reflog.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Append_Reflog_Entry
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Log_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "logs"),
           "HEAD");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);

      Version.Git_Fixtures.Run
        (Root,
         "git config user.email test@example.com");

      Version.Git_Fixtures.Run
        (Root,
         "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      --  Pin the committer date so the reflog's timezone offset is
      --  deterministic; the writer stamps entries in the local timezone
      --  (as git does), which would otherwise vary with the test host.
      Ada.Environment_Variables.Set
        ("GIT_COMMITTER_DATE", "1700000000 +0000");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Reflog.Append
           (Repo    => Repo,
            Ref     => "HEAD",
            Old_Id  => "0000000000000000000000000000000000000000",
            New_Id  => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            Message => "test reflog");
      end;

      Ada.Environment_Variables.Clear ("GIT_COMMITTER_DATE");

      declare
         Text : constant String :=
           Version.Test_Support.Read_Text_File (Log_Path);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Text,
               "0000000000000000000000000000000000000000 "
               & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") /= 0,
            "reflog must contain old and new ids");

         Assert
           (Ada.Strings.Fixed.Index (Text, "Test <test@example.com>") /= 0,
            "reflog must contain configured identity");

         Assert
           (Ada.Strings.Fixed.Index
              (Text,
               "+0000" & Character'Val (9) & "test reflog") /= 0,
            "reflog must separate timezone and message with a horizontal tab");

         Assert
           (Ada.Strings.Fixed.Index (Text, "test reflog") /= 0,
            "reflog must contain message");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Environment_Variables.Clear ("GIT_COMMITTER_DATE");
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Append_Reflog_Entry;

   procedure Append_Reflog_Entries_Preserve_Order_And_Newlines
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Log_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "logs"),
           "HEAD");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Reflog.Append
           (Repo    => Repo,
            Ref     => "HEAD",
            Old_Id  => "0000000000000000000000000000000000000000",
            New_Id  => "1111111111111111111111111111111111111111",
            Message => "first entry");

         Version.Reflog.Append
           (Repo    => Repo,
            Ref     => "HEAD",
            Old_Id  => "1111111111111111111111111111111111111111",
            New_Id  => "2222222222222222222222222222222222222222",
            Message => "second entry");
      end;

      declare
         Text : constant String :=
           Version.Test_Support.Read_Text_File (Log_Path);

         First_Pos : constant Natural :=
           Ada.Strings.Fixed.Index (Text, "first entry");

         Second_Pos : constant Natural :=
           Ada.Strings.Fixed.Index (Text, "second entry");
      begin
         Assert
           (First_Pos /= 0 and then Second_Pos /= 0 and then First_Pos < Second_Pos,
            "reflog entries must be appended in order");

         Assert
           (Ada.Strings.Fixed.Index
              (Text,
               "first entry" & Character'Val (10)
               & "1111111111111111111111111111111111111111 ") /= 0,
            "reflog entries must be separated by LF newline characters");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Append_Reflog_Entries_Preserve_Order_And_Newlines;

   procedure Append_Rejects_Invalid_Object_Ids
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Log_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "logs"),
           "HEAD");

      Lock_Path : constant String := Log_Path & ".lock";

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         begin
            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => "HEAD",
               Old_Id  => "not-a-valid-object-id",
               New_Id  => "1111111111111111111111111111111111111111",
               Message => "invalid old id");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "reflog append must reject malformed old object ids");
      Assert
        (not Ada.Directories.Exists (Log_Path),
         "invalid reflog append must not create reflog file");
      Assert
        (not Ada.Directories.Exists (Lock_Path),
         "invalid reflog append must not create lock file");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Append_Rejects_Invalid_Object_Ids;

   procedure Append_Rejects_Stale_Lock_Without_Mutation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Log_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Root, ".git"), "logs"),
           "HEAD");

      Lock_Path : constant String := Log_Path & ".lock";

      Existing_Log : constant String :=
        "0000000000000000000000000000000000000000 "
        & "1111111111111111111111111111111111111111 "
        & "Test <test@example.com> 0 +0000"
        & Character'Val (9)
        & "existing"
        & Character'Val (10);

      Existing_Lock : constant String := "stale lock" & Character'Val (10);
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Log_Path));
      Version.Test_Support.Write_Text_File (Log_Path, Existing_Log);
      Version.Test_Support.Write_Text_File (Lock_Path, Existing_Lock);

      declare
         Log_Before : constant String := Version.Files.Read_Binary_File (Log_Path);
         Lock_Before : constant String := Version.Files.Read_Binary_File (Lock_Path);
      begin
         Ada.Directories.Set_Directory (Root);

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            begin
               Version.Reflog.Append
                 (Repo    => Repo,
                  Ref     => "HEAD",
                  Old_Id  => "1111111111111111111111111111111111111111",
                  New_Id  => "2222222222222222222222222222222222222222",
                  Message => "blocked by stale lock");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
         end;

         Ada.Directories.Set_Directory (Old_Dir);
         Assert (Raised, "stale reflog lock must reject append");
         Assert
           (Version.Files.Read_Binary_File (Log_Path) = Log_Before,
            "stale reflog lock must preserve existing reflog bytes");
         Assert
           (Version.Files.Read_Binary_File (Lock_Path) = Lock_Before,
            "stale reflog lock must be preserved");
      end;

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Append_Rejects_Stale_Lock_Without_Mutation;

   procedure Preflight_Append_Exception_Modes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Existing_Lock : constant String := "stale lock" & Character'Val (10);
      Data_Error_Raised : Boolean := False;
      Use_Error_Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Lock_Path : constant String :=
           Version.Reflog.Path (Repo, "HEAD") & ".lock";
      begin
         Version.Reflog.Preflight_Append (Repo, "HEAD");
         Version.Files.Create_Parent_Directories (Lock_Path);

         Version.Test_Support.Write_Text_File (Lock_Path, Existing_Lock);

         begin
            Version.Reflog.Preflight_Append (Repo, "HEAD");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Data_Error_Raised := True;
         end;

         begin
            Version.Reflog.Preflight_Append
              (Repo, "HEAD", Version.Reflog.Use_Error_On_Lock);
         exception
            when Ada.IO_Exceptions.Use_Error =>
               Use_Error_Raised := True;
         end;

         Assert
           (Data_Error_Raised,
            "default preflight must raise Data_Error for stale locks");
         Assert
           (Use_Error_Raised,
            "Use_Error preflight mode must raise Use_Error for stale locks");
         Assert
           (Ada.Strings.Fixed.Index
              (Version.Files.Read_Binary_File (Lock_Path), "stale lock") /= 0,
            "preflight must preserve stale lock content");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Preflight_Append_Exception_Modes;

   procedure Linked_Worktree_Path_Uses_Worktree_And_Common_Git_Dirs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-feature";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, "a.txt"), "a" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("initial");
      Version.Branch.Create_Branch ("feature");
      Version.Worktrees.Add (Path => Work, Branch => "feature");

      declare
         Linked_Git_Dir : constant String :=
           Version.Repository.Resolve_Git_Dir (Work);
         Linked_Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open_Git_Dir (Linked_Git_Dir);
         Head_Path : constant String :=
           Version.Reflog.Path (Linked_Repo, "HEAD");
         Branch_Path : constant String :=
           Version.Reflog.Path (Linked_Repo, "refs/heads/main");
         Branch_Lock : constant String := Branch_Path & ".lock";
      begin
         Assert
           (Version.Repository.Is_Linked_Worktree (Linked_Repo),
            "linked repository handle must identify a linked worktree");
         Assert
           (Head_Path = Version.Files.Join (Linked_Git_Dir, "logs/HEAD"),
            "linked worktree HEAD reflog must live in linked git dir");
         Assert
           (Branch_Path =
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Linked_Repo),
                 "logs/refs/heads/main"),
            "linked worktree branch reflog must live in common git dir");

         Version.Test_Support.Write_Text_File
           (Branch_Lock, "stale branch reflog lock" & Character'Val (10));
         begin
            Version.Reflog.Preflight_Append
              (Linked_Repo,
               "refs/heads/main",
               Version.Reflog.Use_Error_On_Lock);
         exception
            when Ada.IO_Exceptions.Use_Error =>
               Raised := True;
         end;
         Assert
           (Raised,
            "linked worktree branch reflog preflight must see common-dir lock");
         Assert
           (Ada.Directories.Exists (Version.Files.To_Native_Path (Branch_Lock)),
            "linked worktree branch reflog preflight must preserve stale lock");
      end;

      Version.Worktrees.Remove (Work);
      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Linked_Worktree_Path_Uses_Worktree_And_Common_Git_Dirs;

   procedure Read_Entries_Parses_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      use Ada.Strings.Unbounded;

      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.Reflog.Append
           (Repo, "HEAD",
            "0000000000000000000000000000000000000000",
            "1111111111111111111111111111111111111111", "first entry");
         Version.Reflog.Append
           (Repo, "HEAD",
            "1111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222", "second entry");

         declare
            Entries : constant Version.Reflog.Log_Entry_Vectors.Vector :=
              Version.Reflog.Read_Entries (Repo, "HEAD");
         begin
            Assert (Natural (Entries.Length) = 2,
                    "Read_Entries must parse both reflog lines");
            Assert (To_String (Entries.Element (1).Message) = "first entry",
                    "oldest entry must be first");
            Assert (To_String (Entries.Element (2).Message) = "second entry",
                    "newest entry must be last");
            Assert
              (To_String (Entries.Element (1).Old_Id)
                 = "0000000000000000000000000000000000000000",
               "old id must be parsed");
            Assert
              (To_String (Entries.Element (2).New_Id)
                 = "2222222222222222222222222222222222222222",
               "new id must be parsed");
         end;

         declare
            Empty : constant Version.Reflog.Log_Entry_Vectors.Vector :=
              Version.Reflog.Read_Entries (Repo, "refs/heads/does-not-exist");
         begin
            Assert (Empty.Is_Empty, "missing reflog must yield an empty list");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Entries_Parses_Reflog;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Read_Entries_Parses_Reflog'Access,
         "Reflog: Read_Entries parses lines oldest-first");

      Register_Routine
        (T,
         Append_Reflog_Entry'Access,
         "Reflog: append entry");

      Register_Routine
        (T,
         Append_Reflog_Entries_Preserve_Order_And_Newlines'Access,
         "Reflog: append preserves order and newline separation");

      Register_Routine
        (T,
         Append_Rejects_Invalid_Object_Ids'Access,
         "Reflog: append rejects invalid object ids");

      Register_Routine
        (T,
         Append_Rejects_Stale_Lock_Without_Mutation'Access,
         "Reflog: append rejects stale lock without mutation");

      Register_Routine
        (T,
         Preflight_Append_Exception_Modes'Access,
         "Reflog: preflight append exception modes");

      Register_Routine
        (T,
         Linked_Worktree_Path_Uses_Worktree_And_Common_Git_Dirs'Access,
         "Reflog: linked worktree path uses worktree and common git dirs");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Reflog");
   end Name;

end Version.Reflog.Tests;