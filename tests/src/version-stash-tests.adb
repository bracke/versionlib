with Ada.Containers;        use Ada.Containers;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Branch;
with Version.Git_Fixtures;
with Version.Init;
with Version.Merge_State;
with Version.Objects;
with Version.Pathspec;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Files;
with Version.Test_Support;
with Version.Stash_Test_Support;
with Version.Write;
with Version.Worktrees;

package body Version.Stash.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Ada.Directories.File_Kind;

   function Stash_Ref_Path (Root : String) return String
     renames Version.Stash_Test_Support.Stash_Ref_Path;
   function Stash_Log_Path (Root : String) return String
     renames Version.Stash_Test_Support.Stash_Log_Path;

   procedure Configure_User (Root : String) is
   begin
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
   end Configure_User;

   procedure Write_File (Root, Name, Content : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Root, Name), Content);
   end Write_File;

   function File_Text (Root, Name : String) return String is
   begin
      return
        Version.Test_Support.Read_Text_File
          (Version.Test_Support.Join (Root, Name));
   end File_Text;

   procedure Commit_File (Root, Name, Content, Message : String) is
   begin
      Write_File (Root, Name, Content);
      Version.Git_Fixtures.Run (Root, "git add " & Name);
      Version.Write.Save (Message);
   end Commit_File;

   procedure Create_Tracked_Stash (Root : String) is
   begin
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
   end Create_Tracked_Stash;

   procedure Create_Two_Tracked_Stashes (Root : String) is
   begin
      Create_Tracked_Stash (Root);
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
   end Create_Two_Tracked_Stashes;

   procedure Write_Stale_Lock (Path : String) is
   begin
      Version.Test_Support.Write_Text_File
        (Path, "stale" & Character'Val (10));
   end Write_Stale_Lock;

   procedure Assert_Tracked_Stash_Not_Applied
     (Root    : String;
      Context : String)
   is
   begin
      Assert
        (File_Text (Root, "a.txt") = "one",
         Context & " must not apply tracked changes");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         Context & " must keep the stash entry");
   end Assert_Tracked_Stash_Not_Applied;

   procedure Assert_Branch_Not_Created
     (Name    : String;
      Context : String)
   is
   begin
      Assert
        (Version.Branch.Current_Branch_Name = "main",
         Context & " must stay on the original branch");
      Assert
        (not Version.Refs.Ref_Exists
               (Version.Repository.Open, "refs/heads/" & Name),
         Context & " must not create the target branch");
   end Assert_Branch_Not_Created;

   procedure Stash_Push_Tracked_Modification_Apply_Keeps_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Assert
        (File_Text (Root, "a.txt") = "one",
         "stash push must restore working tree to HEAD");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      declare
         Entries : constant Version.Stash.Stash_Entry_Vectors.Vector :=
           Version.Stash.List_Entries (Version.Repository.Open);
      begin
         Assert (Entries.Length = 1, "stash list must contain one entry");
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Entries.First_Element.Message), "WIP on main:")
            /= 0,
            "stash message must describe branch");
      end;
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash apply must restore working change");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "stash apply must keep stash");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Version.Git_Fixtures.Run
        (Root, "git stash list | grep -F 'stash@{0}: WIP on main:'");
      Version.Git_Fixtures.Run
        (Root, "git show --quiet refs/stash >/dev/null");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Push_Tracked_Modification_Apply_Keeps_Stash;

   procedure Stash_Push_Staged_Change_Restores_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Stash.Push;
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "a.txt") = "two",
         "staged stash must restore content as working change");
      Version.Git_Fixtures.Run (Root, "test -n ""$(git status --porcelain)""");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Push_Staged_Change_Restores_Index;

   procedure Stash_Pop_Drops_Top (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Version.Stash.Pop;
      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash pop must restore change");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "stash pop must drop stash on success");
      Assert (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
              "stash ref must be removed");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_Drops_Top;

   procedure Stash_Linked_Worktree_Uses_Common_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Work : constant String := Root & "-linked";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");
      Version.Worktrees.Add (Path => Work, Branch => "feature");

      declare
         Linked_Git_Dir : constant String :=
           Version.Repository.Resolve_Git_Dir (Work);
         Linked_Stash_Log : constant String :=
           Version.Files.Join (Linked_Git_Dir, "logs/refs/stash");

         procedure Push_And_Drop_From_Linked is
         begin
            Write_File (Work, "a.txt", "two" & Character'Val (10));
            Version.Stash.Push;
            Assert
              (File_Text (Work, "a.txt") = "one",
               "linked stash push must restore linked worktree content");
            Assert
              (Ada.Directories.Exists (Stash_Log_Path (Root)),
               "linked stash push must write common stash reflog");
            Assert
              (not Ada.Directories.Exists (Linked_Stash_Log),
               "linked stash push must not create per-worktree stash reflog");

            Version.Stash.Drop ("stash@{0}");
            Assert
              (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
               "linked stash drop must remove common stash ref");
            Assert
              (not Ada.Directories.Exists (Stash_Log_Path (Root)),
               "linked stash drop must remove common stash reflog");
            Assert
              (not Ada.Directories.Exists (Linked_Stash_Log),
               "linked stash drop must not create per-worktree stash reflog");
         end Push_And_Drop_From_Linked;
      begin
         Version.Files.With_Directory (Work, Push_And_Drop_From_Linked'Access);
      end;

      Version.Worktrees.Remove (Work);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Linked_Worktree_Uses_Common_Reflog;

   procedure Stash_Pop_Ref_Lock_Fails_Before_Apply
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Tracked_Stash (Root);
      Write_Stale_Lock (Stash_Ref_Path (Root) & ".lock");

      begin
         Version.Stash.Pop;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash pop must reject stale refs/stash lock");
      Assert_Tracked_Stash_Not_Applied (Root, "failed stash pop");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_Ref_Lock_Fails_Before_Apply;

   procedure Stash_Pop_Reflog_Lock_Fails_Before_Apply
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Tracked_Stash (Root);
      Write_Stale_Lock (Stash_Log_Path (Root) & ".lock");

      begin
         Version.Stash.Pop;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash pop must reject stale stash reflog lock");
      Assert_Tracked_Stash_Not_Applied (Root, "failed stash pop");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_Reflog_Lock_Fails_Before_Apply;

   procedure Stash_Branch_Creates_Branch_Applies_And_Drops
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;

      Version.Stash.Branch ("feature");

      Assert (Version.Branch.Current_Branch_Name = "feature",
              "stash branch must switch to the created branch");
      Assert (File_Text (Root, "a.txt") = "two",
              "stash branch must apply the selected stash");
      Assert (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
              "stash branch must drop stash after successful apply");
      Assert (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
              "stash ref must be removed");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Creates_Branch_Applies_And_Drops;

   procedure Stash_Branch_Ref_Lock_Fails_Before_Branch_Create
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Tracked_Stash (Root);
      Write_Stale_Lock (Stash_Ref_Path (Root) & ".lock");

      begin
         Version.Stash.Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash branch must reject stale refs/stash lock");
      Assert_Branch_Not_Created ("feature", "failed stash branch");
      Assert_Tracked_Stash_Not_Applied (Root, "failed stash branch");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Ref_Lock_Fails_Before_Branch_Create;

   procedure Stash_Branch_Reflog_Lock_Fails_Before_Branch_Create
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Tracked_Stash (Root);
      Write_Stale_Lock (Stash_Log_Path (Root) & ".lock");

      begin
         Version.Stash.Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash branch must reject stale stash reflog lock");
      Assert_Branch_Not_Created ("feature", "failed stash branch");
      Assert_Tracked_Stash_Not_Applied (Root, "failed stash branch");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Reflog_Lock_Fails_Before_Branch_Create;

   procedure Stash_Branch_Switch_Failure_Removes_Created_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Head_Lock : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Root, ".git"), "HEAD.lock");
      Feature_Log : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Root, ".git"), "logs"),
              "refs"),
           "heads/feature");
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Tracked_Stash (Root);
      Write_Stale_Lock (Head_Lock);

      begin
         Version.Stash.Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash branch must reject stale HEAD lock");
      Assert_Branch_Not_Created ("feature", "failed stash branch");
      Assert_Tracked_Stash_Not_Applied (Root, "failed stash branch");
      Assert
        (Ada.Directories.Exists (Head_Lock),
         "failed stash branch must preserve stale HEAD lock");
      Assert
        (not Ada.Directories.Exists (Feature_Log),
         "failed stash branch must remove created branch reflog");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Switch_Failure_Removes_Created_Branch;

   procedure Stash_Branch_Explicit_Stash_Drops_Selected_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Newer_Id : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
      Newer_Id := Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");

      Version.Stash.Branch ("older", "stash@{1}");

      Assert (Version.Branch.Current_Branch_Name = "older",
              "stash branch must switch to selected stash branch");
      Assert (File_Text (Root, "a.txt") = "two",
              "stash branch must apply the selected older stash");
      Assert (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
              "stash branch must drop only the selected stash");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}")
         = Newer_Id,
         "stash branch must keep newer stash entries");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Explicit_Stash_Drops_Selected_Only;

   procedure Stash_Branch_Existing_Target_Keeps_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Version.Branch.Create_Branch ("feature");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;

      begin
         Version.Stash.Branch ("feature");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash branch must reject an existing target branch");
      Assert (Version.Branch.Current_Branch_Name = "main",
              "failed stash branch must leave current branch unchanged");
      Assert (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
              "failed stash branch must keep the stash");
      Assert (File_Text (Root, "a.txt") = "one",
              "failed stash branch after push must leave cleaned working tree");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Branch_Existing_Target_Keeps_Stash;

   procedure Stash_Drop_Multiple_Resolves_Zero_And_One
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      First_Id  : Version.Objects.Object_Id_Storage;
      Second_Id : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      First_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
      Second_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{1}")
         = First_Id,
         "stash@{1} must resolve older stash");
      Version.Stash.Drop ("stash@{0}");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}")
         = First_Id,
         "dropping top must expose older stash");
      Assert (Second_Id /= First_Id, "second stash should be distinct");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Drop_Multiple_Resolves_Zero_And_One;

   procedure Stash_Rejects_Invalid_Specs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;

      procedure Assert_Invalid (Spec : String) is
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Version.Objects.Hex_Object_Id :=
                 Version.Stash.Resolve_Stash (Version.Repository.Open, Spec);
            begin
               pragma Unreferenced (Ignored);
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Stash.Invalid_Stash_Spec_Diagnostic (Spec),
                  "invalid stash resolve diagnostic must remain stable");
         end;

         Assert (Raised, "invalid stash resolve must raise Data_Error");

         Raised := False;
         begin
            Version.Stash.Drop (Spec);
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Assert
                 (Ada.Exceptions.Exception_Message (E)
                  = Version.Stash.Invalid_Stash_Spec_Diagnostic (Spec),
                  "invalid stash drop diagnostic must remain stable");
         end;

         Assert (Raised, "invalid stash drop must raise Data_Error");
      end Assert_Invalid;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;

      Assert_Invalid ("stash@{}");
      Assert_Invalid ("stash@{-1}");
      Assert_Invalid ("stash@{abc}");
      Assert_Invalid ("stash@{999999999999999999999999}");
      Assert_Invalid ("stash{0}");
      Assert_Invalid ("stash@{0");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Rejects_Invalid_Specs;

   procedure Stash_Include_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));
      Version.Stash.Push (Include_Untracked => True);
      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "u.txt")),
         "include-untracked must remove untracked file after push");
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "u.txt") = "untracked",
         "include-untracked apply must restore untracked file");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Include_Untracked;

   procedure Stash_Conflict_Keeps_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "stash" & Character'Val (10));
      Version.Stash.Push;
      Write_File (Root, "a.txt", "head" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("head change");
      begin
         Version.Stash.Pop;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Stash.Apply_Conflicts_Diagnostic,
               "stash apply conflict diagnostic must remain stable");
      end;
      Assert (Raised, "stash pop conflict must raise");
      Assert
        (Version.Merge_State.State_Exists (Version.Repository.Open),
         "stash conflict must write merge state");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "conflicted pop must keep stash");
      Assert
        (Ada.Strings.Fixed.Index (File_Text (Root, "a.txt"), "<<<<<<<") /= 0,
         "conflicted apply must write conflict markers");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Conflict_Keeps_Stash;

   procedure Stash_Apply_Older_Entry_Keeps_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      First_Id  : Version.Objects.Object_Id_Storage;
      Second_Id : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      First_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
      Second_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");

      Version.Stash.Apply ("stash@{1}");
      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash apply stash@{1} must restore the older selected entry");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}")
         = Second_Id,
         "applying an older stash must keep the newest stash entry");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{1}")
         = First_Id,
         "applying an older stash must keep that older stash entry");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Older_Entry_Keeps_Stack;

   procedure Stash_Drop_Non_Top_Rewrites_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      First_Id  : Version.Objects.Object_Id_Storage;
      Second_Id : Version.Objects.Object_Id_Storage;
      Third_Id  : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      First_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
      Second_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Write_File (Root, "a.txt", "four" & Character'Val (10));
      Version.Stash.Push;
      Third_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");

      Version.Stash.Drop ("stash@{1}");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}")
         = Third_Id,
         "dropping a non-top stash must keep newer entries in place");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{1}")
         = First_Id,
         "dropping a non-top stash must expose the next older remaining entry");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 2,
         "dropping a non-top stash must remove exactly one entry");
      Assert
        (Second_Id /= First_Id and then Second_Id /= Third_Id,
         "middle stash should be a distinct dropped entry");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Drop_Non_Top_Rewrites_Stack;

   procedure Stash_Staged_Addition_Is_Cleaned_And_Applies
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "new.txt", "new" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add new.txt");

      Version.Stash.Push;

      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "new.txt")),
         "stash push must remove a staged addition from the working tree");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Version.Stash.Apply;
      Assert
        (File_Text (Root, "new.txt") = "new",
         "stash apply must restore a staged addition as a working-tree file");
      Version.Git_Fixtures.Run
        (Root, "git status --porcelain | grep -F '?? new.txt'");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Staged_Addition_Is_Cleaned_And_Applies;

   procedure Stash_Tracked_Delete_Is_Cleaned_And_Applies
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Version.Files.Delete_File_If_Exists
        (Version.Test_Support.Join (Root, "a.txt"));

      Version.Stash.Push;

      Assert
        (File_Text (Root, "a.txt") = "one",
         "stash push must restore a deleted tracked file to HEAD");
      Version.Git_Fixtures.Run (Root, "test -z ""$(git status --porcelain)""");

      Version.Stash.Apply;
      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "a.txt")),
         "stash apply must reapply a tracked deletion");
      Version.Git_Fixtures.Run
        (Root, "git status --porcelain | grep -F ' D a.txt'");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Tracked_Delete_Is_Cleaned_And_Applies;

   procedure Stash_Drop_Only_Entry_Removes_Ref_And_Log
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;

      Version.Stash.Drop;

      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "dropping the only stash must empty the stash list");
      Assert (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
              "stash ref must be removed");
      Assert (not Ada.Directories.Exists (Stash_Log_Path (Root)),
              "stash reflog must be removed");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Drop_Only_Entry_Removes_Ref_And_Log;

   procedure Stash_Clear_Removes_All_Entries_Ref_And_Log
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;

      Version.Stash.Clear;

      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "stash clear must remove all stash entries");
      Assert (not Ada.Directories.Exists (Stash_Ref_Path (Root)),
              "stash ref must be removed");
      Assert (not Ada.Directories.Exists (Stash_Log_Path (Root)),
              "stash reflog must be removed");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Clear_Removes_All_Entries_Ref_And_Log;

   procedure Stash_Clear_Log_Directory_Preserves_Stash_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;

      declare
         Ref_Before : constant String :=
           Version.Files.Read_Binary_File (Stash_Ref_Path (Root));
      begin
         Ada.Directories.Delete_File (Stash_Log_Path (Root));
         Ada.Directories.Create_Path (Stash_Log_Path (Root));
         Version.Test_Support.Write_Text_File
           (Version.Test_Support.Join (Stash_Log_Path (Root), "sentinel"),
            "keep" & Character'Val (10));

         begin
            Version.Stash.Clear;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert (Raised, "stash clear must reject non-file stash reflog");
         Assert
           (Version.Files.Read_Binary_File (Stash_Ref_Path (Root)) = Ref_Before,
            "failed stash clear must restore refs/stash bytes");
         Assert
           (Ada.Directories.Exists (Stash_Log_Path (Root))
            and then Ada.Directories.Kind (Stash_Log_Path (Root)) =
              Ada.Directories.Directory,
            "failed stash clear must leave non-file stash reflog in place");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Clear_Log_Directory_Preserves_Stash_Ref;

   procedure Stash_Apply_Requires_Clean_Worktree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Write_File (Root, "local.txt", "local" & Character'Val (10));

      begin
         Version.Stash.Apply;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised, "stash apply must reject a dirty working tree in Phase 29");
      Assert
        (File_Text (Root, "a.txt") = "one",
         "rejected stash apply must not modify tracked files");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "rejected stash apply must keep the stash");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Requires_Clean_Worktree;

   procedure Stash_Pop_Older_Entry_Drops_Selected_Only
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir   : constant String := Ada.Directories.Current_Directory;
      First_Id  : Version.Objects.Object_Id_Storage;
      Second_Id : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      First_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");
      Write_File (Root, "a.txt", "three" & Character'Val (10));
      Version.Stash.Push;
      Second_Id :=
        Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}");

      Version.Stash.Pop ("stash@{1}");

      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash pop stash@{1} must apply the selected older entry");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "popping an older stash must remove only the selected entry");
      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}")
         = Second_Id,
         "popping an older stash must keep newer entries");
      Assert
        (First_Id /= Second_Id,
         "older and newer stash ids should be distinct");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_Older_Entry_Drops_Selected_Only;

   procedure Stash_Include_Untracked_Preserves_Ignored
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File
        (Root, ".gitignore", "*.ignored" & Character'Val (10), "ignore rule");
      Write_File (Root, "kept.ignored", "ignored" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));

      Version.Stash.Push (Include_Untracked => True);

      Assert
        (Ada.Directories.Exists
           (Version.Test_Support.Join (Root, "kept.ignored")),
         "include-untracked stash must preserve ignored files");
      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "u.txt")),
         "include-untracked stash must remove stashed untracked files");
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "u.txt") = "untracked",
         "include-untracked stash must restore non-ignored untracked files");
      Assert
        (File_Text (Root, "kept.ignored") = "ignored",
         "ignored files must remain untouched across stash apply");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Include_Untracked_Preserves_Ignored;

   procedure Stash_Apply_Rejects_In_Progress_Merge_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      declare
         Repo     : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Head_Id  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Refs.Current_Commit_Id (Repo));
         Stash_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Stash.Resolve_Stash (Repo, "stash@{0}");
      begin
         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Head_Id,
            Target_Id     => Stash_Id,
            Target_Branch => "merge");
      end;

      begin
         Version.Stash.Apply;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Stash.Apply_In_Progress_State_Diagnostic,
               "stash apply merge-state diagnostic must remain stable");
      end;

      Assert
        (Raised, "stash apply must reject an in-progress merge/replay state");
      Assert
        (File_Text (Root, "a.txt") = "one",
         "rejected stash apply with merge state must not modify tracked files");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "rejected stash apply with merge state must keep the stash");
      Version.Merge_State.Clear_State (Version.Repository.Open);
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Version.Merge_State.Clear_State (Version.Repository.Open);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Rejects_In_Progress_Merge_State;

   procedure Stash_Invalid_And_Out_Of_Range_Specs_Raise
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Invalid_Raised : Boolean := False;
      Range_Raised   : Boolean := False;
      Ignored        : Version.Objects.Object_Id_Storage;
      pragma Unreferenced (Ignored);
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;

      begin
         Ignored :=
           Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{}");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Invalid_Raised := True;
      end;
      begin
         Ignored :=
           Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{9}");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Range_Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Stash.Stash_Spec_Out_Of_Range_Diagnostic ("stash@{9}"),
               "out-of-range stash diagnostic must remain stable");
      end;

      Assert (Invalid_Raised, "malformed stash spec must raise Data_Error");
      Assert (Range_Raised, "out-of-range stash spec must raise Data_Error");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Invalid_And_Out_Of_Range_Specs_Raise;

   procedure Stash_No_Changes_Does_Not_Create_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Version.Stash.Push;
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "clean stash push must not create stash");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_No_Changes_Does_Not_Create_Stash;

   procedure Stash_Detached_HEAD_Message
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      declare
         Head : constant String :=
           Version.Refs.Current_Commit_Id (Version.Repository.Open);
      begin
         Version.Git_Fixtures.Run (Root, "git checkout --detach " & Head);
      end;
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Assert
        (Ada.Strings.Fixed.Index
           (To_String
              (Version.Stash.List_Entries (Version.Repository.Open)
                 .First_Element
                 .Message),
            "WIP on detached HEAD:")
         /= 0,
         "detached HEAD stash message must mention detached HEAD");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Detached_HEAD_Message;

   procedure Stash_Push_Pathspec_Stashes_Only_Selected_Tracked_Path
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base-a");
      Commit_File (Root, "b.txt", "one" & Character'Val (10), "base-b");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "b.txt", "two" & Character'Val (10));
      Version.Pathspec.Append_Parse (Specs, "a.txt");

      Version.Stash.Push (Pathspecs => Specs);

      Assert (File_Text (Root, "a.txt") = "one",
              "pathspec stash must reset selected tracked path");
      Assert (File_Text (Root, "b.txt") = "two",
              "pathspec stash must leave non-selected tracked path dirty");
      Write_File (Root, "b.txt", "one" & Character'Val (10));
      Version.Stash.Apply;
      Assert (File_Text (Root, "a.txt") = "two",
              "pathspec stash apply must restore selected path change");
      Assert (File_Text (Root, "b.txt") = "one",
              "pathspec stash apply must not restore non-selected path change");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Push_Pathspec_Stashes_Only_Selected_Tracked_Path;

   procedure Stash_Push_Pathspec_No_Match_Does_Not_Create_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Pathspec.Append_Parse (Specs, "missing.txt");

      Version.Stash.Push (Pathspecs => Specs);

      Assert (File_Text (Root, "a.txt") = "two",
              "no-match pathspec stash must not reset unrelated change");
      Assert (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
              "no-match pathspec stash must not create stash entry");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Push_Pathspec_No_Match_Does_Not_Create_Stash;

   procedure Stash_Push_Pathspec_Filters_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Write_File (Root, "stash.dat", "selected" & Character'Val (10));
      Write_File (Root, "keep.dat", "kept" & Character'Val (10));
      Version.Pathspec.Append_Parse (Specs, "stash.dat");

      Version.Stash.Push (Include_Untracked => True, Pathspecs => Specs);

      Assert (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "stash.dat")),
              "pathspec untracked stash must remove selected untracked file");
      Assert (File_Text (Root, "keep.dat") = "kept",
              "pathspec untracked stash must leave non-selected untracked file");
      Ada.Directories.Delete_File (Version.Test_Support.Join (Root, "keep.dat"));
      Version.Stash.Apply;
      Assert (File_Text (Root, "stash.dat") = "selected",
              "pathspec untracked stash apply must restore selected untracked file");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Push_Pathspec_Filters_Untracked;

   procedure Stash_Include_Ignored_Stores_Removes_And_Restores
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, ".gitignore", "*.log" & Character'Val (10), "ignore");
      Write_File (Root, "ignored.log", "ignored" & Character'Val (10));

      Version.Stash.Push (Include_Untracked => True, Include_Ignored => True);

      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "ignored.log")),
         "include-ignored stash must remove ignored file after push");
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "ignored.log") = "ignored",
         "include-ignored stash apply must restore ignored file");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Include_Ignored_Stores_Removes_And_Restores;

   procedure Stash_Include_Ignored_Pathspec_Filters_Ignored
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, ".gitignore", "*.log" & Character'Val (10), "ignore");
      Write_File (Root, "selected.log", "selected" & Character'Val (10));
      Write_File (Root, "kept.log", "kept" & Character'Val (10));
      Version.Pathspec.Append_Parse (Specs, "selected.log");

      Version.Stash.Push
        (Include_Untracked => True, Include_Ignored => True, Pathspecs => Specs);

      Assert
        (not Ada.Directories.Exists
               (Version.Test_Support.Join (Root, "selected.log")),
         "include-ignored pathspec stash must remove selected ignored file");
      Assert
        (File_Text (Root, "kept.log") = "kept",
         "include-ignored pathspec stash must preserve non-selected ignored file");
      Ada.Directories.Delete_File (Version.Test_Support.Join (Root, "kept.log"));
      Version.Stash.Apply;
      Assert
        (File_Text (Root, "selected.log") = "selected",
         "include-ignored pathspec stash apply must restore selected ignored file");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Include_Ignored_Pathspec_Filters_Ignored;

   procedure Stash_Show_Summary_Includes_Tracked_And_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));

      Version.Stash.Push (Include_Untracked => True);

      declare
         Text : constant String := Version.Stash.Show;
      begin
         Assert
           (Ada.Strings.Fixed.Index (Text, "M a.txt") /= 0,
            "stash show summary must list tracked modifications");
         Assert
           (Ada.Strings.Fixed.Index (Text, "A u.txt") /= 0,
            "stash show summary must list untracked additions");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Show_Summary_Includes_Tracked_And_Untracked;

   procedure Stash_Show_Patch_Includes_Tracked_And_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));

      Version.Stash.Push (Include_Untracked => True);

      declare
         Text : constant String := Version.Stash.Show (Patch => True);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Text, "diff --version a/a.txt b/a.txt") /= 0,
            "stash show patch must include tracked file diff");
         Assert
           (Ada.Strings.Fixed.Index
              (Text, "diff --version a/u.txt b/u.txt") /= 0,
            "stash show patch must include untracked file diff");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Show_Patch_Includes_Tracked_And_Untracked;

   procedure Stash_Show_Pathspec_Filters_Summary
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base-a");
      Commit_File (Root, "b.txt", "one" & Character'Val (10), "base-b");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "b.txt", "two" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));
      Version.Stash.Push (Include_Untracked => True);
      Version.Pathspec.Append_Parse (Specs, "a.txt");

      declare
         Text : constant String := Version.Stash.Show (Pathspecs => Specs);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Text, "M a.txt") /= 0,
            "stash show pathspec summary must include selected tracked path");
         Assert
           (Ada.Strings.Fixed.Index (Text, "M b.txt") = 0,
            "stash show pathspec summary must omit non-selected tracked path");
         Assert
           (Ada.Strings.Fixed.Index (Text, "A u.txt") = 0,
            "stash show pathspec summary must omit non-selected untracked path");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Show_Pathspec_Filters_Summary;

   procedure Stash_Show_Pathspec_Filters_Patch_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));
      Version.Stash.Push (Include_Untracked => True);
      Version.Pathspec.Append_Parse (Specs, "u.txt");

      declare
         Text : constant String :=
           Version.Stash.Show (Patch => True, Pathspecs => Specs);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Text, "diff --version a/u.txt b/u.txt") /= 0,
            "stash show pathspec patch must include selected untracked path");
         Assert
           (Ada.Strings.Fixed.Index
              (Text, "diff --version a/a.txt b/a.txt") = 0,
            "stash show pathspec patch must omit non-selected tracked path");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Show_Pathspec_Filters_Patch_Untracked;

   procedure Stash_Apply_Pathspec_Restores_Selected_Tracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base-a");
      Commit_File (Root, "b.txt", "one" & Character'Val (10), "base-b");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "b.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Version.Pathspec.Append_Parse (Specs, "a.txt");

      Version.Stash.Apply (Pathspecs => Specs);

      Assert
        (File_Text (Root, "a.txt") = "two",
         "pathspec stash apply must restore selected tracked path");
      Assert
        (File_Text (Root, "b.txt") = "one",
         "pathspec stash apply must leave non-selected tracked path at HEAD");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "pathspec stash apply must keep stash entry");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Pathspec_Restores_Selected_Tracked;

   procedure Stash_Apply_Pathspec_Restores_Selected_Untracked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "base.txt", "base" & Character'Val (10), "base");
      Write_File (Root, "selected.txt", "selected" & Character'Val (10));
      Write_File (Root, "kept.txt", "kept" & Character'Val (10));
      Version.Stash.Push (Include_Untracked => True);
      Version.Pathspec.Append_Parse (Specs, "selected.txt");

      Version.Stash.Apply (Pathspecs => Specs);

      Assert
        (File_Text (Root, "selected.txt") = "selected",
         "pathspec stash apply must restore selected untracked path");
      Assert
        (not Ada.Directories.Exists (Version.Test_Support.Join (Root, "kept.txt")),
         "pathspec stash apply must not restore non-selected untracked path");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "pathspec untracked apply must keep stash entry");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Pathspec_Restores_Selected_Untracked;

   procedure Stash_Apply_Pathspec_Untracked_Collision_No_Partial_Write
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Write_File (Root, "u.txt", "untracked" & Character'Val (10));
      declare
         Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Stash.Create (Include_Untracked => True));
      begin
         Write_File (Root, "u.txt", "collision" & Character'Val (10));
         Version.Pathspec.Append_Parse (Specs, "a.txt");
         Version.Pathspec.Append_Parse (Specs, "u.txt");
         begin
            Version.Stash.Store (Id);
            Version.Stash.Apply (Pathspecs => Specs);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Assert (Raised, "pathspec stash apply must reject untracked collision");
      Assert
        (File_Text (Root, "a.txt") = "two",
         "failed pathspec stash apply must not partially restore tracked paths");
      Assert
        (File_Text (Root, "u.txt") = "collision",
         "failed pathspec stash apply must preserve colliding untracked path");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Apply_Pathspec_Untracked_Collision_No_Partial_Write;

   procedure Stash_Pop_Pathspec_No_Match_Keeps_Stash
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Version.Stash.Push;
      Version.Pathspec.Append_Parse (Specs, "missing.txt");

      Version.Stash.Pop (Pathspecs => Specs);

      Assert
        (File_Text (Root, "a.txt") = "one",
         "no-match pathspec stash pop must not modify worktree");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Length = 1,
         "no-match pathspec stash pop must keep stash entry");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Pop_Pathspec_No_Match_Keeps_Stash;

   procedure Stash_Create_Writes_Commit_Without_Updating_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));

      declare
         Id : constant String := Version.Stash.Create;
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Id),
            "stash create must return a commit id when changes exist");
      end;

      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash create must not reset tracked worktree paths");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "stash create must not update refs/stash");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Create_Writes_Commit_Without_Updating_Stack;

   procedure Stash_Create_No_Changes_Returns_Empty
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");

      Assert
        (Version.Stash.Create = "",
         "stash create must return an empty id when nothing is stashable");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "empty stash create must not update refs/stash");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Create_No_Changes_Returns_Empty;

   procedure Stash_Store_Adds_Created_Commit_To_Stack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Id      : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Id := Version.Objects.To_Object_Id (Version.Stash.Create);

      Version.Stash.Store (Id, "custom stash message");

      Assert
        (Version.Stash.Resolve_Stash (Version.Repository.Open, "stash@{0}") = Id,
         "stash store must make the supplied stash commit the top entry");
      Assert
        (To_String
           (Version.Stash.List_Entries
              (Version.Repository.Open).First_Element.Message)
         = "custom stash message",
         "stash store must preserve supplied list message");
      Assert
        (File_Text (Root, "a.txt") = "two",
         "stash store must not reset tracked worktree paths");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Store_Adds_Created_Commit_To_Stack;

   procedure Stash_Store_Default_Message_Uses_Stash_Subject
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Id      : Version.Objects.Object_Id_Storage;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");
      Write_File (Root, "a.txt", "two" & Character'Val (10));
      Id := Version.Objects.To_Object_Id (Version.Stash.Create);

      Version.Stash.Store (Id);

      Assert
        (Ada.Strings.Fixed.Index
           (To_String
              (Version.Stash.List_Entries
                 (Version.Repository.Open).First_Element.Message),
            "WIP on") = 1,
         "stash store default message must use stored stash commit subject");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Store_Default_Message_Uses_Stash_Subject;

   procedure Stash_Store_Rejects_Non_Stash_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Commit_File (Root, "a.txt", "one" & Character'Val (10), "base");

      begin
         Version.Stash.Store
           (Version.Revisions.Resolve_Commit (Version.Repository.Open, "HEAD"),
            "bad stash");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "stash store must reject non-stash-shaped commits");
      Assert
        (Version.Stash.List_Entries (Version.Repository.Open).Is_Empty,
         "rejected stash store must not update refs/stash");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Store_Rejects_Non_Stash_Commit;

   procedure Stash_Drop_Ref_Lock_Preserves_Stash_Reflog
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Ref_Lock : constant String := Stash_Ref_Path (Root) & ".lock";
      Lock_Content : constant String := "stale stash ref lock" & Character'Val (10);
      Raised : Boolean := False;
   begin
      Version.Init.Init (Root);
      Configure_User (Root);
      Ada.Directories.Set_Directory (Root);
      Create_Two_Tracked_Stashes (Root);

      declare
         Ref_Before : constant String :=
           Version.Files.Read_Binary_File (Stash_Ref_Path (Root));
         Log_Before : constant String :=
           Version.Files.Read_Binary_File (Stash_Log_Path (Root));
      begin
         Version.Test_Support.Write_Text_File (Ref_Lock, Lock_Content);

         declare
            Lock_Before : constant String :=
              Version.Files.Read_Binary_File (Ref_Lock);
         begin
            begin
               Version.Stash.Drop ("stash@{0}");
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;

            Assert (Raised, "stale stash ref lock must reject stash drop");
            Assert
              (Version.Files.Read_Binary_File (Stash_Ref_Path (Root)) = Ref_Before,
               "failed stash drop must preserve refs/stash bytes");
            Assert
              (Version.Files.Read_Binary_File (Stash_Log_Path (Root)) = Log_Before,
               "failed stash drop must restore stash reflog bytes");
            Assert
              (Version.Files.Read_Binary_File (Ref_Lock) = Lock_Before,
               "failed stash drop must preserve stale refs/stash lock");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Stash_Drop_Ref_Lock_Preserves_Stash_Reflog;

   procedure Stash_Test_Support_Formats_Storage_Fixtures
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Id : constant String := "1111111111111111111111111111111111111111";
      New_Id : constant String := "2222222222222222222222222222222222222222";
      Other_Id : constant String := "3333333333333333333333333333333333333333";
      Line : constant String :=
        Version.Stash_Test_Support.Stash_Reflog_Line
          (Old_Id => Old_Id, New_Id => New_Id, Message => "message");
      Broken : constant String :=
        Version.Stash_Test_Support.Broken_Reflog_Chain
          (First_Id => New_Id, Second_Id => Other_Id);
   begin
      Assert
        (Stash_Ref_Path (Root) = Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join (Root, ".git"), "refs"),
            "stash"),
         "stash ref helper path must match repository layout");
      Assert
        (Stash_Log_Path (Root) = Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join
                 (Version.Test_Support.Join (Root, ".git"), "logs"),
               "refs"),
            "stash"),
         "stash log helper path must match repository layout");
      Assert
        (Line = Old_Id & " " & New_Id
         & " Version <version@example.invalid> 0 +0000"
         & Character'Val (9) & "message",
         "stash reflog helper must preserve strict line shape");
      Assert
        (Broken = Version.Stash_Test_Support.Stash_Reflog_Line
           (Version.Stash_Test_Support.Zero_Id, New_Id, "first")
         & Character'Val (10)
         & Version.Stash_Test_Support.Stash_Reflog_Line
           (Version.Stash_Test_Support.Bad_Old_Id, Other_Id, "second")
         & Character'Val (10),
         "broken chain helper must build two newline-terminated reflog lines");

      Version.Stash_Test_Support.Write_Stash_Storage
        (Root => Root, New_Id => New_Id, Message => "stored");
      Assert
        (Version.Test_Support.Read_Text_File (Stash_Ref_Path (Root)) = New_Id,
         "stash storage helper must write refs/stash id");
      Assert
        (Version.Test_Support.Read_Text_File (Stash_Log_Path (Root))
         = Version.Stash_Test_Support.Stash_Reflog_Line
             (Version.Stash_Test_Support.Zero_Id, New_Id, "stored"),
         "stash storage helper must write normalized reflog content");
   end Stash_Test_Support_Formats_Storage_Fixtures;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Stash_Push_Tracked_Modification_Apply_Keeps_Stash'Access,
         "Stash: push tracked modification and apply keeps stash");
      Register_Routine
        (T,
         Stash_Push_Staged_Change_Restores_Index'Access,
         "Stash: push staged change restores index");
      Register_Routine
        (T, Stash_Pop_Drops_Top'Access, "Stash: pop restores and drops top");
      Register_Routine
        (T,
         Stash_Linked_Worktree_Uses_Common_Reflog'Access,
         "Stash: linked worktree uses common reflog");
      Register_Routine
        (T,
         Stash_Pop_Ref_Lock_Fails_Before_Apply'Access,
         "Stash: pop ref lock fails before apply");
      Register_Routine
        (T,
         Stash_Pop_Reflog_Lock_Fails_Before_Apply'Access,
         "Stash: pop reflog lock fails before apply");
      Register_Routine
        (T,
         Stash_Branch_Creates_Branch_Applies_And_Drops'Access,
         "Stash: branch creates branch applies and drops stash");
      Register_Routine
        (T,
         Stash_Branch_Ref_Lock_Fails_Before_Branch_Create'Access,
         "Stash: branch ref lock fails before branch create");
      Register_Routine
        (T,
         Stash_Branch_Reflog_Lock_Fails_Before_Branch_Create'Access,
         "Stash: branch reflog lock fails before branch create");
      Register_Routine
        (T,
         Stash_Branch_Switch_Failure_Removes_Created_Branch'Access,
         "Stash: branch switch failure removes created branch");
      Register_Routine
        (T,
         Stash_Branch_Explicit_Stash_Drops_Selected_Only'Access,
         "Stash: branch selected stash drops selected only");
      Register_Routine
        (T,
         Stash_Branch_Existing_Target_Keeps_Stash'Access,
         "Stash: branch existing target keeps stash");
      Register_Routine
        (T,
         Stash_Drop_Multiple_Resolves_Zero_And_One'Access,
         "Stash: multiple entries and top drop");
      Register_Routine
        (T,
         Stash_Drop_Ref_Lock_Preserves_Stash_Reflog'Access,
         "Stash: failed drop restores stash reflog after ref lock");
      Register_Routine
        (T,
         Stash_Rejects_Invalid_Specs'Access,
         "Stash: rejects invalid stash specs");
      Register_Routine
        (T,
         Stash_Include_Untracked'Access,
         "Stash: include untracked stores removes and restores file");
      Register_Routine
        (T,
         Stash_Push_Pathspec_Stashes_Only_Selected_Tracked_Path'Access,
         "Stash: pathspec stashes only selected tracked path");
      Register_Routine
        (T,
         Stash_Push_Pathspec_No_Match_Does_Not_Create_Stash'Access,
         "Stash: pathspec no-match does not create stash");
      Register_Routine
        (T,
         Stash_Push_Pathspec_Filters_Untracked'Access,
         "Stash: pathspec filters untracked files");
      Register_Routine
        (T,
         Stash_Include_Ignored_Stores_Removes_And_Restores'Access,
         "Stash: include ignored stores removes and restores file");
      Register_Routine
        (T,
         Stash_Include_Ignored_Pathspec_Filters_Ignored'Access,
         "Stash: include ignored pathspec filters ignored files");
      Register_Routine
        (T,
         Stash_Show_Summary_Includes_Tracked_And_Untracked'Access,
         "Stash: show summary includes tracked and untracked paths");
      Register_Routine
        (T,
         Stash_Show_Patch_Includes_Tracked_And_Untracked'Access,
         "Stash: show patch includes tracked and untracked paths");
      Register_Routine
        (T,
         Stash_Show_Pathspec_Filters_Summary'Access,
         "Stash: show pathspec filters summary");
      Register_Routine
        (T,
         Stash_Show_Pathspec_Filters_Patch_Untracked'Access,
         "Stash: show pathspec filters patch untracked path");
      Register_Routine
        (T,
         Stash_Apply_Pathspec_Restores_Selected_Tracked'Access,
         "Stash: apply pathspec restores selected tracked path");
      Register_Routine
        (T,
         Stash_Apply_Pathspec_Restores_Selected_Untracked'Access,
         "Stash: apply pathspec restores selected untracked path");
      Register_Routine
        (T,
         Stash_Apply_Pathspec_Untracked_Collision_No_Partial_Write'Access,
         "Stash: apply pathspec untracked collision has no partial write");
      Register_Routine
        (T,
         Stash_Pop_Pathspec_No_Match_Keeps_Stash'Access,
         "Stash: pop pathspec no-match keeps stash");
      Register_Routine
        (T,
         Stash_Create_Writes_Commit_Without_Updating_Stack'Access,
         "Stash: create writes commit without updating stack");
      Register_Routine
        (T,
         Stash_Create_No_Changes_Returns_Empty'Access,
         "Stash: create no changes returns empty id");
      Register_Routine
        (T,
         Stash_Store_Adds_Created_Commit_To_Stack'Access,
         "Stash: store adds created commit to stack");
      Register_Routine
        (T,
         Stash_Store_Default_Message_Uses_Stash_Subject'Access,
         "Stash: store default message uses stash subject");
      Register_Routine
        (T,
         Stash_Store_Rejects_Non_Stash_Commit'Access,
         "Stash: store rejects non-stash commit");
      Register_Routine
        (T, Stash_Conflict_Keeps_Stash'Access, "Stash: conflict keeps stash");
      Register_Routine
        (T,
         Stash_Apply_Older_Entry_Keeps_Stack'Access,
         "Stash: apply older entry keeps stack");
      Register_Routine
        (T,
         Stash_Drop_Non_Top_Rewrites_Stack'Access,
         "Stash: drop non-top rewrites stack");
      Register_Routine
        (T,
         Stash_Staged_Addition_Is_Cleaned_And_Applies'Access,
         "Stash: staged addition is cleaned and reapplied");
      Register_Routine
        (T,
         Stash_Tracked_Delete_Is_Cleaned_And_Applies'Access,
         "Stash: tracked delete is cleaned and reapplied");
      Register_Routine
        (T,
         Stash_Drop_Only_Entry_Removes_Ref_And_Log'Access,
         "Stash: drop only entry removes ref and log");
      Register_Routine
        (T,
         Stash_Clear_Removes_All_Entries_Ref_And_Log'Access,
         "Stash: clear removes all entries ref and log");
      Register_Routine
        (T,
         Stash_Clear_Log_Directory_Preserves_Stash_Ref'Access,
         "Stash: failed clear restores stash ref after log delete failure");
      Register_Routine
        (T,
         Stash_Pop_Older_Entry_Drops_Selected_Only'Access,
         "Stash: pop older entry drops selected only");
      Register_Routine
        (T,
         Stash_Include_Untracked_Preserves_Ignored'Access,
         "Stash: include untracked preserves ignored files");
      Register_Routine
        (T,
         Stash_Apply_Rejects_In_Progress_Merge_State'Access,
         "Stash: apply rejects in-progress merge state");
      Register_Routine
        (T,
         Stash_Invalid_And_Out_Of_Range_Specs_Raise'Access,
         "Stash: invalid and out-of-range specs raise");
      Register_Routine
        (T,
         Stash_Apply_Requires_Clean_Worktree'Access,
         "Stash: apply requires clean working tree");
      Register_Routine
        (T,
         Stash_No_Changes_Does_Not_Create_Stash'Access,
         "Stash: no changes does not create stash");
      Register_Routine
        (T,
         Stash_Test_Support_Formats_Storage_Fixtures'Access,
         "Stash: test support formats storage fixtures");
      Register_Routine
        (T,
         Stash_Detached_HEAD_Message'Access,
         "Stash: detached HEAD message");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Stash");
   end Name;

end Version.Stash.Tests;
