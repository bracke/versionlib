with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Characters.Handling;
with Ada.IO_Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Ada.Containers; use type Ada.Containers.Count_Type;
use type Ada.Directories.File_Kind;
with Ada.Containers.Indefinite_Ordered_Sets;

with Version.Working_Tree;
with Version.Restore;
with Version.Status;
with Version.Staging;
with Version.Objects; use Version.Objects;
use type Version.Objects.Object_Kind;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Refs;
with Version.Repository;
with Version.History;
with Version.Write;
with Version.Files;
with Version.Availability;
with Version.Config;
with Version.Merge_State;
with Version.Merge;
with Version.Reflog;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Rebase_State;
with Version.Cherry_Pick_State;
with Version.Revert_State;
with Version.Worktrees;
with Version.Hooks;
with Version.Revisions;
with Version.Tracking;
with Version.Stash;

package body Version.Branch is

   use type GNAT.OS_Lib.String_Access;

   --  Resolve a program name on PATH (GNAT.OS_Lib.Spawn does not search PATH).
   function Resolve_Program (Name : String) return String is
      P : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Locate_Exec_On_Path (Name);
   begin
      if P = null then
         return Name;
      end if;
      return R : constant String := P.all do
         GNAT.OS_Lib.Free (P);
      end return;
   end Resolve_Program;

   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   package Natural_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Natural);

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Is_Valid_Branch_Name
     (Name : String)
      return Boolean renames Version.Ref_Names.Is_Valid_Branch_Name;

   function Branch_Exists
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return Boolean
   is
   begin
      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & Name;
      end if;

      return Version.Refs.Ref_Exists
        (Repo => Repo,
         Name => "refs/heads/" & Name);
   end Branch_Exists;

   function Short_Id (Id : String) return String is
   begin
      if Id'Length <= 12 then
         return Id;
      else
         return Id (Id'First .. Id'First + 11);
      end if;
   end Short_Id;

   function Zero_Id return Version.Objects.Hex_Object_Id is
   begin
      return Version.Objects.Zero_Object_Id;
   end Zero_Id;

   procedure Require_Clean_Status (Allow_Untracked : Boolean := False) is
      Result : constant Version.Status.Status_Result :=
        Version.Status.Current_Status;
   begin
      if not Result.Changes.Is_Empty
        or else not Result.Staged.Is_Empty
        or else (not Allow_Untracked and then not Result.Untracked.Is_Empty)
        or else not Result.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot update branch: working tree is not clean";
      end if;
   end Require_Clean_Status;

   --  Git allows a merge to proceed with untracked files present, but refuses
   --  if a file the merge would bring in collides with an existing untracked
   --  working-tree file. Mirror that: called BEFORE the merge materializes
   --  anything, comparing the incoming target tree against current untracked
   --  files (checking afterwards would flag the merge's own fresh output).
   procedure Reject_Untracked_Overwrite
     (Target_Items : Version.Objects.Tree_Entry_Vectors.Vector)
   is
      LF     : constant Character := Character'Val (10);
      Status : constant Version.Status.Status_Result :=
        Version.Status.Current_Status;
   begin
      if Status.Untracked.Is_Empty then
         return;
      end if;

      for E of Target_Items loop
         for U of Status.Untracked loop
            if Ada.Strings.Unbounded."=" (U.Path, E.Path) then
               raise Ada.IO_Exceptions.Data_Error with
                 "The following untracked working tree files would be "
                 & "overwritten by merge:" & LF & ASCII.HT
                 & Ada.Strings.Unbounded.To_String (E.Path);
            end if;
         end loop;
      end loop;
   end Reject_Untracked_Overwrite;

   function Has_Stashable_Merge_Changes return Boolean is
      Result : constant Version.Status.Status_Result :=
        Version.Status.Current_Status;
   begin
      return not Result.Changes.Is_Empty
        or else not Result.Staged.Is_Empty
        or else not Result.Untracked.Is_Empty
        or else not Result.Conflicted.Is_Empty;
   end Has_Stashable_Merge_Changes;

   procedure Reject_Unsupported_Merge_Index
     (Repo : Version.Repository.Repository_Handle)
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      pragma Unreferenced (Entries);
   begin
      null;
   end Reject_Unsupported_Merge_Index;

   function Git_State_File
     (Repo : Version.Repository.Repository_Handle; Name : String) return String is
   begin
      return Join (Version.Repository.Git_Dir (Repo), Name);
   end Git_State_File;

   function Merge_Autostash_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Git_State_File (Repo, "MERGE_AUTOSTASH");
   end Merge_Autostash_Path;

   function Read_Merge_Autostash_Id
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Path : constant String := Merge_Autostash_Path (Repo);
      Text : constant String :=
        Ada.Strings.Fixed.Trim
          (Version.Files.Read_Binary_File (Path), Ada.Strings.Both);
      LF : constant Character := Character'Val (10);
      LF_Pos : constant Natural := Ada.Strings.Fixed.Index (Text, String'(1 => LF));
      Line : constant String :=
        (if LF_Pos = 0 then Text else Text (Text'First .. Text'First + LF_Pos - 2));
   begin
      if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git merge state: MERGE_AUTOSTASH";
      end if;

      return Version.Objects.To_Object_Id (Line);
   end Read_Merge_Autostash_Id;

   procedure Write_Merge_Autostash_Id
     (Repo     : Version.Repository.Repository_Handle;
      Stash_Id : Version.Objects.Hex_Object_Id) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => Merge_Autostash_Path (Repo),
         Content => To_String (Stash_Id) & Character'Val (10));
   end Write_Merge_Autostash_Id;

   procedure Create_Merge_Autostash
     (Repo : Version.Repository.Repository_Handle) is
   begin
      if Ada.Directories.Exists (Merge_Autostash_Path (Repo)) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot merge: MERGE_AUTOSTASH already exists";
      end if;

      if not Has_Stashable_Merge_Changes then
         return;
      end if;

      Version.Stash.Push (Include_Untracked => True);

      declare
         Stash_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Stash.Resolve_Stash (Repo, "stash@{0}");
      begin
         Write_Merge_Autostash_Id (Repo, Stash_Id);
         Version.Stash.Drop ("stash@{0}");
      end;
   end Create_Merge_Autostash;

   procedure Store_Merge_Autostash
     (Repo : Version.Repository.Repository_Handle) is
   begin
      if Ada.Directories.Exists (Merge_Autostash_Path (Repo)) then
         declare
            Stash_Id : constant Version.Objects.Hex_Object_Id :=
              Read_Merge_Autostash_Id (Repo);
         begin
            Version.Stash.Store (Stash_Id, "autostash");
            Version.Files.Delete_File_If_Exists (Merge_Autostash_Path (Repo));
         end;
      end if;
   end Store_Merge_Autostash;

   procedure Apply_Merge_Autostash
     (Repo : Version.Repository.Repository_Handle) is
   begin
      if Ada.Directories.Exists (Merge_Autostash_Path (Repo)) then
         declare
            Stash_Id : constant Version.Objects.Hex_Object_Id :=
              Read_Merge_Autostash_Id (Repo);
         begin
            Version.Stash.Apply_Autostash (Stash_Id);
            Version.Files.Delete_File_If_Exists (Merge_Autostash_Path (Repo));
         exception
            when others =>
               begin
                  Version.Stash.Store (Stash_Id, "autostash");
                  Version.Files.Delete_File_If_Exists (Merge_Autostash_Path (Repo));
               exception
                  when others =>
                     null;
               end;
               raise;
         end;
      end if;
   end Apply_Merge_Autostash;

   procedure Verify_Commit_Signature
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Args : GNAT.OS_Lib.Argument_List (1 .. 4) := [others => null];
      Status : Integer;
   begin
      Args (1) := new String'("-C");
      Args (2) := new String'(Version.Repository.Root_Path (Repo));
      Args (3) := new String'("verify-commit");
      Args (4) := new String'(To_String (Commit_Id));

      Status := GNAT.OS_Lib.Spawn (Program_Name => Resolve_Program ("git"), Args => Args);

      for I in Args'Range loop
         GNAT.OS_Lib.Free (Args (I));
      end loop;

      if Status /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot merge: target commit signature could not be verified";
      end if;
   exception
      when others =>
         for I in Args'Range loop
            if Args (I) /= null then
               GNAT.OS_Lib.Free (Args (I));
            end if;
         end loop;
         raise;
   end Verify_Commit_Signature;

   function Configured_Editor return String is
   begin
      if Ada.Environment_Variables.Exists ("GIT_EDITOR") then
         return Ada.Environment_Variables.Value ("GIT_EDITOR");
      elsif Ada.Environment_Variables.Exists ("VISUAL") then
         return Ada.Environment_Variables.Value ("VISUAL");
      elsif Ada.Environment_Variables.Exists ("EDITOR") then
         return Ada.Environment_Variables.Value ("EDITOR");
      else
         return "";
      end if;
   end Configured_Editor;

   function Edit_Merge_Message
     (Repo    : Version.Repository.Repository_Handle;
      Message : String) return String
   is
      Path : constant String := Git_State_File (Repo, "MERGE_MSG");
      Editor : constant String := Configured_Editor;
      Args : GNAT.OS_Lib.Argument_List (1 .. 1) := [others => null];
      Status : Integer;
   begin
      if Editor'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot edit merge message: no editor configured";
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Path => Path, Content => Message & Character'Val (10));
      Args (1) := new String'(Path);
      Status := GNAT.OS_Lib.Spawn (Program_Name => Editor, Args => Args);
      GNAT.OS_Lib.Free (Args (1));

      if Status /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot edit merge message: editor failed";
      end if;

      return Version.Files.Read_Binary_File (Path);
   exception
      when others =>
         if Args (1) /= null then
            GNAT.OS_Lib.Free (Args (1));
         end if;
         raise;
   end Edit_Merge_Message;

   procedure Require_Attached_HEAD
     (Operation : String;
      Repo      : Version.Repository.Repository_Handle)
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if not Version.Refs.Is_Attached (Head) then
         raise Ada.IO_Exceptions.Data_Error with Operation & ": HEAD is detached";
      end if;
   end Require_Attached_HEAD;

   procedure Require_No_Rebase_State
     (Operation : String;
      Repo      : Version.Repository.Repository_Handle) is
   begin
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with Operation & ": rebase in progress";
      end if;

      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with Operation & ": cherry-pick in progress";
      end if;

      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with Operation & ": revert in progress";
      end if;
   end Require_No_Rebase_State;

   function Head_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Join (Version.Repository.Git_Dir (Repo), "HEAD");
   end Head_Path;

   procedure Require_No_Lock (Path : String) is
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Path;
      end if;
   end Require_No_Lock;

   procedure Preflight_HEAD_Metadata
     (Repo : Version.Repository.Repository_Handle) is
   begin
      Require_No_Lock (Head_Path (Repo) & ".lock");
      Version.Reflog.Preflight_Append
        (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
   end Preflight_HEAD_Metadata;

   procedure Restore_HEAD_File
     (Repo    : Version.Repository.Repository_Handle;
      Content : String) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => Head_Path (Repo),
         Content => Content);
   end Restore_HEAD_File;

   procedure Write_HEAD
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Path      : constant String := Head_Path (Repo);
      Lock_Path : constant String := Path & ".lock";
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Lock_Path;
      end if;

      begin
         Version.Files.Write_Binary_File
           (Path    => Lock_Path,
            Content => "ref: refs/heads/" & Name & Character'Val (10));
         Version.Files.Atomic_Replace (Lock_Path, Path);
      exception
         when others =>
            Version.Files.Delete_File_If_Exists (Lock_Path);
            raise;
      end;
   end Write_HEAD;

   procedure Append_HEAD_Reflog
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Message : String) is
   begin
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => To_String (Old_Id),
         New_Id  => To_String (New_Id),
         Message => Message);
   end Append_HEAD_Reflog;

   procedure Append_HEAD_And_Current_Branch_Reflog
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Message : String)
   is
      Branch_Name : constant String := Version.Refs.Current_Branch_Name (Repo);
   begin
      Append_HEAD_Reflog
        (Repo    => Repo,
         Old_Id  => Old_Id,
         New_Id  => New_Id,
         Message => Message);

      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "refs/heads/" & Branch_Name,
         Old_Id  => To_String (Old_Id),
         New_Id  => To_String (New_Id),
         Message => Message);
   end Append_HEAD_And_Current_Branch_Reflog;

   function Branch_Ref_Path
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String
   is
   begin
      return Join
        (Version.Repository.Common_Git_Dir (Repo),
         "refs/heads/" & Name);
   end Branch_Ref_Path;

   function Branch_Reflog_Path
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String
   is
   begin
      Version.Ref_Names.Require_Branch_Name (Name);
      return Version.Reflog.Path (Repo, "refs/heads/" & Name);
   end Branch_Reflog_Path;

   procedure Ensure_Branch_Reflog_Deletable
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Path : constant String := Branch_Reflog_Path (Repo, Name);
   begin
      if Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         raise Ada.IO_Exceptions.Data_Error
           with "branch reflog is not an ordinary file: " & Path;
      end if;
   end Ensure_Branch_Reflog_Deletable;

   procedure Ensure_Branch_Restore_Available
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Lock_Path : constant String := Branch_Ref_Path (Repo, Name) & ".lock";
   begin
      if Ada.Directories.Exists (Lock_Path) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Lock_Path;
      end if;
   end Ensure_Branch_Restore_Available;

   procedure Delete_Branch_Reflog
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
   is
      Path : constant String := Branch_Reflog_Path (Repo, Name);
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;

      Ensure_Branch_Reflog_Deletable (Repo, Name);
      Ada.Directories.Delete_File (Path);
   end Delete_Branch_Reflog;

   procedure Restore_Branch_Ref
     (Repo      : Version.Repository.Repository_Handle;
      Name      : String;
      Target_Id : Version.Objects.Hex_Object_Id)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/heads/" & Name,
         New_Id       => Target_Id,
         Expected_Old => To_String (Zero_Id));
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Restore_Branch_Ref;

   function Branch_Commit_Id
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Hex_Object_Id;

   procedure Create_Branch
      (Name      : String;
       Commit_Id : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Target : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Commit_Id);
      Target_Object : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Target);
   begin
      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & Name;
      end if;

      if Branch_Exists (Repo => Repo, Name => Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "branch already exists: " & Name;
      end if;

      if Version.Objects.Kind (Target_Object) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with
           "object is not a commit";
      end if;

      declare
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/" & Name,
            New_Id       => Target,
            Expected_Old => To_String (Zero_Id));
         Version.Ref_Transaction.Commit (Tx);
      exception
         when others =>
            Version.Ref_Transaction.Cancel (Tx);
            raise;
      end;

      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "refs/heads/" & Name,
         Old_Id  => To_String (Zero_Id),
         New_Id  => To_String (Target),
         Message => "branch create: " & Name);
   end Create_Branch;

   procedure Create_Branch (Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Create_Branch (Name, Version.Refs.Current_Commit_Id (Repo));
   end Create_Branch;

   procedure Rename_Branch
     (Old_Name : String;
      New_Name : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Old_Id : Version.Objects.Object_Id_Storage;
   begin
      if not Is_Valid_Branch_Name (Old_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & Old_Name;
      end if;

      if not Is_Valid_Branch_Name (New_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & New_Name;
      end if;

      if not Branch_Exists (Repo => Repo, Name => Old_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "branch does not exist: " & Old_Name;
      end if;

      if Branch_Exists (Repo => Repo, Name => New_Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "branch already exists: " & New_Name;
      end if;

      Old_Id := Branch_Commit_Id (Repo => Repo, Name => Old_Name);
      Ensure_Branch_Reflog_Deletable (Repo, Old_Name);

      declare
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Item         => Tx,
            Ref_Name     => "refs/heads/" & New_Name,
            New_Id       => Old_Id,
            Expected_Old => To_String (Zero_Id));
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/" & Old_Name,
            Expected_Old => To_String (Old_Id));
         Version.Ref_Transaction.Commit (Tx);
      exception
         when others =>
            Version.Ref_Transaction.Cancel (Tx);
            raise;
      end;

      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "refs/heads/" & New_Name,
         Old_Id  => To_String (Zero_Id),
         New_Id  => To_String (Old_Id),
         Message => "branch: renamed " & Old_Name & " to " & New_Name);

      Delete_Branch_Reflog (Repo, Old_Name);
   end Rename_Branch;

   procedure Rename_Current_Branch (New_Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Old_Name : constant String := Version.Refs.Current_Branch_Name (Repo);
      Old_Id   : constant Version.Objects.Hex_Object_Id :=
        Branch_Commit_Id (Repo => Repo, Name => Old_Name);
   begin
      Rename_Branch (Old_Name, New_Name);
      Write_HEAD (Repo, New_Name);
      Append_HEAD_Reflog
        (Repo    => Repo,
         Old_Id  => Old_Id,
         New_Id  => Old_Id,
         Message => "branch: renamed " & Old_Name & " to " & New_Name);
   end Rename_Current_Branch;

   procedure Delete_Branch
     (Name  : String;
      Force : Boolean := False)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
      Target_Id : Version.Objects.Object_Id_Storage;
      Current_Id : Version.Objects.Object_Id_Storage;
   begin
      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid branch name: " & Name;
      end if;

      if not Branch_Exists (Repo => Repo, Name => Name) then
         raise Ada.IO_Exceptions.Data_Error with
           "branch does not exist: " & Name;
      end if;

      if Version.Refs.Is_Attached (Head)
        and then Version.Refs.Branch_Name (Head) = Name
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot delete current branch: " & Name;
      end if;

      if Version.Worktrees.Branch_Checked_Out_Elsewhere (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Availability.Branch_In_Use_By_Worktree (Name);
      end if;

      Target_Id := Branch_Commit_Id (Repo => Repo, Name => Name);
      Ensure_Branch_Reflog_Deletable (Repo, Name);
      Ensure_Branch_Restore_Available (Repo, Name);

      if not Force then
         Current_Id := Version.Objects.To_Object_Id
           (Version.Refs.Current_Commit_Id (Repo));

         if not Version.History.Is_Ancestor
           (Repo       => Repo,
            Base_Id    => Target_Id,
            Derived_Id => Current_Id)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "branch is not fully merged: " & Name;
         end if;
      end if;

      declare
         Tx : Version.Ref_Transaction.Transaction;
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Delete
           (Item         => Tx,
            Ref_Name     => "refs/heads/" & Name,
            Expected_Old => To_String (Target_Id));
         Version.Ref_Transaction.Commit (Tx);
      exception
         when others =>
            Version.Ref_Transaction.Cancel (Tx);
            raise;
      end;

      begin
         Delete_Branch_Reflog (Repo, Name);
      exception
         when others =>
            Restore_Branch_Ref
              (Repo      => Repo,
               Name      => Name,
               Target_Id => Target_Id);
            raise;
      end;
   end Delete_Branch;

   procedure Switch_Branch (Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);

      Old_Id_Text : constant String := Version.Refs.Current_Commit_Id (Repo);

      Old_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Old_Id_Text);

      Old_Name : constant String :=
        (if Version.Refs.Is_Attached (Head)
         then Version.Refs.Branch_Name (Head)
         else Short_Id (Old_Id_Text));
   begin
      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name: " & Name;
      end if;

      if not Branch_Exists (Repo, Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "branch does not exist: " & Name;
      end if;

      if Version.Worktrees.Branch_Checked_Out_Elsewhere (Name) then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Availability.Branch_In_Use_By_Worktree (Name);
      end if;

      Require_No_Rebase_State ("cannot switch branch", Repo);
      Require_Clean_Status (Allow_Untracked => True);

      declare
         New_Id : constant Version.Objects.Hex_Object_Id :=
           Branch_Commit_Id (Repo => Repo, Name => Name);
         Object_Cache : Version.Object_Cache.Object_Cache;
         Tree_Cache   : Version.Tree_Cache.Tree_Cache;
         Target_Obj   : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object (Repo, Object_Cache, New_Id);
         Target_Tree  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Target_Obj);
         Entries      : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (Repo, Tree_Cache, Target_Tree);
      begin
         if not Entries.Is_Empty then
            for I in Entries.First_Index .. Entries.Last_Index loop
               declare
                  Tree_Item : constant Version.Objects.Tree_Entry := Entries.Element (I);
               begin
                  if Tree_Item.Kind = Version.Objects.Tree_Blob then
                     declare
                        Obj : constant Version.Objects.Git_Object :=
                          Version.Object_Cache.Read_Object
                            (Repo, Object_Cache, Tree_Item.Id);
                     begin
                        if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                           raise Ada.IO_Exceptions.Data_Error with
                             "branch target entry is not a blob: "
                             & Ada.Strings.Unbounded.To_String (Tree_Item.Path);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;

         Reject_Untracked_Overwrite (Entries);

         Preflight_HEAD_Metadata (Repo);
         Version.Restore.Preflight_Working_Tree_For_Commit
           (Repo      => Repo,
            Commit_Id => New_Id);

         declare
            Old_HEAD_Content : constant String :=
              Version.Files.Read_Binary_File (Head_Path (Repo));
            Worktree_Mutated : Boolean := False;
            Head_Moved       : Boolean := False;
         begin
            Version.Restore.Restore_Working_Tree_For_Commit
              (Repo      => Repo,
               Commit_Id => New_Id);
            Version.Restore.Write_Index_For_Commit
              (Repo      => Repo,
               Commit_Id => New_Id);
            Worktree_Mutated := True;

            Write_HEAD (Repo, Name);
            Head_Moved := True;

            Append_HEAD_Reflog
              (Repo    => Repo,
               Old_Id  => Old_Id,
               New_Id  => New_Id,
               Message => "branch switch: moving from " & Old_Name & " to " & Name);

            Version.Hooks.Run_Post_Checkout
              (Repo   => Repo,
               Old_Id => To_String (Old_Id),
               New_Id => To_String (New_Id),
               Flag   => "1");
         exception
            when others =>
               if Head_Moved then
                  begin
                     Restore_HEAD_File (Repo, Old_HEAD_Content);
                  exception
                     when others =>
                        null;
                  end;
               end if;

               if Worktree_Mutated then
                  begin
                     Version.Restore.Restore_Working_Tree_For_Commit
                       (Repo      => Repo,
                        Commit_Id => Old_Id);
                     Version.Restore.Write_Index_For_Commit
                       (Repo      => Repo,
                        Commit_Id => Old_Id);
                  exception
                     when others =>
                        null;
                  end;
               end if;

               raise;
         end;
      end;
   end Switch_Branch;

   function Branch_Commit_Id
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Hex_Object_Id
   is
   begin
      if not Branch_Exists (Repo, Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "branch does not exist: " & Name;
      end if;

      return Version.Refs.Resolve_Ref
        (Repo => Repo,
         Name => "refs/heads/" & Name);
   end Branch_Commit_Id;

   procedure Write_Current_Branch_Commit
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
   is
      Head_Ref : constant String := Version.Refs.Current_Branch_Name (Repo);
      Old_Id   : constant Version.Objects.Hex_Object_Id :=
        Branch_Commit_Id (Repo => Repo, Name => Head_Ref);
      Tx       : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => "refs/heads/" & Head_Ref,
         New_Id       => Commit,
         Expected_Old => To_String (Old_Id));
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Current_Branch_Commit;

   procedure Update_Current_Branch (Target_Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Require_Attached_HEAD ("cannot update branch", Repo);
      Require_Clean_Status;

      declare
         Current_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));

         Target_Id : constant Version.Objects.Hex_Object_Id :=
           Branch_Commit_Id (Repo => Repo, Name => Target_Name);
      begin
         if not Version.History.Is_Ancestor
                  (Repo => Repo, Base_Id => Current_Id, Derived_Id => Target_Id)
         then
            raise Ada.IO_Exceptions.Data_Error
              with "cannot update branch: histories diverged";
         end if;

         Write_Current_Branch_Commit (Repo => Repo, Commit => Target_Id);

         Append_HEAD_And_Current_Branch_Reflog
           (Repo    => Repo,
            Old_Id  => Current_Id,
            New_Id  => Target_Id,
            Message => "branch update: fast-forward to " & Target_Name);

         Version.Restore.Restore_Working_Tree (Repo);

         Version.Restore.Write_Index_For_Commit
           (Repo      => Repo,
            Commit_Id => Target_Id);
      end;
   end Update_Current_Branch;

   function Find_Tree_Item
     (Items : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
      return Natural is
   begin
      if Items.Is_Empty then
         return Natural'Last;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Ada.Strings.Unbounded.To_String (Items.Element (I).Path) = Path
         then
            return I;
         end if;
      end loop;

      return Natural'Last;
   end Find_Tree_Item;

   function Ends_With (Text, Suffix : String) return Boolean is
   begin
      return Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Ends_With;

   function Normalize_Subtree_Prefix (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      if Text'Length = 0 then
         return "";
      end if;

      while First <= Last and then Text (First) = '/' loop
         First := First + 1;
      end loop;

      while Last >= First and then Text (Last) = '/' loop
         Last := Last - 1;
      end loop;

      if First > Last then
         return "";
      end if;

      declare
         Result : constant String := Text (First .. Last);
      begin
         if not Version.Merge.Is_Safe_Relative_Path (Result) then
            raise Ada.IO_Exceptions.Data_Error with
              "unsafe subtree prefix: " & Text;
         end if;

         return Result;
      end;
   end Normalize_Subtree_Prefix;

   function Prefix_Subtree_Path (Prefix, Path : String) return String is
   begin
      if Prefix'Length = 0 then
         return Path;
      elsif Path'Length = 0 then
         return Prefix;
      elsif Path = Prefix
        or else (Path'Length > Prefix'Length
                 and then Path (Path'First .. Path'First + Prefix'Length - 1) = Prefix
                 and then Path (Path'First + Prefix'Length) = '/')
      then
         return Path;
      else
         return Prefix & "/" & Path;
      end if;
   end Prefix_Subtree_Path;

   function Rewrite_Subtree_Items
     (Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Prefix : String) return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Result : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      if Prefix'Length = 0 or else Items.Is_Empty then
         return Items;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item : Version.Objects.Tree_Entry := Items.Element (I);
            Path : constant String := Ada.Strings.Unbounded.To_String (Item.Path);
            Rewritten : constant String := Prefix_Subtree_Path (Prefix, Path);
         begin
            if not Version.Merge.Is_Safe_Relative_Path (Rewritten) then
               raise Ada.IO_Exceptions.Data_Error with
                 "unsafe subtree merge path: " & Rewritten;
            end if;

            Item.Path := Ada.Strings.Unbounded.To_Unbounded_String (Rewritten);
            Result.Append (Item);
         end;
      end loop;

      return Result;
   end Rewrite_Subtree_Items;

   function Infer_Subtree_Prefix
     (Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector) return String
   is
      Candidate : Ada.Strings.Unbounded.Unbounded_String;
      Found     : Boolean := False;
      Ambiguous : Boolean := False;
   begin
      if Current_Items.Is_Empty or else Target_Items.Is_Empty then
         return "";
      end if;

      for T in Target_Items.First_Index .. Target_Items.Last_Index loop
         declare
            Target_Path : constant String :=
              Ada.Strings.Unbounded.To_String (Target_Items.Element (T).Path);
            Needle : constant String := "/" & Target_Path;
         begin
            for C in Current_Items.First_Index .. Current_Items.Last_Index loop
               declare
                  Current_Path : constant String :=
                    Ada.Strings.Unbounded.To_String (Current_Items.Element (C).Path);
               begin
                  if Ends_With (Current_Path, Needle) then
                     declare
                        Prefix : constant String :=
                          Normalize_Subtree_Prefix
                            (Current_Path
                               (Current_Path'First
                                .. Current_Path'Last - Needle'Length));
                     begin
                        if Prefix'Length > 0 then
                           if not Found then
                              Candidate :=
                                Ada.Strings.Unbounded.To_Unbounded_String (Prefix);
                              Found := True;
                           elsif Ada.Strings.Unbounded.To_String (Candidate) /= Prefix then
                              Ambiguous := True;
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
      end loop;

      if Found and then not Ambiguous then
         return Ada.Strings.Unbounded.To_String (Candidate);
      else
         return "";
      end if;
   end Infer_Subtree_Prefix;

   function Effective_Subtree_Prefix
     (Options       : Merge_Options;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector) return String
   is
      Explicit : constant String :=
        Normalize_Subtree_Prefix
          (Ada.Strings.Unbounded.To_String (Options.Subtree_Prefix));
   begin
      if not Options.Subtree then
         return "";
      elsif Explicit'Length > 0 then
         return Explicit;
      end if;

      declare
         Inferred : constant String :=
           Infer_Subtree_Prefix
             (Current_Items => Current_Items,
              Target_Items  => Target_Items);
      begin
         if Inferred'Length = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot infer subtree merge prefix";
         end if;

         return Inferred;
      end;
   end Effective_Subtree_Prefix;

   function Tree_Id_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Commit_Object : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
   begin
      return Version.Objects.Commit_Tree_Id (Commit_Object);
   end Tree_Id_For_Commit;

   function Tree_Id_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Commit_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
   begin
      return Version.Objects.Commit_Tree_Id (Commit_Object);
   end Tree_Id_For_Commit;

   procedure Integrate_Branch (Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Require_Attached_HEAD ("cannot integrate branch", Repo);

      if not Is_Valid_Branch_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name: " & Name;
      end if;

      Require_Clean_Status (Allow_Untracked => True);

      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot integrate branch: merge state already exists";
      end if;

      declare
         Current_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));

         Target_Id : constant Version.Objects.Hex_Object_Id :=
           Branch_Commit_Id (Repo => Repo, Name => Name);
      begin
         if Version.History.Is_Ancestor
              (Repo => Repo, Base_Id => Target_Id, Derived_Id => Current_Id)
         then
            return;
         end if;

         if Version.History.Is_Ancestor
              (Repo => Repo, Base_Id => Current_Id, Derived_Id => Target_Id)
         then
            Update_Current_Branch (Name);
            return;
         end if;

         declare
            Objects : Version.Object_Cache.Object_Cache;
            Trees   : Version.Tree_Cache.Tree_Cache;

            Base_Id : constant Version.Objects.Hex_Object_Id :=
              Version.History.Merge_Base
                (Repo => Repo, Left => Current_Id, Right => Target_Id);

            Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Current_Id);

            Target_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Target_Id);

            Base_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Base_Id);

            Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo    => Repo,
                 Cache   => Trees,
                 Tree_Id => Base_Tree_Id);

            Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo    => Repo,
                 Cache   => Trees,
                 Tree_Id => Current_Tree_Id);

            Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo    => Repo,
                 Cache   => Trees,
                 Tree_Id => Target_Tree_Id);

            Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
            Conflicts    : Version.Merge.Conflict_Vectors.Vector;
         begin
            Reject_Untracked_Overwrite (Target_Items);

            Version.Merge.Merge_Trees
              (Repo          => Repo,
               Current_Name  => Version.Refs.Current_Branch_Name (Repo),
               Target_Name   => Name,
               Base_Items    => Base_Items,
               Current_Items => Current_Items,
               Target_Items  => Target_Items,
               Merged_Index  => Merged_Index,
               Conflicts     => Conflicts);

            if not Conflicts.Is_Empty then
               Version.Merge_State.Write_State
                 (Repo          => Repo,
                  Current_Id    => Current_Id,
                  Target_Id     => Target_Id,
                  Base_Id       => Base_Id,
                  Target_Branch => Name,
                  Conflicts     => Conflicts);
               Version.Staging.Write (Repo => Repo, Entries => Merged_Index);

               raise Ada.IO_Exceptions.Data_Error with
                 "cannot integrate branch: conflicts recorded";
            end if;

            declare
               Tree_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Tree_From_Index
                   (Repo => Repo, Entries => Merged_Index);

               Parents : Version.Objects.Object_Id_Vectors.Vector;
            begin
               Parents.Append (Current_Id);
               Parents.Append (Target_Id);

               declare
                  Commit_Id : constant Version.Objects.Hex_Object_Id :=
                    Version.Write.Write_Commit_With_Parents
                      (Repo    => Repo,
                       Tree_Id => Tree_Id,
                       Parents => Parents,
                       Message => "Integrate branch " & Name);
               begin
                  Write_Current_Branch_Commit (Repo => Repo, Commit => Commit_Id);

                  Append_HEAD_And_Current_Branch_Reflog
                    (Repo    => Repo,
                     Old_Id  => Current_Id,
                     New_Id  => Commit_Id,
                     Message => "branch integrate: merge " & Name);
               end;
            end;

            Version.Restore.Restore_Working_Tree (Repo);
            Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
         end;
      end;
   end Integrate_Branch;

   function Empty_Tree_Items return Version.Objects.Tree_Entry_Vectors.Vector is
      Empty : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      return Empty;
   end Empty_Tree_Items;

   function Merge_Favor
     (Options : Merge_Options) return Version.Merge.Conflict_Favor is
   begin
      case Options.Conflict_Favor is
         when Favor_Neither =>
            return Version.Merge.Favor_Neither;
         when Favor_Current =>
            return Version.Merge.Favor_Current;
         when Favor_Target =>
            return Version.Merge.Favor_Target;
      end case;
   end Merge_Favor;

   function Config_Text
     (Repo : Version.Repository.Repository_Handle; Name : String) return String is
   begin
      return Version.Config.Get_Value (Repo, Name);
   exception
      when others =>
         return "";
   end Config_Text;

   function Normalized_Config_Text (Text : String) return String is
      Result : String := Version.Config.Trim (Text);
   begin
      for I in Result'Range loop
         Result (I) := Ada.Characters.Handling.To_Lower (Result (I));
      end loop;

      return Result;
   end Normalized_Config_Text;

   function Positive_Config
     (Repo : Version.Repository.Repository_Handle; Name : String; Default : Positive)
      return Positive
   is
      Text : constant String := Version.Config.Trim (Config_Text (Repo, Name));
   begin
      if Text'Length = 0 then
         return Default;
      end if;

      declare
         Value : constant Integer := Integer'Value (Text);
      begin
         if Value < 1 or else Value > 64 then
            return Default;
         else
            return Positive (Value);
         end if;
      end;
   exception
      when others =>
         return Default;
   end Positive_Config;

   function Config_True (Text : String) return Boolean is
      Value : constant String := Normalized_Config_Text (Text);
   begin
      return Value = "true" or else Value = "1"
        or else Value = "yes" or else Value = "on";
   end Config_True;

   function Config_False (Text : String) return Boolean is
      Value : constant String := Normalized_Config_Text (Text);
   begin
      return Value = "false" or else Value = "0"
        or else Value = "no" or else Value = "off";
   end Config_False;

   function Natural_Config_Text
     (Text : String; Default : Natural) return Natural
   is
      Value_Text : constant String := Version.Config.Trim (Text);
   begin
      if Value_Text'Length = 0 then
         return Default;
      end if;

      return Natural'Value (Value_Text);
   exception
      when others =>
         return Default;
   end Natural_Config_Text;

   function Has_Prefix (Text, Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Has_Prefix;

   function After_Prefix (Text, Prefix : String) return String is
   begin
      return Text (Text'First + Prefix'Length .. Text'Last);
   end After_Prefix;

   function Parse_Merge_Threshold
     (Text : String; OK : out Boolean) return Natural
   is
      Last  : Natural := Text'Last;
      Value : Natural := 0;
   begin
      OK := False;
      if Text'Length = 0 then
         return 0;
      end if;

      if Text (Last) = '%' then
         if Text'Length = 1 then
            return 0;
         end if;
         Last := Last - 1;
      end if;

      for I in Text'First .. Last loop
         if Text (I) < '0' or else Text (I) > '9' then
            return 0;
         end if;

         Value := Value * 10
           + Character'Pos (Text (I)) - Character'Pos ('0');
      end loop;

      if Value > 100 then
         return 0;
      end if;

      OK := True;
      return Value;
   end Parse_Merge_Threshold;

   function Parse_Merge_Natural
     (Text : String; OK : out Boolean) return Natural
   is
      Value : Natural := 0;
   begin
      OK := False;
      if Text'Length = 0 then
         return 0;
      end if;

      for I in Text'Range loop
         if Text (I) < '0' or else Text (I) > '9' then
            return 0;
         end if;

         Value := Value * 10
           + Character'Pos (Text (I)) - Character'Pos ('0');
      end loop;

      OK := True;
      return Value;
   end Parse_Merge_Natural;

   function Recurse_Submodules_Config_True (Text : String) return Boolean is
      Value : constant String := Normalized_Config_Text (Text);
   begin
      return Config_True (Text)
        or else Value = "on-demand"
        or else Value = "check";
   end Recurse_Submodules_Config_True;

   procedure Apply_Configured_Strategy
     (Name : String; Result : in out Merge_Options)
   is
   begin
      if Result.Strategy_Explicit or else Result.Strategy /= Strategy_Default then
         return;
      elsif Name = "ours" then
         Result.Strategy := Strategy_Ours;
         Result.Strategy_Ours := True;
      elsif Name = "ort" then
         Result.Strategy := Strategy_Ort;
      elsif Name = "recursive" then
         Result.Strategy := Strategy_Recursive;
      elsif Name = "resolve" then
         Result.Strategy := Strategy_Resolve;
      elsif Name = "octopus" then
         Result.Strategy := Strategy_Octopus;
      elsif Name = "subtree" then
         Result.Strategy := Strategy_Subtree;
         Result.Subtree := True;
      end if;
   end Apply_Configured_Strategy;

   procedure Apply_Configured_Strategy_Option
     (Name : String; Result : in out Merge_Options)
   is
      Value : constant String := Normalized_Config_Text (Name);
   begin
      if Name = "ours" then
         if not Result.Conflict_Favor_Explicit
           and then Result.Conflict_Favor = Favor_Neither
         then
            Result.Conflict_Favor := Favor_Current;
         end if;
      elsif Name = "theirs" then
         if not Result.Conflict_Favor_Explicit
           and then Result.Conflict_Favor = Favor_Neither
         then
            Result.Conflict_Favor := Favor_Target;
         end if;
      elsif Name = "ignore-space-change" then
         if Result.Whitespace = Whitespace_Strict then
            Result.Whitespace := Whitespace_Ignore_Space_Change;
         end if;
      elsif Name = "ignore-all-space" then
         if Result.Whitespace = Whitespace_Strict then
            Result.Whitespace := Whitespace_Ignore_All_Space;
         end if;
      elsif Name = "ignore-space-at-eol" then
         if Result.Whitespace = Whitespace_Strict then
            Result.Whitespace := Whitespace_Ignore_Space_At_EOL;
         end if;
      elsif Name = "ignore-cr-at-eol" then
         if Result.Whitespace = Whitespace_Strict then
            Result.Whitespace := Whitespace_Ignore_CR_At_EOL;
         end if;
      elsif Name = "renormalize" then
         if not Result.Renormalize_Explicit then
            Result.Renormalize := True;
         end if;
      elsif Name = "no-renormalize" then
         if not Result.Renormalize_Explicit then
            Result.Renormalize := False;
         end if;
      elsif Name = "find-renames" or else Name = "renames" then
         if not Result.Detect_Renames_Explicit then
            Result.Detect_Renames := True;
         end if;
      elsif Has_Prefix (Name, "find-renames=") then
         if not Result.Detect_Renames_Explicit then
            declare
               OK : Boolean := False;
               Threshold : constant Natural :=
                 Parse_Merge_Threshold (After_Prefix (Name, "find-renames="), OK);
            begin
               if OK then
                  Result.Detect_Renames := True;
                  Result.Rename_Threshold := Threshold;
               end if;
            end;
         end if;
      elsif Has_Prefix (Name, "renames=") then
         if not Result.Detect_Renames_Explicit then
            declare
               OK : Boolean := False;
               Threshold : constant Natural :=
                 Parse_Merge_Threshold (After_Prefix (Name, "renames="), OK);
            begin
               if OK then
                  Result.Detect_Renames := True;
                  Result.Rename_Threshold := Threshold;
               end if;
            end;
         end if;
      elsif Name = "find-copies" or else Name = "copies"
        or else Name = "find-copies-harder"
      then
         if not Result.Detect_Copies_Explicit then
            Result.Detect_Copies := True;
         end if;
      elsif Has_Prefix (Name, "find-copies=") then
         if not Result.Detect_Copies_Explicit then
            declare
               OK : Boolean := False;
               Threshold : constant Natural :=
                 Parse_Merge_Threshold (After_Prefix (Name, "find-copies="), OK);
            begin
               if OK then
                  Result.Detect_Copies := True;
                  Result.Rename_Threshold := Threshold;
               end if;
            end;
         end if;
      elsif Has_Prefix (Name, "copies=") then
         if not Result.Detect_Copies_Explicit then
            declare
               OK : Boolean := False;
               Threshold : constant Natural :=
                 Parse_Merge_Threshold (After_Prefix (Name, "copies="), OK);
            begin
               if OK then
                  Result.Detect_Copies := True;
                  Result.Rename_Threshold := Threshold;
               end if;
            end;
         end if;
      elsif Name = "no-copies" then
         if not Result.Detect_Copies_Explicit then
            Result.Detect_Copies := False;
         end if;
      elsif Name = "no-renames" then
         if not Result.Detect_Renames_Explicit then
            Result.Detect_Renames := False;
         end if;
      elsif Name = "directory-renames" then
         if Result.Directory_Renames = Directory_Renames_Default then
            Result.Directory_Renames := Directory_Renames_Apply;
         end if;
      elsif Name = "no-directory-renames" then
         if Result.Directory_Renames = Directory_Renames_Default then
            Result.Directory_Renames := Directory_Renames_Disabled;
         end if;
      elsif Has_Prefix (Name, "directory-renames=") then
         if Result.Directory_Renames = Directory_Renames_Default then
            declare
               Mode : constant String :=
                 Normalized_Config_Text (After_Prefix (Name, "directory-renames="));
            begin
               if Config_True (Mode) then
                  Result.Directory_Renames := Directory_Renames_Apply;
               elsif Config_False (Mode) then
                  Result.Directory_Renames := Directory_Renames_Disabled;
               elsif Mode = "conflict" then
                  Result.Directory_Renames := Directory_Renames_Conflict;
               end if;
            end;
         end if;
      elsif Name = "recurse-submodules" then
         if not Result.Recurse_Submodules_Explicit then
            Result.Recurse_Submodules := True;
         end if;
      elsif Name = "no-recurse-submodules" then
         if not Result.Recurse_Submodules_Explicit then
            Result.Recurse_Submodules := False;
         end if;
      elsif Has_Prefix (Name, "recurse-submodules=") then
         if not Result.Recurse_Submodules_Explicit then
            declare
               Mode : constant String :=
                 After_Prefix (Name, "recurse-submodules=");
            begin
               if Config_False (Mode) then
                  Result.Recurse_Submodules := False;
               elsif Recurse_Submodules_Config_True (Mode) then
                  Result.Recurse_Submodules := True;
               end if;
            end;
         end if;
      elsif Name = "patience" then
         if Result.Algorithm = Diff_Algorithm_Default then
            Result.Algorithm := Diff_Algorithm_Patience;
         end if;
      elsif Name = "histogram" then
         if Result.Algorithm = Diff_Algorithm_Default then
            Result.Algorithm := Diff_Algorithm_Histogram;
         end if;
      elsif Name = "minimal" then
         if Result.Algorithm = Diff_Algorithm_Default then
            Result.Algorithm := Diff_Algorithm_Minimal;
         end if;
      elsif Name = "myers" then
         if Result.Algorithm = Diff_Algorithm_Default then
            Result.Algorithm := Diff_Algorithm_Myers;
         end if;
      elsif Has_Prefix (Name, "diff-algorithm=") then
         if Result.Algorithm = Diff_Algorithm_Default then
            declare
               Algorithm : constant String :=
                 After_Prefix (Name, "diff-algorithm=");
            begin
               if Algorithm = "patience" then
                  Result.Algorithm := Diff_Algorithm_Patience;
               elsif Algorithm = "histogram" then
                  Result.Algorithm := Diff_Algorithm_Histogram;
               elsif Algorithm = "minimal" then
                  Result.Algorithm := Diff_Algorithm_Minimal;
               elsif Algorithm = "myers" then
                  Result.Algorithm := Diff_Algorithm_Myers;
               end if;
            end;
         end if;
      elsif Has_Prefix (Name, "rename-limit=") then
         if not Result.Rename_Limit_Explicit then
            declare
               OK : Boolean := False;
               Limit : constant Natural :=
                 Parse_Merge_Natural (After_Prefix (Name, "rename-limit="), OK);
            begin
               if OK then
                  Result.Rename_Limit := Limit;
               end if;
            end;
         end if;
      elsif Name = "subtree" then
         Result.Subtree := True;
      elsif Has_Prefix (Name, "subtree=") then
         declare
            Prefix : constant String := After_Prefix (Name, "subtree=");
         begin
            if Prefix'Length > 0 then
               Result.Subtree := True;
               Result.Subtree_Prefix :=
                 Ada.Strings.Unbounded.To_Unbounded_String (Prefix);
            end if;
         end;
      elsif Value = "break-rewrites" or else Value = "no-break-rewrites"
        or else Has_Prefix (Value, "break-rewrites=")
      then
         null;
      end if;
   end Apply_Configured_Strategy_Option;

   procedure Apply_Configured_Merge_Option
     (Token : String; Result : in out Merge_Options)
   is
   begin
      if Token = "--ff" then
         if not Result.Fast_Forward_Explicit then
            Result.Fast_Forward := Fast_Forward_Allowed;
         end if;
      elsif Token = "--ff-only" then
         if not Result.Fast_Forward_Explicit then
            Result.Fast_Forward := Fast_Forward_Only;
         end if;
      elsif Token = "--no-ff" then
         if not Result.Fast_Forward_Explicit then
            Result.Fast_Forward := Fast_Forward_Disabled;
         end if;
      elsif Token = "--squash" then
         if not Result.Squash_Explicit and then not Result.Squash then
            Result.Squash := True;
         end if;
      elsif Token = "--no-commit" then
         if not Result.No_Commit_Explicit and then not Result.No_Commit then
            Result.No_Commit := True;
         end if;
      elsif Token = "--commit" then
         if not Result.No_Commit_Explicit then
            Result.No_Commit := False;
         end if;
      elsif Token = "--signoff" then
         if not Result.Signoff_Explicit and then not Result.Signoff then
            Result.Signoff := True;
         end if;
      elsif Token = "--no-signoff" then
         if not Result.Signoff_Explicit then
            Result.Signoff := False;
         end if;
      elsif Token = "--log" then
         if not Result.Log_Explicit then
            Result.Log_Limit := 20;
         end if;
      elsif Token = "--no-log" then
         if not Result.Log_Explicit then
            Result.Log_Limit := 0;
         end if;
      elsif Has_Prefix (Token, "--log=") then
         if not Result.Log_Explicit then
            Result.Log_Limit :=
              Natural_Config_Text (After_Prefix (Token, "--log="), Result.Log_Limit);
         end if;
      elsif Token = "--stat" or else Token = "--summary"
        or else Token = "--compact-summary"
      then
         if not Result.Stat_Explicit then
            Result.Stat := True;
            Result.Compact_Summary := Token = "--compact-summary";
         end if;
      elsif Token = "--no-stat" or else Token = "--no-summary" then
         if not Result.Stat_Explicit then
            Result.Stat := False;
         end if;
      elsif Token = "--renormalize" then
         Apply_Configured_Strategy_Option ("renormalize", Result);
      elsif Token = "--no-renormalize" then
         Apply_Configured_Strategy_Option ("no-renormalize", Result);
      elsif Token = "--find-renames" then
         Apply_Configured_Strategy_Option ("find-renames", Result);
      elsif Has_Prefix (Token, "--find-renames=") then
         Apply_Configured_Strategy_Option
           ("find-renames=" & After_Prefix (Token, "--find-renames="), Result);
      elsif Token = "--find-copies" then
         Apply_Configured_Strategy_Option ("find-copies", Result);
      elsif Token = "--find-copies-harder" then
         Apply_Configured_Strategy_Option ("find-copies-harder", Result);
      elsif Has_Prefix (Token, "--find-copies=") then
         Apply_Configured_Strategy_Option
           ("find-copies=" & After_Prefix (Token, "--find-copies="), Result);
      elsif Token = "--no-copies" then
         Apply_Configured_Strategy_Option ("no-copies", Result);
      elsif Token = "--no-renames" then
         Apply_Configured_Strategy_Option ("no-renames", Result);
      elsif Token = "--recurse-submodules" then
         Apply_Configured_Strategy_Option ("recurse-submodules", Result);
      elsif Token = "--no-recurse-submodules" then
         Apply_Configured_Strategy_Option ("no-recurse-submodules", Result);
      elsif Has_Prefix (Token, "--recurse-submodules=") then
         Apply_Configured_Strategy_Option
           ("recurse-submodules=" & After_Prefix (Token, "--recurse-submodules="),
            Result);
      end if;
   end Apply_Configured_Merge_Option;

   procedure Apply_Branch_Merge_Options_Config
     (Repo : Version.Repository.Repository_Handle; Result : in out Merge_Options)
   is
      Branch_Name : Ada.Strings.Unbounded.Unbounded_String;
   begin
      begin
         Branch_Name :=
           Ada.Strings.Unbounded.To_Unbounded_String
             (Version.Refs.Current_Branch_Name (Repo));
      exception
         when others =>
            Branch_Name := Ada.Strings.Unbounded.Null_Unbounded_String;
      end;

      if Ada.Strings.Unbounded.Length (Branch_Name) = 0 then
         return;
      end if;

      declare
         Text : constant String :=
           Config_Text
             (Repo,
              "branch."
              & Ada.Strings.Unbounded.To_String (Branch_Name)
              & ".mergeOptions");
         Pos  : Natural := Text'First;
         Pending_Strategy : Boolean := False;
         Pending_Strategy_Option : Boolean := False;
      begin
         while Pos <= Text'Last loop
            while Pos <= Text'Last
              and then (Text (Pos) = ' ' or else Text (Pos) = Character'Val (9))
            loop
               Pos := Pos + 1;
            end loop;

            exit when Pos > Text'Last;

            declare
               First : constant Natural := Pos;
            begin
               while Pos <= Text'Last
                 and then Text (Pos) /= ' '
                 and then Text (Pos) /= Character'Val (9)
               loop
                  Pos := Pos + 1;
               end loop;

               declare
                  Token : constant String := Text (First .. Pos - 1);
               begin
                  if Pending_Strategy then
                     Apply_Configured_Strategy (Token, Result);
                     Pending_Strategy := False;
                  elsif Pending_Strategy_Option then
                     Apply_Configured_Strategy_Option (Token, Result);
                     Pending_Strategy_Option := False;
                  elsif Token = "-s" or else Token = "--strategy" then
                     Pending_Strategy := True;
                  elsif Token = "-X" or else Token = "--strategy-option" then
                     Pending_Strategy_Option := True;
                  elsif Has_Prefix (Token, "-s") and then Token'Length > 2 then
                     Apply_Configured_Strategy
                       (Token (Token'First + 2 .. Token'Last), Result);
                  elsif Has_Prefix (Token, "-X") and then Token'Length > 2 then
                     Apply_Configured_Strategy_Option
                       (Token (Token'First + 2 .. Token'Last), Result);
                  elsif Has_Prefix (Token, "--strategy=") then
                     Apply_Configured_Strategy
                       (After_Prefix (Token, "--strategy="), Result);
                  elsif Has_Prefix (Token, "--strategy-option=") then
                     Apply_Configured_Strategy_Option
                       (After_Prefix (Token, "--strategy-option="), Result);
                  else
                     Apply_Configured_Merge_Option (Token, Result);
                  end if;
               end;
            end;
         end loop;
      end;
   end Apply_Branch_Merge_Options_Config;

   function Merge_Configured_Options
     (Repo : Version.Repository.Repository_Handle; Options : Merge_Options)
      return Merge_Options
   is
      Result : Merge_Options := Options;
      FF_Config : constant String := Config_Text (Repo, "merge.ff");
      FF_Value  : constant String := Normalized_Config_Text (FF_Config);
      Autostash_Config : constant String := Config_Text (Repo, "merge.autostash");
      Stat_Config : constant String := Config_Text (Repo, "merge.stat");
      Summary_Config : constant String := Config_Text (Repo, "merge.summary");
      Log_Config : constant String := Config_Text (Repo, "merge.log");
      Auto_Edit_Config : constant String := Config_Text (Repo, "merge.autoEdit");
      Verify_Config : constant String := Config_Text (Repo, "merge.verifySignatures");
      Commit_GPG_Config : constant String := Config_Text (Repo, "commit.gpgSign");
      Signing_Key_Config : constant String := Config_Text (Repo, "user.signingKey");
      Recurse_Config : constant String := Config_Text (Repo, "submodule.recurse");
      Merge_Recurse_Config : constant String := Config_Text (Repo, "merge.recurseSubmodules");
   begin
      if not Options.Fast_Forward_Explicit then
         if Config_False (FF_Config) then
            Result.Fast_Forward := Fast_Forward_Disabled;
         elsif FF_Value = "only" then
            Result.Fast_Forward := Fast_Forward_Only;
         elsif Config_True (FF_Config) then
            Result.Fast_Forward := Fast_Forward_Allowed;
         end if;
      end if;

      if not Options.Autostash_Explicit then
         if Config_True (Autostash_Config) then
            Result.Autostash := True;
         elsif Config_False (Autostash_Config) then
            Result.Autostash := False;
         end if;
      end if;

      if not Options.Stat_Explicit then
         if Config_True (Stat_Config) or else Config_True (Summary_Config) then
            Result.Stat := True;
         elsif Config_False (Stat_Config) or else Config_False (Summary_Config) then
            Result.Stat := False;
         end if;
      end if;

      if not Options.Log_Explicit then
         if Config_True (Log_Config) then
            Result.Log_Limit := 20;
         elsif Config_False (Log_Config) then
            Result.Log_Limit := 0;
         else
            Result.Log_Limit := Natural_Config_Text (Log_Config, Result.Log_Limit);
         end if;
      end if;

      if not Options.Edit_Explicit then
         if Config_True (Auto_Edit_Config) then
            Result.Edit_Message := True;
         elsif Config_False (Auto_Edit_Config) then
            Result.Edit_Message := False;
         end if;
      end if;

      if not Options.Verify_Signatures_Explicit then
         if Config_True (Verify_Config) then
            Result.Verify_Signatures := True;
         elsif Config_False (Verify_Config) then
            Result.Verify_Signatures := False;
         end if;
      end if;

      if not Options.GPG_Sign_Explicit and then Config_True (Commit_GPG_Config) then
         if Version.Config.Trim (Signing_Key_Config)'Length > 0 then
            Result.GPG_Sign := Ada.Strings.Unbounded.To_Unbounded_String (Version.Config.Trim (Signing_Key_Config));
         else
            Result.GPG_Sign := Ada.Strings.Unbounded.To_Unbounded_String ("default");
         end if;
      end if;

      if not Options.Recurse_Submodules_Explicit then
         if Config_False (Merge_Recurse_Config)
           or else Config_False (Recurse_Config)
         then
            Result.Recurse_Submodules := False;
         elsif Recurse_Submodules_Config_True (Merge_Recurse_Config)
           or else Recurse_Submodules_Config_True (Recurse_Config)
         then
            Result.Recurse_Submodules := True;
         end if;
      end if;

      Apply_Branch_Merge_Options_Config (Repo, Result);

      if not Result.Enable_Rerere
        and then Config_True (Config_Text (Repo, "rerere.autoupdate"))
      then
         Result.Enable_Rerere := True;
      end if;

      return Result;
   end Merge_Configured_Options;

   function Supported_Cleanup_Mode (Mode : String) return Boolean is
      Value : constant String := Normalized_Config_Text (Mode);
   begin
      return Value'Length = 0
        or else Value = "default"
        or else Value = "strip"
        or else Value = "whitespace"
        or else Value = "verbatim"
        or else Value = "scissors";
   end Supported_Cleanup_Mode;

   function Cleanup_Message (Message : String; Mode : String) return String is
      Value : constant String := Normalized_Config_Text (Mode);
   begin
      if Value = "verbatim" then
         return Message;
      elsif Supported_Cleanup_Mode (Mode) then
         return Version.Config.Trim (Message);
      else
         raise Ada.IO_Exceptions.Data_Error with
           "unsupported merge cleanup mode: " & Mode;
      end if;
   end Cleanup_Message;

   function Commit_Subject
     (Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
   begin
      return Version.Objects.Commit_Message_First_Line (Obj);
   end Commit_Subject;

   function Merge_Log_Text
     (Repo : Version.Repository.Repository_Handle;
      Target_Id : Version.Objects.Hex_Object_Id;
      Limit : Natural) return String
   is
      pragma Unreferenced (Limit);
      Subject : constant String := Commit_Subject (Repo, Target_Id);
   begin
      if Subject'Length = 0 then
         return "";
      else
         return Character'Val (10) & Character'Val (10)
           & "* " & Short_Id (To_String (Target_Id)) & " " & Subject;
      end if;
   end Merge_Log_Text;

   function Signoff_Text
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Identity : constant Version.Config.Identity := Version.Config.User_Identity (Repo);
      Name    : constant String := Ada.Strings.Unbounded.To_String (Identity.Name);
      Email   : constant String := Ada.Strings.Unbounded.To_String (Identity.Email);
   begin
      if Name'Length = 0 or else Email'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot sign off merge: user identity is not configured";
      end if;

      return "Signed-off-by: " & Name & " <" & Email & ">";
   end Signoff_Text;

   function Finalize_Merge_Message
     (Repo : Version.Repository.Repository_Handle;
      Base_Message : String;
      Target_Id : Version.Objects.Hex_Object_Id;
      Options : Merge_Options) return String
   is
      Result : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Cleanup_Message
             (Base_Message,
              Ada.Strings.Unbounded.To_String (Options.Cleanup_Mode)));
   begin
      if Options.Log_Limit > 0 then
         Ada.Strings.Unbounded.Append
           (Result, Merge_Log_Text (Repo, Target_Id, Options.Log_Limit));
      end if;

      if Options.Signoff then
         Ada.Strings.Unbounded.Append
           (Result, Character'Val (10) & Character'Val (10) & Signoff_Text (Repo));
      end if;

      declare
         Text : constant String := Ada.Strings.Unbounded.To_String (Result);
      begin
         if Options.Edit_Message then
            return Edit_Merge_Message (Repo => Repo, Message => Text);
         else
            return Text;
         end if;
      end;
   end Finalize_Merge_Message;

   function Merge_Behavior_For
     (Repo : Version.Repository.Repository_Handle; Options : Merge_Options)
      return Version.Merge.Merge_Behavior
   is
      Result : Version.Merge.Merge_Behavior;
      Style  : constant String :=
        Normalized_Config_Text (Config_Text (Repo, "merge.conflictstyle"));
      Rename_Config : constant String := Config_Text (Repo, "merge.renames");
      Renormalize_Config : constant String :=
        Config_Text (Repo, "merge.renormalize");
      Rename_Limit_Config : constant String :=
        Config_Text (Repo, "merge.renameLimit");
      Directory_Renames_Config : constant String :=
        Normalized_Config_Text (Config_Text (Repo, "merge.directoryRenames"));
   begin
      Result.Favor := Merge_Favor (Options);

      case Options.Conflict_Style is
         when Conflict_Style_Default =>
            if Style = "diff3" then
               Result.Style := Version.Merge.Conflict_Style_Diff3;
            elsif Style = "zdiff3" then
               Result.Style := Version.Merge.Conflict_Style_ZDiff3;
            else
               Result.Style := Version.Merge.Conflict_Style_Merge;
            end if;
         when Conflict_Style_Merge =>
            Result.Style := Version.Merge.Conflict_Style_Merge;
         when Conflict_Style_Diff3 =>
            Result.Style := Version.Merge.Conflict_Style_Diff3;
         when Conflict_Style_ZDiff3 =>
            Result.Style := Version.Merge.Conflict_Style_ZDiff3;
      end case;

      Result.Marker_Size := Positive_Config (Repo, "merge.markersize", Options.Marker_Size);
      if Options.Detect_Renames_Explicit then
         Result.Detect_Renames := Options.Detect_Renames;
      elsif Config_False (Rename_Config) then
         Result.Detect_Renames := False;
      elsif Config_True (Rename_Config) then
         Result.Detect_Renames := True;
      else
         Result.Detect_Renames := Options.Detect_Renames;
      end if;

      if Options.Strategy = Strategy_Resolve then
         Result.Detect_Renames := False;
      end if;

      Result.Rename_Threshold := Options.Rename_Threshold;
      if Options.Rename_Limit_Explicit then
         Result.Rename_Limit := Options.Rename_Limit;
      else
         Result.Rename_Limit :=
           Natural_Config_Text (Rename_Limit_Config, Options.Rename_Limit);
      end if;

      Result.Detect_Copies := Options.Detect_Copies;

      case Options.Directory_Renames is
         when Directory_Renames_Disabled =>
            Result.Directory_Renames := Version.Merge.Directory_Renames_Disabled;
         when Directory_Renames_Conflict =>
            Result.Directory_Renames := Version.Merge.Directory_Renames_Conflict;
         when Directory_Renames_Apply =>
            Result.Directory_Renames := Version.Merge.Directory_Renames_Apply;
         when Directory_Renames_Default =>
            if Directory_Renames_Config = "false"
              or else Directory_Renames_Config = "0"
              or else Directory_Renames_Config = "no"
              or else Directory_Renames_Config = "off"
            then
               Result.Directory_Renames := Version.Merge.Directory_Renames_Disabled;
            elsif Directory_Renames_Config = "conflict" then
               Result.Directory_Renames := Version.Merge.Directory_Renames_Conflict;
            else
               Result.Directory_Renames := Version.Merge.Directory_Renames_Apply;
            end if;
      end case;

      Result.Recurse_Submodules := Options.Recurse_Submodules;

      if Options.Renormalize or else Options.Renormalize_Explicit then
         Result.Renormalize := Options.Renormalize;
      elsif Config_True (Renormalize_Config) then
         Result.Renormalize := True;
      elsif Config_False (Renormalize_Config) then
         Result.Renormalize := False;
      else
         Result.Renormalize := False;
      end if;
      Result.Enable_Rerere := Options.Enable_Rerere;

      case Options.Whitespace is
         when Whitespace_Strict =>
            Result.Whitespace := Version.Merge.Whitespace_Strict;
         when Whitespace_Ignore_Space_Change =>
            Result.Whitespace := Version.Merge.Whitespace_Ignore_Space_Change;
         when Whitespace_Ignore_All_Space =>
            Result.Whitespace := Version.Merge.Whitespace_Ignore_All_Space;
         when Whitespace_Ignore_Space_At_EOL =>
            Result.Whitespace := Version.Merge.Whitespace_Ignore_Space_At_EOL;
         when Whitespace_Ignore_CR_At_EOL =>
            Result.Whitespace := Version.Merge.Whitespace_Ignore_CR_At_EOL;
      end case;

      case Options.Algorithm is
         when Diff_Algorithm_Default =>
            Result.Algorithm := Version.Merge.Diff_Algorithm_Default;
         when Diff_Algorithm_Myers =>
            Result.Algorithm := Version.Merge.Diff_Algorithm_Myers;
         when Diff_Algorithm_Minimal =>
            Result.Algorithm := Version.Merge.Diff_Algorithm_Minimal;
         when Diff_Algorithm_Patience =>
            Result.Algorithm := Version.Merge.Diff_Algorithm_Patience;
         when Diff_Algorithm_Histogram =>
            Result.Algorithm := Version.Merge.Diff_Algorithm_Histogram;
      end case;

      return Result;
   end Merge_Behavior_For;

   function Short_Target_Label (Target : String) return String is
   begin
      if Version.Objects.Is_Valid_Hex_Object_Id (Target) then
         return Short_Id (Target);
      else
         return Target;
      end if;
   end Short_Target_Label;

   function Is_Local_Branch_Target (Target : String) return Boolean is
   begin
      return Branch_Exists (Target);
   exception
      when others =>
         return False;
   end Is_Local_Branch_Target;

   function Default_Merge_Message (Target : String) return String is
      Label : constant String := Short_Target_Label (Target);
   begin
      if Is_Local_Branch_Target (Target) then
         return "Merge branch '" & Label & "'";
      else
         return "Merge " & Label;
      end if;
   end Default_Merge_Message;

   function Selected_Merge_Message
     (Repo      : Version.Repository.Repository_Handle;
      Target    : String;
      Target_Id : Version.Objects.Hex_Object_Id;
      Options   : Merge_Options) return String
   is
      Explicit : constant String := Ada.Strings.Unbounded.To_String (Options.Message);
      Into     : constant String := Ada.Strings.Unbounded.To_String (Options.Into_Name);
      Base     : constant String :=
        (if Explicit'Length > 0 then Explicit
         elsif Into'Length > 0 then Default_Merge_Message (Target) & " into " & Into
         else Default_Merge_Message (Target));
   begin
      return Finalize_Merge_Message
        (Repo         => Repo,
         Base_Message => Base,
         Target_Id    => Target_Id,
         Options      => Options);
   end Selected_Merge_Message;

   function Default_Multiple_Merge_Message
     (Targets : Merge_Target_Vectors.Vector) return String
   is
      Text : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Ada.Strings.Unbounded.Append (Text, "Merge");

      if not Targets.Is_Empty then
         for I in Targets.First_Index .. Targets.Last_Index loop
            if I = Targets.First_Index then
               Ada.Strings.Unbounded.Append (Text, " ");
            else
               Ada.Strings.Unbounded.Append (Text, ", ");
            end if;

            Ada.Strings.Unbounded.Append
              (Text,
               Short_Target_Label
                 (Ada.Strings.Unbounded.To_String (Targets.Element (I))));
         end loop;
      end if;

      return Ada.Strings.Unbounded.To_String (Text);
   end Default_Multiple_Merge_Message;

   function Selected_Multiple_Merge_Message
     (Repo    : Version.Repository.Repository_Handle;
      Targets : Merge_Target_Vectors.Vector;
      Ids     : Version.Objects.Object_Id_Vectors.Vector;
      Options : Merge_Options) return String
   is
      Explicit : constant String := Ada.Strings.Unbounded.To_String (Options.Message);
      Into     : constant String := Ada.Strings.Unbounded.To_String (Options.Into_Name);
      Base     : constant String :=
        (if Explicit'Length > 0 then Explicit
         elsif Into'Length > 0 then Default_Multiple_Merge_Message (Targets) & " into " & Into
         else Default_Multiple_Merge_Message (Targets));
      Result   : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Cleanup_Message
             (Base, Ada.Strings.Unbounded.To_String (Options.Cleanup_Mode)));
   begin
      if Options.Log_Limit > 0 and then not Ids.Is_Empty then
         for I in Ids.First_Index .. Ids.Last_Index loop
            Ada.Strings.Unbounded.Append
              (Result, Merge_Log_Text (Repo, Ids.Element (I), Options.Log_Limit));
         end loop;
      end if;

      if Options.Signoff then
         Ada.Strings.Unbounded.Append
           (Result, Character'Val (10) & Character'Val (10) & Signoff_Text (Repo));
      end if;

      declare
         Text : constant String := Ada.Strings.Unbounded.To_String (Result);
      begin
         if Options.Edit_Message then
            return Edit_Merge_Message (Repo => Repo, Message => Text);
         else
            return Text;
         end if;
      end;
   end Selected_Multiple_Merge_Message;

   procedure Require_Safe_Signing_Key (Signing_Key : String) is
   begin
      for C of Signing_Key loop
         if C = Character'Val (0)
           or else C = Character'Val (10)
           or else C = Character'Val (13)
         then
            raise Ada.IO_Exceptions.Data_Error with "invalid signing key";
         end if;
      end loop;
   end Require_Safe_Signing_Key;

   function Signing_Key_From_Mode (Mode : String) return String is
      Pos : Natural := Mode'First;
   begin
      while Pos <= Mode'Last loop
         while Pos <= Mode'Last and then Mode (Pos) = ' ' loop
            Pos := Pos + 1;
         end loop;

         exit when Pos > Mode'Last;

         declare
            First : constant Natural := Pos;
         begin
            while Pos <= Mode'Last and then Mode (Pos) /= ' ' loop
               Pos := Pos + 1;
            end loop;

            declare
               Token : constant String := Mode (First .. Pos - 1);
            begin
               if Token = "gpg-sign" then
                  return "default";
               elsif Token'Length > 9
                 and then Token (Token'First .. Token'First + 8) = "gpg-sign="
               then
                  declare
                     Key : constant String := Token (Token'First + 9 .. Token'Last);
                  begin
                     if Key'Length = 0 then
                        return "default";
                     else
                        return Key;
                     end if;
                  end;
               end if;
            end;
         end;
      end loop;

      return "";
   end Signing_Key_From_Mode;

   function Merge_Mode_Text (Options : Merge_Options) return String is
      Text : Ada.Strings.Unbounded.Unbounded_String;

      procedure Append_Mode (Mode : String) is
      begin
         if Ada.Strings.Unbounded.Length (Text) > 0 then
            Ada.Strings.Unbounded.Append (Text, " ");
         end if;
         Ada.Strings.Unbounded.Append (Text, Mode);
      end Append_Mode;
   begin
      if Options.Fast_Forward = Fast_Forward_Disabled then
         Append_Mode ("no-ff");
      elsif Options.Fast_Forward = Fast_Forward_Only then
         Append_Mode ("ff-only");
      end if;

      if Options.No_Commit then
         Append_Mode ("no-commit");
      end if;

      if Options.Squash then
         Append_Mode ("squash");
      end if;

      if Ada.Strings.Unbounded.Length (Options.GPG_Sign) > 0 then
         declare
            Key : constant String := Ada.Strings.Unbounded.To_String (Options.GPG_Sign);
         begin
            Require_Safe_Signing_Key (Key);
            if Key = "default" then
               Append_Mode ("gpg-sign");
            else
               Append_Mode ("gpg-sign=" & Key);
            end if;
         end;
      end if;

      return Ada.Strings.Unbounded.To_String (Text);
   end Merge_Mode_Text;

   function Is_Squash_Mode (Mode : String) return Boolean is
   begin
      return Ada.Strings.Fixed.Index (Mode, "squash") /= 0;
   end Is_Squash_Mode;

   function First_Line (Text : String) return String is
   begin
      for I in Text'Range loop
         if Text (I) = Character'Val (10) or else Text (I) = Character'Val (13) then
            if I = Text'First then
               return "";
            else
               return Text (Text'First .. I - 1);
            end if;
         end if;
      end loop;

      return Text;
   end First_Line;

   function Contains_Object_Id
     (Ids : Version.Objects.Object_Id_Vectors.Vector;
      Id  : Version.Objects.Hex_Object_Id) return Boolean
   is
   begin
      if Ids.Is_Empty then
         return False;
      end if;

      for I in Ids.First_Index .. Ids.Last_Index loop
         if Ids.Element (I) = Id then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Object_Id;

   procedure Commit_Merge_Result
     (Repo           : Version.Repository.Repository_Handle;
      Current_Id     : Version.Objects.Hex_Object_Id;
      Target_Id      : Version.Objects.Hex_Object_Id;
      Tree_Id        : Version.Objects.Hex_Object_Id;
      Message        : String;
      Reflog_Message : String;
      Squash         : Boolean;
      Run_Hooks      : Boolean;
      Signing_Key    : String := "")
   is
      Parents : Version.Objects.Object_Id_Vectors.Vector;
   begin
      Parents.Append (Current_Id);
      if not Squash then
         Parents.Append (Target_Id);
      end if;

      if not Squash then
         Version.Hooks.Run_Pre_Merge_Commit
           (Repo => Repo, Run_Hooks => Run_Hooks);
      end if;

      declare
         Prepared_Message : constant String :=
           Version.Hooks.Prepare_Commit_Message
             (Repo => Repo, Message => Message, Run_Hooks => Run_Hooks);

         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           (if Signing_Key'Length > 0 then
              Version.Write.Write_Signed_Commit_With_Parents
                (Repo        => Repo,
                 Tree_Id     => Tree_Id,
                 Parents     => Parents,
                 Message     => Prepared_Message,
                 Signing_Key => Signing_Key)
            else
              Version.Write.Write_Commit_With_Parents
                (Repo    => Repo,
                 Tree_Id => Tree_Id,
                 Parents => Parents,
                 Message => Prepared_Message));
      begin
         Write_Current_Branch_Commit (Repo => Repo, Commit => Commit_Id);

         Append_HEAD_And_Current_Branch_Reflog
           (Repo    => Repo,
            Old_Id  => Current_Id,
            New_Id  => Commit_Id,
            Message => Reflog_Message);

         Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => Run_Hooks);
         Version.Hooks.Run_Post_Merge
           (Repo => Repo, Squash => Squash, Run_Hooks => Run_Hooks);
      end;
   end Commit_Merge_Result;

   procedure Commit_Merge_Result_With_Parents
     (Repo           : Version.Repository.Repository_Handle;
      Current_Id     : Version.Objects.Hex_Object_Id;
      Tree_Id        : Version.Objects.Hex_Object_Id;
      Parents        : Version.Objects.Object_Id_Vectors.Vector;
      Message        : String;
      Reflog_Message : String;
      Run_Hooks      : Boolean;
      Signing_Key    : String := "")
   is
   begin
      Version.Hooks.Run_Pre_Merge_Commit
        (Repo => Repo, Run_Hooks => Run_Hooks);

      declare
         Prepared_Message : constant String :=
           Version.Hooks.Prepare_Commit_Message
             (Repo => Repo, Message => Message, Run_Hooks => Run_Hooks);

         Commit_Id : constant Version.Objects.Hex_Object_Id :=
        (if Signing_Key'Length > 0 then
           Version.Write.Write_Signed_Commit_With_Parents
             (Repo        => Repo,
              Tree_Id     => Tree_Id,
              Parents     => Parents,
              Message     => Prepared_Message,
              Signing_Key => Signing_Key)
         else
           Version.Write.Write_Commit_With_Parents
             (Repo    => Repo,
              Tree_Id => Tree_Id,
              Parents => Parents,
              Message => Prepared_Message));
      begin
         Write_Current_Branch_Commit (Repo => Repo, Commit => Commit_Id);

         Append_HEAD_And_Current_Branch_Reflog
           (Repo    => Repo,
            Old_Id  => Current_Id,
            New_Id  => Commit_Id,
            Message => Reflog_Message);

         Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => Run_Hooks);
         Version.Hooks.Run_Post_Merge
           (Repo => Repo, Squash => False, Run_Hooks => Run_Hooks);
      end;
   end Commit_Merge_Result_With_Parents;

   procedure Fast_Forward_Current_Branch_To_Commit
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Target     : String;
      Run_Hooks  : Boolean) is
   begin
      Version.Merge_State.Write_Orig_Head
        (Repo => Repo, Current_Id => Current_Id);
      Write_Current_Branch_Commit (Repo => Repo, Commit => Target_Id);

      Append_HEAD_And_Current_Branch_Reflog
        (Repo    => Repo,
         Old_Id  => Current_Id,
         New_Id  => Target_Id,
         Message => "merge: fast-forward to " & Short_Target_Label (Target));

      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Target_Id);
      Version.Restore.Write_Index_For_Commit
        (Repo => Repo, Commit_Id => Target_Id);
      Version.Hooks.Run_Post_Merge
        (Repo => Repo, Squash => False, Run_Hooks => Run_Hooks);
   end Fast_Forward_Current_Branch_To_Commit;

   function Merge_Base_For
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Options    : Merge_Options) return Version.Objects.Hex_Object_Id is
   begin
      return Version.History.Merge_Base
        (Repo => Repo, Left => Current_Id, Right => Target_Id);
   exception
      when Ada.IO_Exceptions.Data_Error =>
         if Options.Allow_Unrelated_Histories then
            return Zero_Id;
         else
            raise;
         end if;
   end Merge_Base_For;

   type Merge_Base_Result is record
      Base_Id : Version.Objects.Object_Id_Storage;
      Items   : Version.Objects.Tree_Entry_Vectors.Vector;
   end record;

   function Tree_Items_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit
          (Repo      => Repo,
           Objects   => Objects,
           Commit_Id => Commit_Id);
   begin
      return Version.Tree_Cache.Flatten_Tree
        (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
   end Tree_Items_For_Commit;

   function Commit_Distance
     (Repo   : Version.Repository.Repository_Handle;
      Start  : Version.Objects.Hex_Object_Id;
      Target : Version.Objects.Hex_Object_Id) return Natural
   is
      Pending : Version.History.Commit_Id_Vectors.Vector;
      Depths  : Natural_Vectors.Vector;
      Seen    : Path_Sets.Set;
   begin
      Pending.Append (Start);
      Depths.Append (0);

      while not Pending.Is_Empty loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Pending.First_Element;
            Current_Depth : constant Natural := Depths.First_Element;
            Current_Key : constant String := To_String (Current_Id);
         begin
            Pending.Delete_First;
            Depths.Delete_First;

            if Current_Id = Target then
               return Current_Depth;
            end if;

            if not Seen.Contains (Current_Key) then
               Seen.Include (Current_Key);

               declare
                  Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                    Version.History.Parent_Commits (Repo, Current_Id);
               begin
                  if not Parents.Is_Empty then
                     for I in Parents.First_Index .. Parents.Last_Index loop
                        if not Seen.Contains (To_String (Parents.Element (I))) then
                           Pending.Append (Parents.Element (I));
                           Depths.Append (Current_Depth + 1);
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      return Natural'Last;
   end Commit_Distance;

   function Recursive_Base_Order_Score
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Base_Id    : Version.Objects.Hex_Object_Id) return Natural
   is
      Left_Distance  : constant Natural :=
        Commit_Distance (Repo, Current_Id, Base_Id);
      Right_Distance : constant Natural :=
        Commit_Distance (Repo, Target_Id, Base_Id);
   begin
      if Left_Distance = Natural'Last or else Right_Distance = Natural'Last then
         return Natural'Last;
      elsif Left_Distance > Natural'Last - Right_Distance then
         return Natural'Last;
      else
         return Left_Distance + Right_Distance;
      end if;
   end Recursive_Base_Order_Score;

   function Ordered_Recursive_Bases
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Bases      : Version.History.Commit_Id_Vectors.Vector)
      return Version.History.Commit_Id_Vectors.Vector
   is
      Result : Version.History.Commit_Id_Vectors.Vector := Bases;
   begin
      if Result.Length <= 1 then
         return Result;
      end if;

      for I in Result.First_Index .. Result.Last_Index loop
         declare
            Best : Natural := I;
         begin
            for J in I + 1 .. Result.Last_Index loop
               declare
                  Best_Id : constant Version.Objects.Hex_Object_Id :=
                    Result.Element (Best);
                  Candidate_Id : constant Version.Objects.Hex_Object_Id :=
                    Result.Element (J);
                  Best_Score : constant Natural :=
                    Recursive_Base_Order_Score
                      (Repo, Current_Id, Target_Id, Best_Id);
                  Candidate_Score : constant Natural :=
                    Recursive_Base_Order_Score
                      (Repo, Current_Id, Target_Id, Candidate_Id);
               begin
                  if Candidate_Score < Best_Score
                    or else
                      (Candidate_Score = Best_Score
                       and then To_String (Candidate_Id) < To_String (Best_Id))
                  then
                     Best := J;
                  end if;
               end;
            end loop;

            if Best /= I then
               declare
                  A : constant Version.Objects.Hex_Object_Id := Result.Element (I);
                  B : constant Version.Objects.Hex_Object_Id := Result.Element (Best);
               begin
                  Result.Replace_Element (I, B);
                  Result.Replace_Element (Best, A);
               end;
            end if;
         end;
      end loop;

      return Result;
   end Ordered_Recursive_Bases;

   function Merge_Base_Result_For
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Options    : Merge_Options;
      Objects    : in out Version.Object_Cache.Object_Cache;
      Trees      : in out Version.Tree_Cache.Tree_Cache)
      return Merge_Base_Result
   is
      Raw_Bases : constant Version.History.Commit_Id_Vectors.Vector :=
        Version.History.Merge_Bases
          (Repo => Repo, Left => Current_Id, Right => Target_Id);
      Bases : constant Version.History.Commit_Id_Vectors.Vector :=
        Ordered_Recursive_Bases
          (Repo       => Repo,
           Current_Id => Current_Id,
           Target_Id  => Target_Id,
           Bases      => Raw_Bases);
   begin
      if Bases.Is_Empty then
         if Options.Allow_Unrelated_Histories then
            return Merge_Base_Result'
              (Base_Id => Zero_Id,
               Items   => Empty_Tree_Items);
         else
            raise Ada.IO_Exceptions.Data_Error with "no merge base found";
         end if;
      end if;

      declare
         First_Base : constant Version.Objects.Hex_Object_Id :=
           Bases.First_Element;
      begin
         if Bases.Length = 1 then
            return Merge_Base_Result'
              (Base_Id => First_Base,
               Items   => Tree_Items_For_Commit
                 (Repo      => Repo,
                  Objects   => Objects,
                  Trees     => Trees,
                  Commit_Id => First_Base));
         end if;

         if Options.Strategy = Strategy_Resolve then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot merge: resolve strategy cannot handle multiple merge bases";
         end if;

         declare
            Accum_Id : Version.Objects.Hex_Object_Id := First_Base;
            Accum_Items : Version.Objects.Tree_Entry_Vectors.Vector :=
              Tree_Items_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Trees     => Trees,
                 Commit_Id => First_Base);
            Behavior : Version.Merge.Merge_Behavior :=
              Merge_Behavior_For (Repo, Options);
         begin
            Behavior.Update_Worktree := False;
            Behavior.Enable_Rerere := False;
            Behavior.Materialize_Virtual_Conflicts := True;

            for I in Bases.First_Index + 1 .. Bases.Last_Index loop
               declare
                  Next_Id : constant Version.Objects.Hex_Object_Id :=
                    Bases.Element (I);
                  Pair_Base_Id : constant Version.Objects.Hex_Object_Id :=
                    Merge_Base_For
                      (Repo       => Repo,
                       Current_Id => Accum_Id,
                       Target_Id  => Next_Id,
                       Options    => Options);
                  Pair_Base_Items : constant
                    Version.Objects.Tree_Entry_Vectors.Vector :=
                    (if Pair_Base_Id = Zero_Id then
                        Empty_Tree_Items
                     else
                        Tree_Items_For_Commit
                          (Repo      => Repo,
                           Objects   => Objects,
                           Trees     => Trees,
                           Commit_Id => Pair_Base_Id));
                  Next_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Tree_Items_For_Commit
                      (Repo      => Repo,
                       Objects   => Objects,
                       Trees     => Trees,
                       Commit_Id => Next_Id);
                  Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
                  Conflicts    : Version.Merge.Conflict_Vectors.Vector;
               begin
                  Version.Merge.Merge_Trees
                    (Repo          => Repo,
                     Current_Name  => "merge-base",
                     Target_Name   => "merge-base",
                     Base_Items    => Pair_Base_Items,
                     Current_Items => Accum_Items,
                     Target_Items  => Next_Items,
                     Merged_Index  => Merged_Index,
                     Conflicts     => Conflicts,
                     Behavior      => Behavior);

                  if not Conflicts.Is_Empty then
                     for C in Conflicts.First_Index .. Conflicts.Last_Index loop
                        if Version.Staging.Find_Stage_Entry
                             (Merged_Index,
                              Ada.Strings.Unbounded.To_String
                                (Conflicts.Element (C).Path),
                              0) = Natural'Last
                        then
                           raise Ada.IO_Exceptions.Data_Error with
                             "cannot materialize recursive virtual merge base conflict";
                        end if;
                     end loop;
                  end if;

                  declare
                     Tree_Id : constant Version.Objects.Hex_Object_Id :=
                       Version.Write.Write_Tree_From_Index
                         (Repo => Repo, Entries => Merged_Index);
                     Parents : Version.Objects.Object_Id_Vectors.Vector;
                  begin
                     Parents.Append (Accum_Id);
                     Parents.Append (Next_Id);
                     Accum_Id := Version.Write.Write_Commit_With_Parents
                       (Repo    => Repo,
                        Tree_Id => Tree_Id,
                        Parents => Parents,
                        Message => "virtual merge base");
                     Accum_Items := Version.Tree_Cache.Flatten_Tree
                       (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
                  end;
               end;
            end loop;

            return Merge_Base_Result'
              (Base_Id => Accum_Id,
               Items   => Accum_Items);
         end;
      end;
   end Merge_Base_Result_For;

   procedure Write_Auto_Merge_From_Working_Tree
     (Repo : Version.Repository.Repository_Handle);

   procedure Write_Clean_Paused_Merge_State
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Base_Id    : Version.Objects.Hex_Object_Id;
      Target     : String;
      Message    : String;
      Mode       : String) is
      Empty : Version.Merge.Conflict_Vectors.Vector;
   begin
      Version.Merge_State.Write_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Base_Id,
         Target_Branch => Target,
         Conflicts     => Empty,
         Git_State     => True,
         Message       => Message,
         Mode          => Mode);
   end Write_Clean_Paused_Merge_State;

   procedure Write_Merge_Head_Ids
     (Repo       : Version.Repository.Repository_Handle;
      Target_Ids : Version.Objects.Object_Id_Vectors.Vector)
   is
      Heads : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Target_Ids.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with "cannot merge: missing merge target";
      end if;

      for I in Target_Ids.First_Index .. Target_Ids.Last_Index loop
         Ada.Strings.Unbounded.Append
           (Heads, To_String (Target_Ids.Element (I)) & Character'Val (10));
      end loop;

      Version.Files.Write_Binary_File_Atomic
        (Path    => Git_State_File (Repo, "MERGE_HEAD"),
         Content => Ada.Strings.Unbounded.To_String (Heads));
   end Write_Merge_Head_Ids;

   procedure Write_Clean_Paused_Merge_State_Multiple
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Ids : Version.Objects.Object_Id_Vectors.Vector;
      Message    : String;
      Mode       : String)
   is
   begin
      Version.Merge_State.Write_Orig_Head (Repo => Repo, Current_Id => Current_Id);
      Write_Merge_Head_Ids (Repo => Repo, Target_Ids => Target_Ids);

      Version.Files.Write_Binary_File_Atomic
        (Path    => Git_State_File (Repo, "MERGE_MSG"),
         Content => Message & Character'Val (10));

      if Mode'Length > 0 then
         Version.Files.Write_Binary_File_Atomic
           (Path    => Git_State_File (Repo, "MERGE_MODE"),
            Content => Mode & Character'Val (10));
      else
         Version.Files.Delete_File_If_Exists (Git_State_File (Repo, "MERGE_MODE"));
      end if;

      Version.Files.Delete_File_If_Exists (Git_State_File (Repo, "SQUASH_MSG"));
   end Write_Clean_Paused_Merge_State_Multiple;

   procedure Merge
     (Target  : String;
      Options : Merge_Options)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Require_Attached_HEAD ("cannot merge", Repo);
      Require_No_Rebase_State ("cannot merge", Repo);

      if Version.Merge_State.State_Exists (Repo)
        or else Version.Merge_State.Git_State_Exists (Repo)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot merge: merge state already exists";
      end if;

      Reject_Unsupported_Merge_Index (Repo);

      declare
         Current_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));

         Target_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, Target);

         Effective_Options : constant Merge_Options :=
           Merge_Configured_Options (Repo, Options);
         Message : constant String :=
           Selected_Merge_Message
             (Repo      => Repo,
              Target    => Target,
              Target_Id => Target_Id,
              Options   => Effective_Options);
         Mode    : constant String := Merge_Mode_Text (Effective_Options);
      begin
         if Version.History.Is_Ancestor
              (Repo => Repo, Base_Id => Target_Id, Derived_Id => Current_Id)
         then
            return;
         end if;

         if Effective_Options.Strategy = Strategy_Octopus then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot merge: octopus strategy requires multiple targets";
         end if;

         if Effective_Options.Autostash then
            Create_Merge_Autostash (Repo);
         else
            Require_Clean_Status (Allow_Untracked => True);
         end if;

         if Effective_Options.Verify_Signatures then
            Verify_Commit_Signature (Repo, Target_Id);
         end if;

         if not Effective_Options.Subtree
           and then Version.History.Is_Ancestor
              (Repo => Repo, Base_Id => Current_Id, Derived_Id => Target_Id)
         then
            if Effective_Options.Squash then
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Version.Restore.Restore_Working_Tree_For_Commit
                 (Repo => Repo, Commit_Id => Target_Id);
               Version.Restore.Write_Index_For_Commit
                 (Repo => Repo, Commit_Id => Target_Id);
               Version.Files.Write_Binary_File_Atomic
                 (Path    => Join (Version.Repository.Git_Dir (Repo), "SQUASH_MSG"),
                  Content => Message & Character'Val (10));
               Version.Hooks.Run_Post_Merge
                 (Repo => Repo, Squash => True, Run_Hooks => Effective_Options.Run_Hooks);
               Apply_Merge_Autostash (Repo);
               return;
            elsif Effective_Options.No_Commit then
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Version.Restore.Restore_Working_Tree_For_Commit
                 (Repo => Repo, Commit_Id => Target_Id);
               Version.Restore.Write_Index_For_Commit
                 (Repo => Repo, Commit_Id => Target_Id);
               Write_Clean_Paused_Merge_State
                 (Repo       => Repo,
                  Current_Id => Current_Id,
                  Target_Id  => Target_Id,
                  Base_Id    => Current_Id,
                  Target     => Target,
                  Message    => Message,
                  Mode       => Mode);
               Apply_Merge_Autostash (Repo);
               return;
            elsif Effective_Options.Fast_Forward /= Fast_Forward_Disabled then
               Fast_Forward_Current_Branch_To_Commit
                 (Repo       => Repo,
                  Current_Id => Current_Id,
                  Target_Id  => Target_Id,
                  Target     => Target,
                  Run_Hooks  => Effective_Options.Run_Hooks);
               Apply_Merge_Autostash (Repo);
               return;
            end if;
         elsif Effective_Options.Fast_Forward = Fast_Forward_Only then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot merge: not possible to fast-forward";
         end if;

         declare
            Objects : Version.Object_Cache.Object_Cache;
            Trees   : Version.Tree_Cache.Tree_Cache;

            Base : constant Merge_Base_Result :=
              Merge_Base_Result_For
                (Repo       => Repo,
                 Current_Id => Current_Id,
                 Target_Id  => Target_Id,
                 Options    => Effective_Options,
                 Objects    => Objects,
                 Trees      => Trees);

            Base_Id : constant Version.Objects.Hex_Object_Id := Base.Base_Id;

            Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Current_Id);

            Target_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Target_Id);

            Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Base.Items;

            Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo    => Repo,
                 Cache   => Trees,
                 Tree_Id => Current_Tree_Id);

            Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo    => Repo,
                 Cache   => Trees,
                 Tree_Id => Target_Tree_Id);

            Subtree_Prefix : constant String :=
              Effective_Subtree_Prefix
                (Options       => Effective_Options,
                 Current_Items => Current_Items,
                 Target_Items  => Target_Items);

            Effective_Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Rewrite_Subtree_Items
                (Items  => Base_Items,
                 Prefix => Subtree_Prefix);

            Effective_Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Rewrite_Subtree_Items
                (Items  => Target_Items,
                 Prefix => Subtree_Prefix);

            Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
            Conflicts    : Version.Merge.Conflict_Vectors.Vector;
         begin
            if Effective_Options.Strategy_Ours
              or else Effective_Options.Strategy = Strategy_Ours
            then
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Commit_Merge_Result
                 (Repo           => Repo,
                  Current_Id     => Current_Id,
                  Target_Id      => Target_Id,
                  Tree_Id        => Current_Tree_Id,
                  Message        => Message,
                  Reflog_Message => "merge: " & First_Line (Message),
                  Squash         => False,
                  Run_Hooks      => Effective_Options.Run_Hooks,
                  Signing_Key    => Ada.Strings.Unbounded.To_String
                    (Effective_Options.GPG_Sign));
               Version.Restore.Restore_Working_Tree (Repo);
               Version.Staging.Write (Repo => Repo, Entries => Version.Staging.Load (Repo));
               Apply_Merge_Autostash (Repo);
               return;
            end if;

            Reject_Untracked_Overwrite (Effective_Target_Items);

            Version.Merge.Merge_Trees
              (Repo          => Repo,
               Current_Name  => Version.Refs.Current_Branch_Name (Repo),
               Target_Name   => Target,
               Base_Items    => Effective_Base_Items,
               Current_Items => Current_Items,
               Target_Items  => Effective_Target_Items,
               Merged_Index  => Merged_Index,
               Conflicts     => Conflicts,
               Behavior      => Merge_Behavior_For (Repo, Effective_Options));

            if not Conflicts.Is_Empty then
               Version.Merge_State.Write_State
                 (Repo          => Repo,
                  Current_Id    => Current_Id,
                  Target_Id     => Target_Id,
                  Base_Id       => Base_Id,
                  Target_Branch => Target,
                  Conflicts     => Conflicts,
                  Git_State     => True,
                  Message       => Message,
                  Mode          => Mode);
               Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
               Write_Auto_Merge_From_Working_Tree (Repo);

               raise Ada.IO_Exceptions.Data_Error with
                 "cannot merge: conflicts recorded";
            end if;

            if Effective_Options.Squash then
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
               Version.Files.Write_Binary_File_Atomic
                 (Path    => Join (Version.Repository.Git_Dir (Repo), "SQUASH_MSG"),
                  Content => Message & Character'Val (10));
               Version.Hooks.Run_Post_Merge
                 (Repo => Repo, Squash => True, Run_Hooks => Effective_Options.Run_Hooks);
               Apply_Merge_Autostash (Repo);
               return;
            elsif Effective_Options.No_Commit then
               Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
               Write_Clean_Paused_Merge_State
                 (Repo       => Repo,
                  Current_Id => Current_Id,
                  Target_Id  => Target_Id,
                  Base_Id    => Base_Id,
                  Target     => Target,
                  Message    => Message,
                  Mode       => Mode);
               Apply_Merge_Autostash (Repo);
               return;
            end if;

            declare
               Tree_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Tree_From_Index
                   (Repo => Repo, Entries => Merged_Index);
            begin
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Commit_Merge_Result
                 (Repo           => Repo,
                  Current_Id     => Current_Id,
                  Target_Id      => Target_Id,
                  Tree_Id        => Tree_Id,
                  Message        => Message,
                  Reflog_Message => "merge: " & First_Line (Message),
                  Squash         => False,
                  Run_Hooks      => Effective_Options.Run_Hooks,
                  Signing_Key    => Ada.Strings.Unbounded.To_String
                    (Effective_Options.GPG_Sign));
            end;

            Version.Restore.Restore_Working_Tree (Repo);
            Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
            Apply_Merge_Autostash (Repo);
         end;
      end;
   end Merge;

   procedure Merge_Multiple
     (Targets : Merge_Target_Vectors.Vector;
      Options : Merge_Options)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if Targets.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot merge: missing merge target";
      elsif Targets.Length = 1 then
         Merge
           (Target  => Ada.Strings.Unbounded.To_String
                         (Targets.Element (Targets.First_Index)),
            Options => Options);
         return;
      end if;

      Require_Attached_HEAD ("cannot merge", Repo);
      Require_No_Rebase_State ("cannot merge", Repo);

      if Version.Merge_State.State_Exists (Repo)
        or else Version.Merge_State.Git_State_Exists (Repo)
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot merge: merge state already exists";
      end if;

      Reject_Unsupported_Merge_Index (Repo);

      declare
         Current_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));

         Effective_Options : constant Merge_Options :=
           Merge_Configured_Options (Repo, Options);
         Effective_Targets : Merge_Target_Vectors.Vector;
         Effective_Ids     : Version.Objects.Object_Id_Vectors.Vector;
      begin
         for I in Targets.First_Index .. Targets.Last_Index loop
            declare
               Target_Text : constant String :=
                 Ada.Strings.Unbounded.To_String (Targets.Element (I));

               Target_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Revisions.Resolve_Commit (Repo, Target_Text);
            begin
               if Version.History.Is_Ancestor
                    (Repo => Repo, Base_Id => Target_Id, Derived_Id => Current_Id)
               then
                  null;
               elsif not Contains_Object_Id (Effective_Ids, Target_Id) then
                  Effective_Targets.Append (Targets.Element (I));
                  Effective_Ids.Append (Target_Id);
               end if;
            end;
         end loop;

         if Effective_Ids.Is_Empty then
            return;
         elsif Effective_Ids.Length = 1 then
            Merge
              (Target  => Ada.Strings.Unbounded.To_String
                            (Effective_Targets.Element
                               (Effective_Targets.First_Index)),
               Options => Options);
            return;
         end if;

         if Effective_Options.Strategy in Strategy_Ort | Strategy_Recursive
              | Strategy_Resolve | Strategy_Subtree
         then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot merge: selected strategy supports only one target";
         end if;

         if Effective_Options.Autostash then
            Create_Merge_Autostash (Repo);
         else
            Require_Clean_Status (Allow_Untracked => True);
         end if;

         if Effective_Options.Verify_Signatures and then not Effective_Ids.Is_Empty then
            for I in Effective_Ids.First_Index .. Effective_Ids.Last_Index loop
               Verify_Commit_Signature (Repo, Effective_Ids.Element (I));
            end loop;
         end if;

         if Effective_Options.Fast_Forward = Fast_Forward_Only then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot merge: not possible to fast-forward multiple targets";
         end if;

         declare
            Objects : Version.Object_Cache.Object_Cache;
            Trees   : Version.Tree_Cache.Tree_Cache;

            Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit
                (Repo      => Repo,
                 Objects   => Objects,
                 Commit_Id => Current_Id);

            Accum_Tree_Id : Version.Objects.Hex_Object_Id := Current_Tree_Id;
            Accum_Items   : Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Tree_Cache.Flatten_Tree
                (Repo => Repo, Cache => Trees, Tree_Id => Current_Tree_Id);

            Final_Index : Version.Staging.Index_Entry_Vectors.Vector;
            Message     : constant String :=
              Selected_Multiple_Merge_Message
                (Repo    => Repo,
                 Targets => Effective_Targets,
                 Ids     => Effective_Ids,
                 Options => Effective_Options);
            Mode        : constant String := Merge_Mode_Text (Effective_Options);
            Completed_Ids : Version.Objects.Object_Id_Vectors.Vector;
         begin
            if Effective_Options.Strategy_Ours
              or else Effective_Options.Strategy = Strategy_Ours
            then
               declare
                  Parents : Version.Objects.Object_Id_Vectors.Vector;
               begin
                  Parents.Append (Current_Id);
                  for I in Effective_Ids.First_Index .. Effective_Ids.Last_Index loop
                     Parents.Append (Effective_Ids.Element (I));
                  end loop;

                  if Effective_Options.No_Commit then
                     Version.Staging.Write
                       (Repo => Repo, Entries => Version.Staging.Load (Repo));
                     Write_Clean_Paused_Merge_State_Multiple
                       (Repo       => Repo,
                        Current_Id => Current_Id,
                        Target_Ids => Effective_Ids,
                        Message    => Message,
                        Mode       => Mode);
                     Apply_Merge_Autostash (Repo);
                     return;
                  end if;

                  Version.Merge_State.Write_Orig_Head
                    (Repo => Repo, Current_Id => Current_Id);
                  Commit_Merge_Result_With_Parents
                    (Repo           => Repo,
                     Current_Id     => Current_Id,
                     Tree_Id        => Current_Tree_Id,
                     Parents        => Parents,
                     Message        => Message,
                     Reflog_Message => "merge: " & First_Line (Message),
                     Run_Hooks      => Effective_Options.Run_Hooks,
                     Signing_Key    => Ada.Strings.Unbounded.To_String
                       (Effective_Options.GPG_Sign));
                  Version.Restore.Restore_Working_Tree (Repo);
                  Version.Staging.Write
                    (Repo => Repo, Entries => Version.Staging.Load (Repo));
                  Apply_Merge_Autostash (Repo);
                  return;
               end;
            end if;

            for I in Effective_Ids.First_Index .. Effective_Ids.Last_Index loop
               declare
                  Target_Id : constant Version.Objects.Hex_Object_Id :=
                    Effective_Ids.Element (I);

                  Target_Name : constant String :=
                    Ada.Strings.Unbounded.To_String
                      (Effective_Targets.Element (I));

                  Base : constant Merge_Base_Result :=
                    Merge_Base_Result_For
                      (Repo       => Repo,
                       Current_Id => Current_Id,
                       Target_Id  => Target_Id,
                       Options    => Effective_Options,
                       Objects    => Objects,
                       Trees      => Trees);

                  Base_Id : constant Version.Objects.Hex_Object_Id := Base.Base_Id;

                  Target_Tree_Id : constant Version.Objects.Hex_Object_Id :=
                    Tree_Id_For_Commit
                      (Repo      => Repo,
                       Objects   => Objects,
                       Commit_Id => Target_Id);

                  Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Base.Items;

                  Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Version.Tree_Cache.Flatten_Tree
                      (Repo    => Repo,
                       Cache   => Trees,
                       Tree_Id => Target_Tree_Id);

                  Subtree_Prefix : constant String :=
                    Effective_Subtree_Prefix
                      (Options       => Effective_Options,
                       Current_Items => Accum_Items,
                       Target_Items  => Target_Items);

                  Effective_Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Rewrite_Subtree_Items
                      (Items  => Base_Items,
                       Prefix => Subtree_Prefix);

                  Effective_Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Rewrite_Subtree_Items
                      (Items  => Target_Items,
                       Prefix => Subtree_Prefix);

                  Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
                  Conflicts    : Version.Merge.Conflict_Vectors.Vector;
               begin
                  Reject_Untracked_Overwrite (Effective_Target_Items);

                  Version.Merge.Merge_Trees
                    (Repo          => Repo,
                     Current_Name  => Version.Refs.Current_Branch_Name (Repo),
                     Target_Name   => Target_Name,
                     Base_Items    => Effective_Base_Items,
                     Current_Items => Accum_Items,
                     Target_Items  => Effective_Target_Items,
                     Merged_Index  => Merged_Index,
                     Conflicts     => Conflicts,
                     Behavior      => Merge_Behavior_For (Repo, Effective_Options));

                  if not Conflicts.Is_Empty then
                     Version.Merge_State.Write_State
                       (Repo          => Repo,
                        Current_Id    => Current_Id,
                        Target_Id     => Target_Id,
                        Base_Id       => Base_Id,
                        Target_Branch => Target_Name,
                        Conflicts     => Conflicts,
                        Git_State     => True,
                        Message       => Message,
                        Mode          => Mode);
                     Write_Merge_Head_Ids
                       (Repo       => Repo,
                        Target_Ids => Effective_Ids);
                     Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
                     Write_Auto_Merge_From_Working_Tree (Repo);

                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot merge: octopus conflicts recorded";
                  end if;

                  Accum_Tree_Id :=
                    Version.Write.Write_Tree_From_Index
                      (Repo => Repo, Entries => Merged_Index);
                  Accum_Items :=
                    Version.Tree_Cache.Flatten_Tree
                      (Repo => Repo, Cache => Trees, Tree_Id => Accum_Tree_Id);
                  Final_Index := Merged_Index;
                  Completed_Ids.Append (Target_Id);
               end;
            end loop;

            if Effective_Options.Squash then
               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Version.Staging.Write (Repo => Repo, Entries => Final_Index);
               Version.Files.Write_Binary_File_Atomic
                 (Path    => Join (Version.Repository.Git_Dir (Repo), "SQUASH_MSG"),
                  Content => Message & Character'Val (10));
               Version.Hooks.Run_Post_Merge
                 (Repo => Repo, Squash => True, Run_Hooks => Effective_Options.Run_Hooks);
               Apply_Merge_Autostash (Repo);
               return;
            elsif Effective_Options.No_Commit then
               Version.Staging.Write (Repo => Repo, Entries => Final_Index);
               Write_Clean_Paused_Merge_State_Multiple
                 (Repo       => Repo,
                  Current_Id => Current_Id,
                  Target_Ids => Effective_Ids,
                  Message    => Message,
                  Mode       => Mode);
               Apply_Merge_Autostash (Repo);
               return;
            end if;

            declare
               Parents : Version.Objects.Object_Id_Vectors.Vector;
            begin
               Parents.Append (Current_Id);
               for I in Effective_Ids.First_Index .. Effective_Ids.Last_Index loop
                  Parents.Append (Effective_Ids.Element (I));
               end loop;

               Version.Merge_State.Write_Orig_Head
                 (Repo => Repo, Current_Id => Current_Id);
               Commit_Merge_Result_With_Parents
                 (Repo           => Repo,
                  Current_Id     => Current_Id,
                  Tree_Id        => Accum_Tree_Id,
                  Parents        => Parents,
                  Message        => Message,
                  Reflog_Message => "merge: " & First_Line (Message),
                  Run_Hooks      => Effective_Options.Run_Hooks,
                  Signing_Key    => Ada.Strings.Unbounded.To_String
                    (Effective_Options.GPG_Sign));
            end;

            Version.Restore.Restore_Working_Tree (Repo);
            Version.Staging.Write (Repo => Repo, Entries => Final_Index);
            Apply_Merge_Autostash (Repo);
         end;
      end;
   end Merge_Multiple;

   function File_Contains_Conflict_Marker (Path : String) return Boolean is
      File : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         return False;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Ada.Strings.Fixed.Index (Line, "<<<<<<<") /= 0
              or else Ada.Strings.Fixed.Index (Line, "=======") /= 0
              or else Ada.Strings.Fixed.Index (Line, ">>>>>>>") /= 0
            then
               Ada.Text_IO.Close (File);
               return True;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return False;

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;

         raise;
   end File_Contains_Conflict_Marker;

   function Working_Tree_Has_Conflict_Markers
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is
      Files : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);
   begin
      if Files.Is_Empty then
         return False;
      end if;

      for I in Files.First_Index .. Files.Last_Index loop
         declare
            Relative_Path : constant String :=
              Ada.Strings.Unbounded.To_String (Files.Element (I).Path);

            Absolute_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Root_Path (Repo), Relative_Path);
         begin
            if File_Contains_Conflict_Marker (Absolute_Path) then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Working_Tree_Has_Conflict_Markers;

   function Tree_Item_Id_For_Path
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Found     : out Boolean)
      return Version.Objects.Hex_Object_Id
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit (Repo => Repo, Commit_Id => Commit_Id);

      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);

      Pos : constant Natural := Find_Tree_Item (Items, Path);
   begin
      if Pos = Natural'Last then
         Found := False;
         return Zero_Id;
      end if;

      Found := True;
      return Items.Element (Pos).Id;
   end Tree_Item_Id_For_Path;

   function Object_Content_For_Path
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Found     : out Boolean)
      return String
   is
      Blob_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Item_Id_For_Path
          (Repo      => Repo,
           Commit_Id => Commit_Id,
           Path      => Path,
           Found     => Found);
   begin
      if not Found then
         return "";
      end if;

      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Blob_Id);
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
            raise Ada.IO_Exceptions.Data_Error with
              "conflicted path does not reference blob object: " & Path;
         end if;

         return Version.Objects.Content (Obj);
      end;
   end Object_Content_For_Path;

   function Target_Id_For_Git_State
     (Repo       : Version.Repository.Repository_Handle;
      Target_Ids : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Hex_Object_Id
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      if Target_Ids.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git merge state: MERGE_HEAD";
      elsif Target_Ids.Length = 1 or else Entries.Is_Empty then
         return Target_Ids.First_Element;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if Entries.Element (I).Stage = 3 then
            declare
               Path : constant String :=
                 Ada.Strings.Unbounded.To_String (Entries.Element (I).Path);
            begin
               for J in Target_Ids.First_Index .. Target_Ids.Last_Index loop
                  declare
                     Found : Boolean := False;
                     Id : constant Version.Objects.Hex_Object_Id :=
                       Tree_Item_Id_For_Path
                         (Repo      => Repo,
                          Commit_Id => Target_Ids.Element (J),
                          Path      => Path,
                          Found     => Found);
                  begin
                     if Found and then Id = Entries.Element (I).Id then
                        return Target_Ids.Element (J);
                     end if;
                  end;
               end loop;
            end;
         end if;
      end loop;

      return Target_Ids.First_Element;
   end Target_Id_For_Git_State;

   function Non_Text_Conflict_Has_User_Resolution
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Conflict   : Version.Merge.Conflict)
      return Boolean
   is
      Path : constant String :=
        Ada.Strings.Unbounded.To_String (Conflict.Path);

      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path);

      Current_Found : Boolean := False;
      Target_Found  : Boolean := False;

      Current_Content : constant String :=
        Object_Content_For_Path
          (Repo      => Repo,
           Commit_Id => Current_Id,
           Path      => Path,
           Found     => Current_Found);

      Target_Content : constant String :=
        Object_Content_For_Path
          (Repo      => Repo,
           Commit_Id => Target_Id,
           Path      => Path,
           Found     => Target_Found);
   begin
      Version.Merge.Require_Safe_Path (Path);

      if not Ada.Directories.Exists (Absolute_Path) then
         return True;
      end if;

      if Ada.Directories.Kind (Absolute_Path) /= Ada.Directories.Ordinary_File then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot finalize integration: conflicted path is not a file";
      end if;

      declare
         Content : constant String := Version.Files.Read_Binary_File (Absolute_Path);
      begin
         case Conflict.Kind is
            when Version.Merge.Binary_Conflict =>
               --  Binary conflicts leave the current side in the working tree.
               --  Keeping that byte-for-byte content is unresolved; replacing it
               --  with target bytes, new bytes, or deleting the path is treated
               --  as an explicit user resolution for this phase.
               if Current_Found and then Content = Current_Content then
                  return False;
               end if;

            when Version.Merge.Delete_Modify_Conflict
               | Version.Merge.Directory_File_Conflict =>
               --  These conflict classes write the surviving file side.  Reject
               --  exactly that initial surviving content so finalize cannot pass
               --  immediately without a user decision.
               if Current_Found and then not Target_Found
                 and then Content = Current_Content
               then
                  return False;
               end if;

               if Target_Found and then not Current_Found
                 and then Content = Target_Content
               then
                  return False;
               end if;

               if Current_Found and then Target_Found
                 and then (Content = Current_Content or else Content = Target_Content)
               then
                  return False;
               end if;

            when Version.Merge.Content_Conflict | Version.Merge.Add_Add_Conflict =>
               null;
         end case;

         return True;
      end;
   end Non_Text_Conflict_Has_User_Resolution;

   procedure Require_Conflicted_Path_Resolved
     (Repo       : Version.Repository.Repository_Handle;
      Current_Id : Version.Objects.Hex_Object_Id;
      Target_Id  : Version.Objects.Hex_Object_Id;
      Conflict   : Version.Merge.Conflict)
   is
      Relative_Path : constant String :=
        Ada.Strings.Unbounded.To_String (Conflict.Path);

      Absolute_Path : constant String :=
        Version.Files.Join
          (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Version.Merge.Require_Safe_Path (Relative_Path);

      if File_Contains_Conflict_Marker (Absolute_Path) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot finalize integration: conflict markers remain";
      end if;

      case Conflict.Kind is
         when Version.Merge.Content_Conflict | Version.Merge.Add_Add_Conflict =>
            null;

         when Version.Merge.Binary_Conflict
            | Version.Merge.Delete_Modify_Conflict
            | Version.Merge.Directory_File_Conflict =>
            if not Non_Text_Conflict_Has_User_Resolution
                     (Repo       => Repo,
                      Current_Id => Current_Id,
                      Target_Id  => Target_Id,
                      Conflict   => Conflict)
            then
               raise Ada.IO_Exceptions.Data_Error with
                 "cannot finalize integration: non-text conflict remains unresolved";
            end if;
      end case;
   end Require_Conflicted_Path_Resolved;

   procedure Build_Index_From_Working_Tree
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Version.Staging.Index_Entry_Vectors.Vector)
   is
      Files : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);
   begin
      if not Files.Is_Empty then
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               File_Item : constant Version.Working_Tree.Working_File :=
                 Files.Element (I);

               Relative_Path : constant String :=
                 Ada.Strings.Unbounded.To_String (File_Item.Path);

               Absolute_Path : constant String :=
                 Version.Files.Join
                   (Version.Repository.Root_Path (Repo), Relative_Path);

               Content : constant String :=
                 Version.Files.Read_Binary_File (Absolute_Path);

               Blob_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Blob (Repo => Repo, Content => Content);
            begin
               Result.Append
                 (Version.Staging.Index_Entry'
                    (Path  => File_Item.Path,
                     Id    => Blob_Id,
                     Mode  =>
                       Ada.Strings.Unbounded.To_Unbounded_String ("100644"),
                     Stage => 0));
            end;
         end loop;
      end if;
   end Build_Index_From_Working_Tree;

   procedure Write_Auto_Merge_From_Working_Tree
     (Repo : Version.Repository.Repository_Handle)
   is
      Index_Items : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Build_Index_From_Working_Tree (Repo => Repo, Result => Index_Items);

      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index
             (Repo => Repo, Entries => Index_Items);
      begin
         Version.Files.Write_Binary_File_Atomic
           (Path    => Join (Version.Repository.Git_Dir (Repo), "AUTO_MERGE"),
            Content => To_String (Tree_Id) & Character'Val (10));
      end;
   end Write_Auto_Merge_From_Working_Tree;

   function Git_State_Path
     (Repo : Version.Repository.Repository_Handle; Name : String) return String is
   begin
      return Join (Version.Repository.Git_Dir (Repo), Name);
   end Git_State_Path;

   function Read_Git_State_Id
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Hex_Object_Id
   is
      Path : constant String := Git_State_Path (Repo, Name);
      Text : constant String :=
        Ada.Strings.Fixed.Trim
          (Version.Files.Read_Binary_File (Path), Ada.Strings.Both);
      LF : constant Character := Character'Val (10);
   begin
      declare
         Line : constant String :=
           (if Ada.Strings.Fixed.Index (Text, String'(1 => LF)) = 0
            then Text
            else Text (Text'First
                 .. Text'First + Ada.Strings.Fixed.Index (Text, String'(1 => LF)) - 2));
      begin
         if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid Git merge state: " & Name;
         end if;

         return Version.Objects.To_Object_Id (Line);
      end;
   end Read_Git_State_Id;

   function Read_Git_State_Ids
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Path : constant String := Git_State_Path (Repo, Name);
      Text : constant String := Version.Files.Read_Binary_File (Path);
      LF : constant Character := Character'Val (10);
      CR : constant Character := Character'Val (13);
      Start : Natural := Text'First;
      Result : Version.Objects.Object_Id_Vectors.Vector;
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;

            if Stop > Start then
               declare
                  Line_Last : Natural := Stop - 1;
               begin
                  if Text (Line_Last) = CR then
                     Line_Last := Line_Last - 1;
                  end if;

                  if Line_Last >= Start then
                     declare
                        Line : constant String := Text (Start .. Line_Last);
                     begin
                        if not Version.Objects.Is_Valid_Hex_Object_Id (Line) then
                           raise Ada.IO_Exceptions.Data_Error with
                             "invalid Git merge state: " & Name;
                        end if;

                        Result.Append (Version.Objects.To_Object_Id (Line));
                     end;
                  end if;
               end;
            end if;

            Start := Stop + 1;
         end;
      end loop;

      if Result.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid Git merge state: " & Name;
      end if;

      return Result;
   end Read_Git_State_Ids;

   function Conflict_Kind_From_Index_Stages
     (Has_Base, Has_Current, Has_Target : Boolean)
      return Version.Merge.Conflict_Kind is
   begin
      if (not Has_Base) and then Has_Current and then Has_Target then
         return Version.Merge.Add_Add_Conflict;
      elsif Has_Base and then (Has_Current xor Has_Target) then
         return Version.Merge.Delete_Modify_Conflict;
      else
         return Version.Merge.Content_Conflict;
      end if;
   end Conflict_Kind_From_Index_Stages;

   procedure Load_Conflicts_From_Index
     (Repo      : Version.Repository.Repository_Handle;
      Conflicts : in out Version.Merge.Conflict_Vectors.Vector)
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Paths : Path_Sets.Set;
   begin
      Conflicts.Clear;

      if Entries.Is_Empty then
         return;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if Entries.Element (I).Stage /= 0 then
            Paths.Include (Ada.Strings.Unbounded.To_String (Entries.Element (I).Path));
         end if;
      end loop;

      if Paths.Is_Empty then
         return;
      end if;

      declare
         Cursor : Path_Sets.Cursor := Paths.First;
      begin
         while Path_Sets.Has_Element (Cursor) loop
            declare
               Path : constant String := Path_Sets.Element (Cursor);
               Has_Base    : constant Boolean :=
                 Version.Staging.Find_Stage_Entry (Entries, Path, 1) /= Natural'Last;
               Has_Current : constant Boolean :=
                 Version.Staging.Find_Stage_Entry (Entries, Path, 2) /= Natural'Last;
               Has_Target  : constant Boolean :=
                 Version.Staging.Find_Stage_Entry (Entries, Path, 3) /= Natural'Last;
            begin
               Conflicts.Append
                 (Version.Merge.Conflict'
                    (Path => Ada.Strings.Unbounded.To_Unbounded_String (Path),
                     Kind => Conflict_Kind_From_Index_Stages
                       (Has_Base, Has_Current, Has_Target)));
            end;

            Path_Sets.Next (Cursor);
         end loop;
      end;
   end Load_Conflicts_From_Index;

   procedure Read_Git_Merge_State
     (Repo          : Version.Repository.Repository_Handle;
      Current_Id    : out Version.Objects.Hex_Object_Id;
      Target_Id     : out Version.Objects.Hex_Object_Id;
      Base_Id       : out Version.Objects.Hex_Object_Id;
      Target_Branch : out Ada.Strings.Unbounded.Unbounded_String;
      Conflicts     : in out Version.Merge.Conflict_Vectors.Vector) is
   begin
      declare
         Target_Ids : constant Version.Objects.Object_Id_Vectors.Vector :=
           Read_Git_State_Ids (Repo, "MERGE_HEAD");
      begin
         Target_Id := Target_Id_For_Git_State
           (Repo => Repo, Target_Ids => Target_Ids);
      end;

      if Ada.Directories.Exists (Git_State_Path (Repo, "ORIG_HEAD")) then
         Current_Id := Read_Git_State_Id (Repo, "ORIG_HEAD");
      else
         Current_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
      end if;

      Base_Id := Version.History.Merge_Base
        (Repo => Repo, Left => Current_Id, Right => Target_Id);
      Target_Branch := Ada.Strings.Unbounded.To_Unbounded_String ("MERGE_HEAD");
      Load_Conflicts_From_Index (Repo => Repo, Conflicts => Conflicts);
   end Read_Git_Merge_State;

   procedure Finalize_Integration (Run_Hooks : Boolean := False) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Current_Id    : Version.Objects.Object_Id_Storage;
      Target_Id     : Version.Objects.Object_Id_Storage;
      Base_Id       : Version.Objects.Object_Id_Storage;
      Target_Branch : Ada.Strings.Unbounded.Unbounded_String;
      Conflicts     : Version.Merge.Conflict_Vectors.Vector;

      Index_Items : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Require_Attached_HEAD ("cannot finalize integration", Repo);

      if Version.Merge_State.State_Exists (Repo) then
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      elsif Version.Merge_State.Git_State_Exists (Repo) then
         Read_Git_Merge_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      else
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      end if;

      if not Conflicts.Is_Empty then
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            Require_Conflicted_Path_Resolved
              (Repo       => Repo,
               Current_Id => Current_Id,
               Target_Id  => Target_Id,
               Conflict   => Conflicts.Element (I));
         end loop;

         Version.Merge.Record_Rerere_Resolutions
           (Repo => Repo, Conflicts => Conflicts);
      elsif Working_Tree_Has_Conflict_Markers (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot finalize integration: conflict markers remain";
      end if;

      Build_Index_From_Working_Tree (Repo => Repo, Result => Index_Items);

      Version.Staging.Write (Repo => Repo, Entries => Index_Items);

      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index
             (Repo => Repo, Entries => Index_Items);

         Target_Text : constant String :=
           Ada.Strings.Unbounded.To_String (Target_Branch);

         Fallback_Message : constant String :=
           "Integrate branch " & Target_Text;
      begin
         if Version.Merge_State.Git_State_Exists (Repo) then
            declare
               Message : constant String :=
                 Version.Merge_State.Git_Message_Text
                   (Repo => Repo, Fallback => Default_Merge_Message (Target_Text));
               Mode : constant String := Version.Merge_State.Git_Mode_Text (Repo);
               Squash_Mode : constant Boolean := Is_Squash_Mode (Mode);
               Target_Ids : Version.Objects.Object_Id_Vectors.Vector;
            begin
               if (not Squash_Mode)
                 and then Ada.Directories.Exists (Git_State_Path (Repo, "MERGE_HEAD"))
               then
                  Target_Ids := Read_Git_State_Ids (Repo, "MERGE_HEAD");
               end if;

               if Target_Ids.Length > 1 then
                  declare
                     Parents : Version.Objects.Object_Id_Vectors.Vector;
                  begin
                     Parents.Append (Current_Id);
                     for I in Target_Ids.First_Index .. Target_Ids.Last_Index loop
                        Parents.Append (Target_Ids.Element (I));
                     end loop;

                     Commit_Merge_Result_With_Parents
                       (Repo           => Repo,
                        Current_Id     => Current_Id,
                        Tree_Id        => Tree_Id,
                        Parents        => Parents,
                        Message        => Message,
                        Reflog_Message => "merge: " & First_Line (Message),
                        Run_Hooks      => Run_Hooks,
                        Signing_Key    => Signing_Key_From_Mode (Mode));
                  end;
               else
                  Commit_Merge_Result
                    (Repo           => Repo,
                     Current_Id     => Current_Id,
                     Target_Id      => Target_Id,
                     Tree_Id        => Tree_Id,
                     Message        => Message,
                     Reflog_Message => "merge: " & First_Line (Message),
                     Squash         => Squash_Mode,
                     Run_Hooks      => Run_Hooks,
                     Signing_Key    => Signing_Key_From_Mode (Mode));
               end if;
            end;
         else
            declare
               Parents : Version.Objects.Object_Id_Vectors.Vector;
            begin
               Parents.Append (Current_Id);
               Parents.Append (Target_Id);

               declare
                  Commit_Id : constant Version.Objects.Hex_Object_Id :=
                    Version.Write.Write_Commit_With_Parents
                      (Repo    => Repo,
                       Tree_Id => Tree_Id,
                       Parents => Parents,
                       Message => Fallback_Message);
               begin
                  Write_Current_Branch_Commit (Repo => Repo, Commit => Commit_Id);

                  Append_HEAD_And_Current_Branch_Reflog
                    (Repo    => Repo,
                     Old_Id  => Current_Id,
                     New_Id  => Commit_Id,
                     Message =>
                       "branch finalize: merge finalized " & Target_Text);
               end;
            end;
         end if;
      end;

      Version.Merge_State.Clear_State (Repo);
      Apply_Merge_Autostash (Repo);
   end Finalize_Integration;

   procedure Delete_Working_File_If_Present
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String)
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Relative_Path);
   begin
      Version.Merge.Require_Safe_Path (Relative_Path);

      if Ada.Directories.Exists (Absolute_Path) then
         if Ada.Directories.Kind (Absolute_Path) = Ada.Directories.Ordinary_File then
            Version.Files.Remove_File_If_Safe
              (Repo_Root     => Version.Repository.Root_Path (Repo),
               Relative_Path => Relative_Path);
         else
            raise Ada.IO_Exceptions.Data_Error with
              "cannot remove merge-abort path because it is not a file: "
              & Relative_Path;
         end if;
      end if;
   end Delete_Working_File_If_Present;

   procedure Reset_Working_Tree_Directly_To_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit (Repo => Repo, Commit_Id => Commit_Id);

      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);

      Working_Files : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);

      Wanted_Paths : Path_Sets.Set;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Relative_Path : constant String :=
                 Ada.Strings.Unbounded.To_String (Items.Element (I).Path);
            begin
               Version.Merge.Require_Safe_Path (Relative_Path);
               Wanted_Paths.Include (Relative_Path);
            end;
         end loop;
      end if;

      --  Abort is a reset, not a checkout overlay.  Delete every ordinary
      --  working-tree file that is absent from the saved current-parent tree,
      --  including clean target-side additions written before the merge stopped
      --  on a conflict.  This does not rely on the current index, because a
      --  conflicted integration intentionally leaves the index at the pre-merge
      --  parent while still mutating the worktree.
      if not Working_Files.Is_Empty then
         for I in Working_Files.First_Index .. Working_Files.Last_Index loop
            declare
               Relative_Path : constant String :=
                 Ada.Strings.Unbounded.To_String (Working_Files.Element (I).Path);
            begin
               Version.Merge.Require_Safe_Path (Relative_Path);

               if not Wanted_Paths.Contains (Relative_Path) then
                  Delete_Working_File_If_Present
                    (Repo          => Repo,
                     Relative_Path => Relative_Path);
               end if;
            end;
         end loop;
      end if;

      --  Re-materialize every tracked blob from the saved current parent.  This
      --  overwrites conflict-marker files with the exact committed bytes, so the
      --  result is independent of conflict marker parsing and independent of the
      --  order in which the failed merge wrote paths.
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Version.Objects.Tree_Entry := Items.Element (I);
               Relative_Path : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Path);
               Mode_Text : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Mode);
            begin
               Version.Merge.Require_Safe_Path (Relative_Path);

               if Item.Kind /= Version.Objects.Tree_Gitlink
                 and then Mode_Text /= "160000"
               then
                  declare
                     Blob : constant Version.Objects.Git_Object :=
                       Version.Objects.Read_Object (Repo, Item.Id);
                  begin
                     if Version.Objects.Kind (Blob) /= Version.Objects.Blob_Object then
                        raise Ada.IO_Exceptions.Data_Error with
                          "merge-abort reset path is not a blob: " & Relative_Path;
                     end if;

                     Version.Files.Write_Binary_File_Atomic
                       (Path    => Version.Files.Join
                          (Version.Repository.Root_Path (Repo), Relative_Path),
                        Content => Version.Objects.Content (Blob));
                  end;
               end if;
            end;
         end loop;
      end if;
   end Reset_Working_Tree_Directly_To_Commit;

   procedure Abort_Integration is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Current_Id    : Version.Objects.Object_Id_Storage;
      Target_Id     : Version.Objects.Object_Id_Storage;
      Base_Id       : Version.Objects.Object_Id_Storage;
      Target_Branch : Ada.Strings.Unbounded.Unbounded_String;
      Conflicts     : Version.Merge.Conflict_Vectors.Vector;
   begin
      Require_Attached_HEAD ("cannot abort integration", Repo);

      if Version.Merge_State.State_Exists (Repo) then
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      elsif Version.Merge_State.Git_State_Exists (Repo) then
         Read_Git_Merge_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      else
         Version.Merge_State.Read_State
           (Repo          => Repo,
            Current_Id    => Current_Id,
            Target_Id     => Target_Id,
            Base_Id       => Base_Id,
            Target_Branch => Target_Branch,
            Conflicts     => Conflicts);
      end if;

      --  Abort must be equivalent to a hard reset to the saved current parent
      --  recorded before integration began.  Keep the branch ref, index, and
      --  worktree all on that exact commit; do not derive current-parent bytes
      --  from conflict markers or from the target branch.
      Write_Current_Branch_Commit (Repo => Repo, Commit => Current_Id);

      Reset_Working_Tree_Directly_To_Commit
        (Repo      => Repo,
         Commit_Id => Current_Id);

      Version.Restore.Write_Index_For_Commit
        (Repo      => Repo,
         Commit_Id => Current_Id);

      --  Re-run the direct reset after writing the index.  Index writing records
      --  file stat data from the current worktree; keeping the direct reset last
      --  guarantees conflict-marker files and target-only additions cannot be
      --  left behind by any helper that treats checkout as an overlay.
      Reset_Working_Tree_Directly_To_Commit
        (Repo      => Repo,
         Commit_Id => Current_Id);

      Version.Restore.Write_Index_For_Commit
        (Repo      => Repo,
         Commit_Id => Current_Id);

      Version.Merge_State.Clear_State (Repo);
      Apply_Merge_Autostash (Repo);
   end Abort_Integration;

   procedure Quit_Integration is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Store_Merge_Autostash (Repo);
      Version.Merge_State.Clear_State (Repo);
   end Quit_Integration;

   function Current_Branch_Name return String is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      return Version.Refs.Current_Branch_Name (Repo);
   end Current_Branch_Name;

   function Current_Branch_Text return String is
   begin
      return Current_Branch_Name & Character'Val (10);
   end Current_Branch_Text;

   function Branch_Exists
     (Name : String)
      return Boolean
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      return Branch_Exists (Repo => Repo, Name => Name);
   end Branch_Exists;

   function Resolve_Branch
     (Name : String)
      return Version.Objects.Hex_Object_Id
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      return Branch_Commit_Id (Repo => Repo, Name => Name);
   end Resolve_Branch;

   function Resolve_Branch_Text
     (Name : String)
      return String
   is
   begin
      return To_String (Resolve_Branch (Name)) & Character'Val (10);
   end Resolve_Branch_Text;

   procedure Sort_Branch_Names
     (Branches : in out Version.Refs.Branch_Name_Vectors.Vector)
   is
      use Ada.Strings.Unbounded;
   begin
      --  Keep script-facing output deterministic and aligned with branch list.
      if Branches.Length >= 2 then
         declare
            Swapped : Boolean := True;
         begin
            while Swapped loop
               Swapped := False;

               for J in Branches.First_Index .. Branches.Last_Index - 1 loop
                  if To_String (Branches.Element (J))
                    > To_String (Branches.Element (J + 1))
                  then
                     declare
                        Temp : constant Unbounded_String := Branches.Element (J);
                     begin
                        Branches.Replace_Element (J, Branches.Element (J + 1));
                        Branches.Replace_Element (J + 1, Temp);
                        Swapped := True;
                     end;
                  end if;
               end loop;
            end loop;
         end;
      end if;
   end Sort_Branch_Names;

   function Spaces (Count : Natural) return String is
   begin
      if Count = 0 then
         return "";
      else
         return [1 .. Count => ' '];
      end if;
   end Spaces;

   function List_Branches_Verbose_Text return String is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Head : constant Version.Refs.Head_Info :=
        Version.Refs.Read_Head (Repo);

      Current : constant String :=
        (if Version.Refs.Is_Attached (Head)
         then Version.Refs.Branch_Name (Head)
         else "");

      Branches : Version.Refs.Branch_Name_Vectors.Vector :=
        Version.Refs.List_Branches (Repo);

      Max_Name_Length : Natural := 0;
      Text            : Unbounded_String;
   begin
      Sort_Branch_Names (Branches);

      if Branches.Is_Empty then
         return "No branches" & Character'Val (10);
      end if;

      for I in Branches.First_Index .. Branches.Last_Index loop
         declare
            Name : constant String := To_String (Branches.Element (I));
         begin
            if Name'Length > Max_Name_Length then
               Max_Name_Length := Name'Length;
            end if;
         end;
      end loop;

      for I in Branches.First_Index .. Branches.Last_Index loop
         declare
            Name : constant String := To_String (Branches.Element (I));
            Tip  : constant Version.Objects.Hex_Object_Id :=
              Branch_Commit_Id (Repo => Repo, Name => Name);
            Obj  : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Tip);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
               raise Ada.IO_Exceptions.Data_Error with
                 "branch does not point to a commit: " & Name;
            end if;

            Append (Text, (if Name = Current then "* " else "  "));
            Append (Text, Name);
            Append (Text, Spaces (Max_Name_Length - Name'Length + 2));
            Append (Text, Short_Id (To_String (Tip)));
            Ada.Strings.Unbounded.Append (Text, " ");
            Append (Text, Version.Objects.Commit_Message_First_Line (Obj));
            Append (Text, Character'Val (10));
         end;
      end loop;

      return Ada.Strings.Unbounded.To_String (Text);
   end List_Branches_Verbose_Text;

   function Upstream_Text
     (Name : String := "")
      return String
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Branch_Name : constant String :=
        (if Name = "" then Version.Refs.Current_Branch_Name (Repo) else Name);
   begin
      if not Is_Valid_Branch_Name (Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name: " & Branch_Name;
      end if;

      if not Branch_Exists (Repo => Repo, Name => Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "branch does not exist: " & Branch_Name;
      end if;

      declare
         Info       : constant Version.Tracking.Upstream_Info :=
           Version.Tracking.Upstream (Repo => Repo, Branch_Name => Branch_Name);
         Remote     : constant String := To_String (Info.Remote);
         Merge_Ref  : constant String := To_String (Info.Merge);
         Prefix     : constant String := "refs/heads/";
         Remote_Branch : constant String :=
           Merge_Ref (Merge_Ref'First + Prefix'Length .. Merge_Ref'Last);
      begin
         return Remote & "/" & Remote_Branch & Character'Val (10);
      end;
   end Upstream_Text;

   function Branches_Containing_Text
     (Revision : String)
      return String
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Target_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo => Repo, Text => Revision);

      Branches : Version.Refs.Branch_Name_Vectors.Vector :=
        Version.Refs.List_Branches (Repo);

      Text : Unbounded_String;
   begin
      Sort_Branch_Names (Branches);

      if not Branches.Is_Empty then
         for I in Branches.First_Index .. Branches.Last_Index loop
            declare
               Name : constant String := To_String (Branches.Element (I));
               Tip  : constant Version.Objects.Hex_Object_Id :=
                 Branch_Commit_Id (Repo => Repo, Name => Name);
            begin
               if Version.History.Is_Ancestor
                    (Repo       => Repo,
                     Base_Id    => Target_Id,
                     Derived_Id => Tip)
               then
                  Append (Text, Name);
                  Append (Text, Character'Val (10));
               end if;
            end;
         end loop;
      end if;

      return Ada.Strings.Unbounded.To_String (Text);
   end Branches_Containing_Text;

   function Merged_Branches_Text
     (Base_Branch : String := "")
      return String
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Branches : Version.Refs.Branch_Name_Vectors.Vector :=
        Version.Refs.List_Branches (Repo);

      Text : Unbounded_String;
   begin
      if Base_Branch /= ""
        and then not Is_Valid_Branch_Name (Base_Branch)
      then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name: " & Base_Branch;
      end if;

      declare
         Base_Id : constant Version.Objects.Hex_Object_Id :=
           (if Base_Branch = ""
            then Version.Objects.To_Object_Id
                   (Version.Refs.Current_Commit_Id (Repo))
            else Branch_Commit_Id (Repo => Repo, Name => Base_Branch));
      begin
         Sort_Branch_Names (Branches);

         if not Branches.Is_Empty then
            for I in Branches.First_Index .. Branches.Last_Index loop
               declare
                  Name : constant String := To_String (Branches.Element (I));
                  Tip  : constant Version.Objects.Hex_Object_Id :=
                    Branch_Commit_Id (Repo => Repo, Name => Name);
               begin
                  if Version.History.Is_Ancestor
                       (Repo       => Repo,
                        Base_Id    => Tip,
                        Derived_Id => Base_Id)
                  then
                     Append (Text, Name);
                     Append (Text, Character'Val (10));
                  end if;
               end;
            end loop;
         end if;
      end;

      return Ada.Strings.Unbounded.To_String (Text);
   end Merged_Branches_Text;

   function Unmerged_Branches_Text
     (Base_Branch : String := "")
      return String
   is
      use Ada.Strings.Unbounded;

      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Branches : Version.Refs.Branch_Name_Vectors.Vector :=
        Version.Refs.List_Branches (Repo);

      Text : Unbounded_String;
   begin
      if Base_Branch /= ""
        and then not Is_Valid_Branch_Name (Base_Branch)
      then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name: " & Base_Branch;
      end if;

      declare
         Base_Id : constant Version.Objects.Hex_Object_Id :=
           (if Base_Branch = ""
            then Version.Objects.To_Object_Id
                   (Version.Refs.Current_Commit_Id (Repo))
            else Branch_Commit_Id (Repo => Repo, Name => Base_Branch));
      begin
         Sort_Branch_Names (Branches);

         if not Branches.Is_Empty then
            for I in Branches.First_Index .. Branches.Last_Index loop
               declare
                  Name : constant String := To_String (Branches.Element (I));
                  Tip  : constant Version.Objects.Hex_Object_Id :=
                    Branch_Commit_Id (Repo => Repo, Name => Name);
               begin
                  if not Version.History.Is_Ancestor
                       (Repo       => Repo,
                        Base_Id    => Tip,
                        Derived_Id => Base_Id)
                  then
                     Append (Text, Name);
                     Append (Text, Character'Val (10));
                  end if;
               end;
            end loop;
         end if;
      end;

      return Ada.Strings.Unbounded.To_String (Text);
   end Unmerged_Branches_Text;

end Version.Branch;
