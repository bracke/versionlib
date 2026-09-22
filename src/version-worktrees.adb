with Ada.Directories; use Ada.Directories;
with Ada.Containers; use Ada.Containers;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Files;
with Version.Objects;
with Version.Platform;
with Version.Refs;
with Version.Ref_Names;
with Version.Repository;
with Version.Restore;
with Version.Revisions;
with Version.Status;
with Version.Merge_State;
with Version.Rebase_State;
with Version.Cherry_Pick_State;
with Version.Revert_State;
with Version.Transport.Local;
with Version.Hooks;

package body Version.Worktrees is
   use Version.Objects;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Native (Path : String) return String
   renames Version.Files.To_Native_Path;

   function Abs_Path (Path : String) return String is
   begin
      if Path'Length > 0
        and then
          (Path (Path'First) = '/'
           or else Version.Platform.Is_Windows_Drive_Path (Path))
      then
         return Version.Files.Normalize_Separators (Path);
      else
         return
           Version.Files.Normalize_Separators
             (Ada.Directories.Full_Name (Native (Path)));
      end if;
   exception
      when others =>
         return
           Version.Files.Normalize_Separators
             (Join (Version.Files.Current_Directory, Path));
   end Abs_Path;

   function Base_Name (Path : String) return String is
      P    : constant String := Version.Files.Normalize_Separators (Path);
      Last : Natural := P'Last;
   begin
      if P'Length = 0 then
         return "";
      end if;

      while Last >= P'First and then P (Last) = '/' loop
         if Last = P'First then
            return "";
         end if;
         Last := Last - 1;
      end loop;

      for I in reverse P'First .. Last loop
         if P (I) = '/' then
            return P (I + 1 .. Last);
         end if;
      end loop;
      return P (P'First .. Last);
   end Base_Name;

   function Worktrees_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Join (Version.Repository.Common_Git_Dir (Repo), "worktrees");
   end Worktrees_Dir;

   function Primary_Worktree_Path
     (Repo : Version.Repository.Repository_Handle) return String
   is
      Common : constant String := Version.Repository.Common_Git_Dir (Repo);
   begin
      if Base_Name (Common) = ".git" then
         return
           Version.Files.Normalize_Separators
             (Ada.Directories.Containing_Directory (Native (Common)));
      else
         return Version.Repository.Root_Path (Repo);
      end if;
   end Primary_Worktree_Path;

   function Is_Empty_Directory (Path : String) return Boolean is
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Native (Path),
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => True]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Dir_Entry);
         begin
            if Name /= "." and then Name /= ".." then
               Ada.Directories.End_Search (Search);
               return False;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return True;
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Is_Empty_Directory;

   procedure Require_Safe_Path_Text (Path : String; Context : String) is
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Context & ": empty path";
      end if;
      for C of Path loop
         if Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            raise Ada.IO_Exceptions.Data_Error
              with Context & ": control character in path";
         end if;
      end loop;
      if Ada.Strings.Fixed.Index (Path, "/../") /= 0
        or else Ada.Strings.Fixed.Index (Path, "//") /= 0
      then
         raise Ada.IO_Exceptions.Data_Error with Context & ": unsafe path";
      end if;
   end Require_Safe_Path_Text;

   function Unique_Admin_Name
     (Repo : Version.Repository.Repository_Handle; Path : String) return String
   is
      Base : constant String := Base_Name (Path);
      Root : constant String := Worktrees_Dir (Repo);
   begin
      Require_Safe_Path_Text (Base, "worktree name");
      if Base = "." or else Base = ".." or else Base = ".git" then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid worktree name: " & Base;
      end if;

      if not Ada.Directories.Exists (Native (Join (Root, Base))) then
         return Base;
      end if;

      for N in 1 .. 9999 loop
         declare
            Candidate : constant String :=
              Base
              & "-"
              & Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Left);
         begin
            if not Ada.Directories.Exists (Native (Join (Root, Candidate)))
            then
               return Candidate;
            end if;
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error
        with "could not allocate worktree metadata name";
   end Unique_Admin_Name;

   function Read_HEAD_File (Git_Dir : String) return String is
   begin
      return
        Ada.Strings.Fixed.Trim
          (Version.Transport.Local.Read_First_Line (Join (Git_Dir, "HEAD")),
           Ada.Strings.Both);
   end Read_HEAD_File;

   function Head_Branch_Or_Detached (Git_Dir : String) return Worktree_Info is
      Line   : constant String := Read_HEAD_File (Git_Dir);
      Prefix : constant String := "ref: refs/heads/";
   begin
      if Line'Length >= Prefix'Length
        and then Line (Line'First .. Line'First + Prefix'Length - 1) = Prefix
      then
         return
           (Path     => Null_Unbounded_String,
            Branch   =>
              To_Unbounded_String
                (Line (Line'First + Prefix'Length .. Line'Last)),
            Detached => False,
            Current  => False,
            Missing  => False,
            Locked   => False,
            Lock_Reason => Null_Unbounded_String,
            Head     => Null_Unbounded_String);
      else
         return
           (Path     => Null_Unbounded_String,
            Branch   => To_Unbounded_String (Line),
            Detached => True,
            Current  => False,
            Missing  => False,
            Locked   => False,
            Lock_Reason => Null_Unbounded_String,
            Head     => To_Unbounded_String (Line));
      end if;
   end Head_Branch_Or_Detached;

   procedure Append_Info
     (Result          : in out Worktree_Info_Vectors.Vector;
      Path            : String;
      Git_Dir         : String;
      Current_Git_Dir : String;
      Linked          : Boolean)
   is
      Info : Worktree_Info := Head_Branch_Or_Detached (Git_Dir);
   begin
      Info.Path :=
        To_Unbounded_String (Version.Files.Normalize_Separators (Path));
      Info.Current :=
        Version.Files.Normalize_Separators (Git_Dir)
        = Version.Files.Normalize_Separators (Current_Git_Dir);
      --  git calls an entry prunable when the `.git` file its gitdir names
      --  is gone, not merely when the directory is.
      Info.Missing :=
        Linked and then not Version.Files.Is_Ordinary_File (Join (Path, ".git"));
      Info.Locked  := Version.Files.Is_Ordinary_File (Join (Git_Dir, "locked"));
      if Info.Locked then
         declare
            Raw  : constant String :=
              Version.Files.Read_Binary_File (Join (Git_Dir, "locked"));
            Last : Natural := Raw'Last;
         begin
            while Last >= Raw'First
              and then Raw (Last) in Character'Val (10) | Character'Val (13)
            loop
               Last := Last - 1;
            end loop;
            Info.Lock_Reason :=
              To_Unbounded_String (Raw (Raw'First .. Last));
         exception
            when others =>
               Info.Lock_Reason := Null_Unbounded_String;
         end;
      end if;

      --  An attached worktree's HEAD is whatever its branch points at; the
      --  branch itself lives in the common git dir, so the caller's handle
      --  resolves it.
      if not Info.Detached and then Length (Info.Branch) > 0 then
         begin
            Info.Head := To_Unbounded_String
              (Version.Objects.To_String
                 (Version.Refs.Resolve_Ref
                    (Version.Repository.Open,
                     "refs/heads/" & To_String (Info.Branch))));
         exception
            when others =>
               null;
         end;
      end if;

      --  An unborn branch has no commit; git still reports a HEAD for the
      --  entry, as the null object id.
      if Length (Info.Head) = 0 then
         Info.Head := To_Unbounded_String
           (Version.Objects.To_String (Version.Objects.Zero_Object_Id));
      end if;

      Result.Append (Info);
   exception
      when others =>
         null;
   end Append_Info;

   function Same_Path (Left, Right : String) return Boolean is
   begin
      return
        Version.Files.Normalize_Separators (Left)
        = Version.Files.Normalize_Separators (Right);
   end Same_Path;

   procedure For_Each_Linked
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Worktree_Info_Vectors.Vector)
   is
      Root      : constant String := Worktrees_Dir (Repo);
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Native (Root)) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Native (Root),
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name  : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Admin : constant String :=
              Version.Files.Normalize_Separators
                (Ada.Directories.Full_Name (Dir_Entry));
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Gitdir_File : constant String := Join (Admin, "gitdir");
               begin
                  if Version.Files.Is_Ordinary_File (Gitdir_File) then
                     declare
                        Dot_Git_Path : constant String :=
                          Ada.Strings.Fixed.Trim
                            (Version.Transport.Local.Read_First_Line
                               (Gitdir_File),
                             Ada.Strings.Both);
                     begin
                        declare
                           Work_Path : constant String :=
                             Version.Files.Normalize_Separators
                               (Ada.Directories.Containing_Directory
                                  (Native (Dot_Git_Path)));
                        begin
                           --  git lists every administrative entry that has
                           --  a gitdir file; whether the worktree points
                           --  back is what `repair` is for, not a reason to
                           --  hide the entry.
                           Append_Info
                             (Result          => Result,
                              Path            => Work_Path,
                              Git_Dir         => Admin,
                              Current_Git_Dir =>
                                Version.Repository.Git_Dir (Repo),
                              Linked          => True);
                        end;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end For_Each_Linked;

   function List return Worktree_Info_Vectors.Vector is
      Repo   : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Result : Worktree_Info_Vectors.Vector;
   begin
      Append_Info
        (Result          => Result,
         Path            => Primary_Worktree_Path (Repo),
         Git_Dir         => Version.Repository.Common_Git_Dir (Repo),
         Current_Git_Dir => Version.Repository.Git_Dir (Repo),
         Linked          => False);
      For_Each_Linked (Repo, Result);
      return Result;
   end List;

   function Worktree_Status_Markers (Item : Worktree_Info) return String is
      Text : Unbounded_String := Null_Unbounded_String;

      procedure Add (Marker : String) is
      begin
         if Length (Text) > 0 then
            Append (Text, " ");
         end if;
         Append (Text, Marker);
      end Add;
   begin
      if Item.Current and then not Item.Missing then
         Add ("current");
      end if;

      if Item.Current then
         Add ("primary");
      else
         Add ("linked");
      end if;

      if Item.Missing then
         Add ("missing");
      end if;

      if Item.Detached then
         Add ("detached");
      elsif not Item.Current then
         Add ("branch-in-use");
      end if;

      return To_String (Text);
   end Worktree_Status_Markers;

   function Short_Id (Id : String) return String is
   begin
      if Id'Length > 12 then
         return Id (Id'First .. Id'First + 11);
      else
         return Id;
      end if;
   end Short_Id;

   function Worktree_Status_Line (Item : Worktree_Info) return String is
      Path      : constant String := To_String (Item.Path);
      Name      : constant String := To_String (Item.Branch);
      Head_Text : constant String :=
        (if Item.Detached
         then "detached " & Short_Id (Name)
         else "branch " & Name);
   begin
      return Path & " [" & Worktree_Status_Markers (Item) & "] " & Head_Text;
   end Worktree_Status_Line;

   function Current_Worktree_Text return String is
      Repo      : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Head      : constant Version.Refs.Head_Info :=
        Version.Refs.Read_Head (Repo);
      Kind      : constant String :=
        (if Version.Repository.Is_Linked_Worktree (Repo)
         then "linked"
         else "primary");
      Head_Text : constant String :=
        (if Version.Refs.Is_Detached (Head)
         then "detached " & Short_Id (Version.Refs.Commit_Id (Head))
         else "branch " & Version.Refs.Branch_Name (Head));
   begin
      return
        Version.Repository.Root_Path (Repo)
        & " [current "
        & Kind
        & "] "
        & Head_Text
        & Character'Val (10);
   end Current_Worktree_Text;

   function Branch_Checked_Out_Elsewhere (Branch : String) return Boolean is
      Items : constant Worktree_Info_Vectors.Vector := List;
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Item : constant Worktree_Info := Items.Element (I);
         begin
            if not Item.Current
              and then not Item.Detached
              and then To_String (Item.Branch) = Branch
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Branch_Checked_Out_Elsewhere;

   procedure Write_Common_Admin
     (Admin_Path : String; Work_Path : String; Common_Dir : String)
   is
      pragma Unreferenced (Common_Dir);
   begin
      Version.Files.Create_Directory_If_Missing (Admin_Path);
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Admin_Path, "gitdir"),
         Content => Join (Work_Path, ".git") & Character'Val (10));
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Admin_Path, "commondir"),
         Content => "../.." & Character'Val (10));
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Work_Path, ".git"),
         Content => "gitdir: " & Admin_Path & Character'Val (10));
   end Write_Common_Admin;

   procedure Checkout_New_Worktree (Path : String) is
      procedure Action is
         Repo   : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         if Commit'Length > 0 then
            Version.Restore.Write_Index_For_Commit
              (Repo      => Repo,
               Commit_Id => Version.Objects.To_Object_Id (Commit));
            Version.Restore.Restore_Working_Tree (Repo);
            Version.Hooks.Run_Post_Checkout
              (Repo   => Repo,
               Old_Id => "0000000000000000000000000000000000000000",
               New_Id => Commit,
               Flag   => "1");
         end if;
      end Action;
   begin
      Version.Files.With_Directory (Path, Action'Access);
   end Checkout_New_Worktree;

   function Is_Inside_Path (Child, Parent : String) return Boolean is
      C : constant String := Version.Files.Normalize_Separators (Child);
      P : constant String := Version.Files.Normalize_Separators (Parent);
   begin
      return
        C'Length > P'Length
        and then C (C'First .. C'First + P'Length - 1) = P
        and then C (C'First + P'Length) = '/';
   end Is_Inside_Path;

   function Is_Admin_Dir_For_Linked_Worktree
     (Repo      : Version.Repository.Repository_Handle;
      Admin     : String;
      Work_Path : String) return Boolean
   is
      Root     : constant String := Worktrees_Dir (Repo);
      Backlink : constant String := Join (Admin, "gitdir");
      Dot_Git  : constant String := Join (Work_Path, ".git");
   begin
      if not Is_Inside_Path (Admin, Root) then
         return False;
      end if;

      if not Version.Files.Is_Ordinary_File (Backlink) then
         return False;
      end if;

      declare
         Recorded : constant String :=
           Ada.Strings.Fixed.Trim
             (Version.Transport.Local.Read_First_Line (Backlink),
              Ada.Strings.Both);
      begin
         return Same_Path (Recorded, Dot_Git);
      end;
   exception
      when others =>
         return False;
   end Is_Admin_Dir_For_Linked_Worktree;

   --  git places no restriction on where a worktree lives: inside the
   --  repository and inside another linked worktree are both accepted, and
   --  both work. Refusing them turned the ordinary `worktree add wt <branch>`
   --  -- the spelling in git's own documentation -- into an error, so the
   --  check is gone rather than narrowed.
   procedure Reject_Nested_Worktree
     (Repo : Version.Repository.Repository_Handle; Work_Path : String)
   is
      pragma Unreferenced (Repo);
      pragma Unreferenced (Work_Path);
   begin
      null;
   end Reject_Nested_Worktree;

   --  Given is the path as the user spelled it: git's refusal quotes that,
   --  not the absolute form it works with.
   procedure Prepare_Target_Directory (Path : String; Given : String) is
   begin
      Require_Safe_Path_Text (Path, "worktree path");
      if Ada.Directories.Exists (Native (Path)) then
         if Ada.Directories.Kind (Native (Path)) /= Ada.Directories.Directory
           or else not Is_Empty_Directory (Path)
         then
            raise Worktree_Error with "'" & Given & "' already exists";
         end if;
      else
         Ada.Directories.Create_Path (Native (Path));
      end if;
   end Prepare_Target_Directory;

   --  Admin_Existed guards the administrative directory of a worktree that
   --  was already there: a refused `add` onto an existing worktree's path
   --  must not take that worktree's entry with it.
   procedure Cleanup_Failed_Add
     (Work_Path      : String;
      Admin_Path     : String;
      Existed_Before : Boolean;
      Admin_Existed  : Boolean) is
   begin
      if not Admin_Existed
        and then Ada.Directories.Exists (Native (Admin_Path))
      then
         begin
            Version.Files.Delete_Directory_Tree_If_Exists (Admin_Path);
         exception
            when others =>
               null;
         end;
      end if;

      if Ada.Directories.Exists (Native (Work_Path)) then
         begin
            if Existed_Before then
               Version.Files.Delete_File_If_Exists (Join (Work_Path, ".git"));
            else
               Version.Files.Delete_Directory_Tree_If_Exists (Work_Path);
            end if;
         exception
            when others =>
               null;
         end;
      end if;
   end Cleanup_Failed_Add;

   procedure Add
     (Path        : String;
      Branch      : String;
      No_Checkout : Boolean := False;
      Force       : Boolean := False)
   is
      Repo           : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work_Path      : constant String := Abs_Path (Path);
      Existed_Before : constant Boolean :=
        Ada.Directories.Exists (Native (Work_Path));
      Admin_Name     : constant String := Unique_Admin_Name (Repo, Work_Path);
      Admin_Path     : constant String :=
        Join (Worktrees_Dir (Repo), Admin_Name);
      Admin_Existed  : constant Boolean :=
        Ada.Directories.Exists (Native (Admin_Path));
      --  Nothing has been created until the target directory is accepted, so
      --  a refusal before that must leave an existing worktree there alone.
      Started        : Boolean := False;
      Ref_Name       : constant String := "refs/heads/" & Branch;
   begin
      Version.Ref_Names.Require_Branch_Name (Branch);
      if not Version.Refs.Ref_Exists (Repo => Repo, Name => Ref_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "branch does not exist: " & Branch;
      end if;
      if not Force
        and then (Branch_Checked_Out_Elsewhere (Branch)
                  or else
                    (not Version.Refs.Is_Detached (Repo)
                     and then Version.Refs.Current_Branch_Name (Repo) = Branch))
      then
         --  git names the worktree that holds it.
         declare
            Where : Unbounded_String;
         begin
            for W of List loop
               if not W.Detached and then To_String (W.Branch) = Branch then
                  Where := W.Path;
               end if;
            end loop;
            raise Worktree_Error with
              "'" & Branch & "' is already used by worktree at '"
              & To_String (Where) & "'";
         end;
      end if;

      Reject_Nested_Worktree (Repo, Work_Path);
      Prepare_Target_Directory (Work_Path, Path);
      Started := True;
      Version.Files.Create_Directory_If_Missing (Admin_Path);
      Write_Common_Admin
        (Admin_Path, Work_Path, Version.Repository.Common_Git_Dir (Repo));
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Admin_Path, "HEAD"),
         Content => "ref: refs/heads/" & Branch & Character'Val (10));
      if not No_Checkout then
         Checkout_New_Worktree (Work_Path);
      end if;
   exception
      when others =>
         if Started then
            Cleanup_Failed_Add
              (Work_Path      => Work_Path,
               Admin_Path     => Admin_Path,
               Existed_Before => Existed_Before,
               Admin_Existed  => Admin_Existed);
         end if;
         raise;
   end Add;

   procedure Add_Detached
     (Path : String; Rev : String; No_Checkout : Boolean := False)
   is
      Repo           : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work_Path      : constant String := Abs_Path (Path);
      Existed_Before : constant Boolean :=
        Ada.Directories.Exists (Native (Work_Path));
      Admin_Name     : constant String := Unique_Admin_Name (Repo, Work_Path);
      Admin_Path     : constant String :=
        Join (Worktrees_Dir (Repo), Admin_Name);
      Admin_Existed  : constant Boolean :=
        Ada.Directories.Exists (Native (Admin_Path));
      --  Nothing has been created until the target directory is accepted, so
      --  a refusal before that must leave an existing worktree there alone.
      Started        : Boolean := False;
      Commit_Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Revisions.Resolve_Commit (Repo => Repo, Text => Rev);
   begin
      Reject_Nested_Worktree (Repo, Work_Path);
      Prepare_Target_Directory (Work_Path, Path);
      Started := True;
      Version.Files.Create_Directory_If_Missing (Admin_Path);
      Write_Common_Admin
        (Admin_Path, Work_Path, Version.Repository.Common_Git_Dir (Repo));
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Admin_Path, "HEAD"),
         Content => To_String (Commit_Id) & Character'Val (10));
      if not No_Checkout then
         Checkout_New_Worktree (Work_Path);
      end if;
   exception
      when others =>
         if Started then
            Cleanup_Failed_Add
              (Work_Path      => Work_Path,
               Admin_Path     => Admin_Path,
               Existed_Before => Existed_Before,
               Admin_Existed  => Admin_Existed);
         end if;
         raise;
   end Add_Detached;

   procedure Add_Orphan
     (Path        : String;
      Branch      : String;
      No_Checkout : Boolean := False)
   is
      pragma Unreferenced (No_Checkout);
      Repo           : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work_Path      : constant String := Abs_Path (Path);
      Existed_Before : constant Boolean :=
        Ada.Directories.Exists (Native (Work_Path));
      Admin_Name     : constant String := Unique_Admin_Name (Repo, Work_Path);
      Admin_Path     : constant String :=
        Join (Worktrees_Dir (Repo), Admin_Name);
      Admin_Existed  : constant Boolean :=
        Ada.Directories.Exists (Native (Admin_Path));
      --  Nothing has been created until the target directory is accepted, so
      --  a refusal before that must leave an existing worktree there alone.
      Started        : Boolean := False;
   begin
      Version.Ref_Names.Require_Branch_Name (Branch);
      if Version.Refs.Ref_Exists (Repo, "refs/heads/" & Branch) then
         raise Worktree_Error with
           "a branch named '" & Branch & "' already exists";
      end if;

      Reject_Nested_Worktree (Repo, Work_Path);
      Prepare_Target_Directory (Work_Path, Path);
      Started := True;
      Version.Files.Create_Directory_If_Missing (Admin_Path);
      Write_Common_Admin
        (Admin_Path, Work_Path, Version.Repository.Common_Git_Dir (Repo));
      --  An unborn branch: HEAD names it, and there is nothing to check out.
      Version.Files.Write_Binary_File_Atomic
        (Path    => Join (Admin_Path, "HEAD"),
         Content => "ref: refs/heads/" & Branch & Character'Val (10));
   exception
      when others =>
         if Started then
            Cleanup_Failed_Add
              (Work_Path      => Work_Path,
               Admin_Path     => Admin_Path,
               Existed_Before => Existed_Before,
               Admin_Existed  => Admin_Existed);
         end if;
         raise;
   end Add_Orphan;

   procedure Require_No_Operation_State
     (Repo : Version.Repository.Repository_Handle) is
   begin
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot remove worktree: merge in progress";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot remove worktree: rebase in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot remove worktree: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot remove worktree: revert in progress";
      end if;
   end Require_No_Operation_State;

   procedure Require_Clean (Path : String; Given : String) is
      function Has_User_Untracked
        (Items : Version.Status.File_Change_Vectors.Vector) return Boolean
      is
      begin
         if Items.Is_Empty then
            return False;
         end if;

         for I in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (I).Path) /= ".git" then
               return True;
            end if;
         end loop;

         return False;
      end Has_User_Untracked;

      procedure Action is
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         S    : constant Version.Status.Status_Result :=
           Version.Status.Current_Status;
      begin
         Require_No_Operation_State (Repo);
         if not S.Changes.Is_Empty
           or else not S.Staged.Is_Empty
           or else not S.Conflicted.Is_Empty
           or else Has_User_Untracked (S.Untracked)
         then
            raise Worktree_Error with
              "'" & Given & "' contains modified or untracked files, use "
              & "--force to delete it";
         end if;
      end Action;
   begin
      Version.Files.With_Directory (Path, Action'Access);
   end Require_Clean;

   procedure Require_Linked_Common_Dir
     (Caller : Version.Repository.Repository_Handle; Work_Path : String)
   is
      Linked_Common : Unbounded_String := Null_Unbounded_String;

      procedure Action is
         Linked : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         if not Version.Repository.Is_Linked_Worktree (Linked) then
            raise Ada.IO_Exceptions.Data_Error with "not a linked worktree";
         end if;

         Linked_Common :=
           To_Unbounded_String (Version.Repository.Common_Git_Dir (Linked));
      end Action;
   begin
      Version.Files.With_Directory (Work_Path, Action'Access);
      if not Same_Path
               (To_String (Linked_Common),
                Version.Repository.Common_Git_Dir (Caller))
      then
         raise Ada.IO_Exceptions.Data_Error
           with "linked worktree belongs to a different common repository";
      end if;
   end Require_Linked_Common_Dir;

   --  The admin directory .git/worktrees/<name> that belongs to a worktree
   --  path, or "" when the path is not a linked worktree.
   function Admin_Dir_Of (Path : String) return String is
      Caller    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work_Path : constant String := Abs_Path (Path);
      Resolved  : constant String :=
        Version.Repository.Resolve_Git_Dir (Work_Path);
   begin
      if Resolved'Length = 0
        or else Same_Path
                  (Resolved, Version.Repository.Common_Git_Dir (Caller))
      then
         return "";
      end if;
      return Resolved;
   exception
      when others =>
         return "";
   end Admin_Dir_Of;

   function Lock_File_Of (Path : String) return String is
      Admin : constant String := Admin_Dir_Of (Path);
   begin
      return (if Admin'Length = 0 then "" else Join (Admin, "locked"));
   end Lock_File_Of;

   function Is_Locked (Path : String) return Boolean is
      File : constant String := Lock_File_Of (Path);
   begin
      return File'Length > 0 and then Version.Files.Is_Ordinary_File (File);
   end Is_Locked;

   procedure Move (From : String; To : String; Force : Natural := 0) is
      Caller   : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Src      : constant String := Abs_Path (From);
      Dst      : constant String := Abs_Path (To);
      Admin    : constant String := Admin_Dir_Of (From);
   begin
      if Same_Path (Src, Primary_Worktree_Path (Caller)) then
         raise Worktree_Error with "'" & From & "' is a main working tree";
      end if;

      if Admin'Length = 0 then
         raise Worktree_Error with "'" & From & "' is not a working tree";
      end if;

      if Is_Locked (Src) and then Force < 2 then
         declare
            Why : constant String := Lock_Reason (From);
         begin
            raise Worktree_Error with
              (if Why'Length > 0
               then "cannot move a locked working tree, lock reason: " & Why
               else "cannot move a locked working tree;")
              & Character'Val (10)
              & "use 'move -f -f' to override or unlock first";
         end;
      end if;

      if not Ada.Directories.Exists (Native (Src)) then
         raise Worktree_Error with
           "validation failed, cannot move working tree: '" & From
           & "' does not exist";
      end if;

      declare
         --  Like `mv`, an existing-directory destination receives the worktree
         --  under its own name rather than being an error.
         Final_Dst : constant String :=
           (if Ada.Directories.Exists (Native (Dst))
              and then Ada.Directories.Kind (Native (Dst))
                       = Ada.Directories.Directory
            then Join (Dst, Ada.Directories.Simple_Name (Native (Src)))
            else Dst);
      begin
         if Ada.Directories.Exists (Native (Final_Dst)) then
            raise Worktree_Error with "'" & To & "' already exists";
         end if;

         Ada.Directories.Rename
           (Old_Name => Native (Src), New_Name => Native (Final_Dst));

         --  The admin directory keeps its name; its gitdir pointer is what
         --  says where the worktree lives, so that is the only thing to
         --  rewrite.
         Version.Files.Write_Binary_File_Atomic
           (Join (Admin, "gitdir"),
            Join (Final_Dst, ".git") & Character'Val (10));
      end;
   end Move;

   --  The `gitdir: <path>` a .git file names, "" when it names none.
   function Gitdir_Target (Dot_Git : String) return String is
      Tag  : constant String := "gitdir: ";
      Line : constant String :=
        Ada.Strings.Fixed.Trim
          (Version.Transport.Local.Read_First_Line (Dot_Git),
           Ada.Strings.Both);
   begin
      if Line'Length <= Tag'Length
        or else Line (Line'First .. Line'First + Tag'Length - 1) /= Tag
      then
         return "";
      end if;
      return Line (Line'First + Tag'Length .. Line'Last);
   exception
      when others =>
         return "";
   end Gitdir_Target;

   procedure Repair
     (Path    : String;
      Reports : in out Report_Vectors.Vector;
      Errors  : in out Report_Vectors.Vector)
   is
      Caller : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work   : constant String := Abs_Path (Path);
      Dot    : constant String := Join (Work, ".git");
   begin
      if Same_Path (Work, Primary_Worktree_Path (Caller)) then
         return;
      end if;

      if not Ada.Directories.Exists (Native (Work))
        or else Ada.Directories.Kind (Native (Work))
                /= Ada.Directories.Directory
      then
         Errors.Append ("not a valid path: " & Path);
         return;
      end if;

      if not Version.Files.Is_Ordinary_File (Dot) then
         if Ada.Directories.Exists (Native (Dot)) then
            Errors.Append
              ("unable to locate repository; .git is not a file: " & Dot);
         else
            Errors.Append
              ("unable to locate repository; .git file broken: " & Dot);
         end if;
         return;
      end if;

      --  The worktree's own .git file still names its administrative
      --  directory -- that link survives a move, and is what makes the
      --  repair possible at all. Only the pointer back has gone stale.
      declare
         Admin : constant String := Gitdir_Target (Dot);
      begin
         if Admin'Length = 0 or else not Ada.Directories.Exists (Native (Admin))
         then
            Errors.Append
              ("unable to locate repository; .git file does not reference a "
               & "repository: " & Dot);
            return;
         end if;

         --  git only reports the pointer it actually had to correct.
         declare
            Gitdir : constant String := Join (Admin, "gitdir");
            Stale  : constant Boolean :=
              not Version.Files.Is_Ordinary_File (Gitdir)
              or else Ada.Strings.Fixed.Trim
                        (Version.Transport.Local.Read_First_Line (Gitdir),
                         Ada.Strings.Both)
                      /= Dot;
         begin
            if Stale then
               Reports.Append ("repair: gitdir incorrect: " & Gitdir);
               Version.Files.Write_Binary_File_Atomic
                 (Gitdir, Dot & Character'Val (10));
            end if;
         end;
      end;
   end Repair;

   procedure Repair_All
     (Reports : in out Report_Vectors.Vector;
      Errors  : in out Report_Vectors.Vector)
   is
      pragma Unreferenced (Errors);
      Caller    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Root      : constant String := Worktrees_Dir (Caller);
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Native (Root)) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Native (Root),
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name  : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Admin : constant String :=
              Version.Files.Normalize_Separators
                (Ada.Directories.Full_Name (Dir_Entry));
            Gitdir : constant String := Join (Admin, "gitdir");
         begin
            if Name /= "." and then Name /= ".."
              and then Version.Files.Is_Ordinary_File (Gitdir)
            then
               declare
                  Dot : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Gitdir),
                       Ada.Strings.Both);
                  Work : constant String :=
                    Version.Files.Normalize_Separators
                      (Ada.Directories.Containing_Directory (Native (Dot)));
               begin
                  --  A worktree whose directory is gone is prune's business,
                  --  not repair's.
                  if Ada.Directories.Exists (Native (Work))
                    and then (not Version.Files.Is_Ordinary_File (Dot)
                              or else not Same_Path
                                            (Gitdir_Target (Dot), Admin))
                  then
                     Reports.Append ("repair: .git file broken: " & Work);
                     Version.Files.Write_Binary_File_Atomic
                       (Dot, "gitdir: " & Admin & Character'Val (10));
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Repair_All;

   function Lock_Reason (Path : String) return String is
      File : constant String := Lock_File_Of (Path);
   begin
      if File'Length = 0 or else not Version.Files.Is_Ordinary_File (File) then
         return "";
      end if;
      declare
         Raw  : constant String := Version.Files.Read_Binary_File (File);
         Last : Natural := Raw'Last;
      begin
         while Last >= Raw'First
           and then Raw (Last) in Character'Val (10) | Character'Val (13)
         loop
            Last := Last - 1;
         end loop;
         return Raw (Raw'First .. Last);
      end;
   exception
      when others =>
         return "";
   end Lock_Reason;

   --  git refuses to lock or unlock the worktree the repository itself
   --  lives in.
   procedure Require_Linked_For_Lock (Path : String) is
      Caller : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if Same_Path (Abs_Path (Path), Primary_Worktree_Path (Caller)) then
         raise Worktree_Error
           with "The main working tree cannot be locked or unlocked";
      end if;
      if Admin_Dir_Of (Path)'Length = 0 then
         raise Worktree_Error with "'" & Path & "' is not a working tree";
      end if;
   end Require_Linked_For_Lock;

   procedure Lock (Path : String; Reason : String := "") is
      File : constant String := Lock_File_Of (Path);
   begin
      Require_Linked_For_Lock (Path);
      if Version.Files.Is_Ordinary_File (File) then
         declare
            Why : constant String := Lock_Reason (Path);
         begin
            raise Worktree_Error with
              "'" & Path & "' is already locked"
              & (if Why'Length > 0 then ", reason: " & Why else "");
         end;
      end if;

      Version.Files.Write_Binary_File
        (File,
         (if Reason'Length = 0 then "" else Reason & Character'Val (10)));
   end Lock;

   procedure Unlock (Path : String) is
      File : constant String := Lock_File_Of (Path);
   begin
      Require_Linked_For_Lock (Path);
      if not Version.Files.Is_Ordinary_File (File) then
         raise Worktree_Error with "'" & Path & "' is not locked";
      end if;

      Version.Files.Delete_File_If_Exists (File);
   end Unlock;

   function Prunable return Prunable_Vectors.Vector is
      Repo      : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Root      : constant String := Worktrees_Dir (Repo);
      Result    : Prunable_Vectors.Vector;
      Search    : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened    : Boolean := False;
   begin
      if not Ada.Directories.Exists (Native (Root)) then
         return Result;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Native (Root),
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => False,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);
         declare
            Name  : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Admin : constant String :=
              Version.Files.Normalize_Separators
                (Ada.Directories.Full_Name (Dir_Entry));
         begin
            if Name /= "." and then Name /= ".." then
               declare
                  Gitdir_File : constant String := Join (Admin, "gitdir");
               begin
                  if not Version.Files.Is_Ordinary_File (Gitdir_File) then
                     Result.Append
                       (Prunable_Entry'
                          (Name   => To_Unbounded_String (Name),
                           Reason =>
                             To_Unbounded_String ("gitdir file does not exist")));
                  else
                     declare
                        Dot_Git_Path : constant String :=
                          Ada.Strings.Fixed.Trim
                            (Version.Transport.Local.Read_First_Line
                               (Gitdir_File),
                             Ada.Strings.Both);
                     begin
                        if not Ada.Directories.Exists (Native (Dot_Git_Path))
                        then
                           Result.Append
                             (Prunable_Entry'
                                (Name   => To_Unbounded_String (Name),
                                 Reason =>
                                   To_Unbounded_String
                                     ("gitdir file points to non-existent"
                                      & " location")));
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      return Result;
   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
         raise;
   end Prunable;

   procedure Prune is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Root : constant String := Worktrees_Dir (Repo);
   begin
      for Item of Prunable loop
         Version.Files.Delete_Directory_Tree_If_Exists
           (Join (Root, To_String (Item.Name)));
      end loop;
   end Prune;

   procedure Remove (Path : String; Force : Natural := 0) is
      Caller        : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Work_Path     : constant String := Abs_Path (Path);
      Dot_Git       : constant String := Join (Work_Path, ".git");
      Git_Dir_Value : Unbounded_String;
   begin
      if Version.Files.Normalize_Separators (Work_Path)
        = Version.Files.Normalize_Separators (Primary_Worktree_Path (Caller))
      then
         raise Worktree_Error with "'" & Path & "' is a main working tree";
      end if;
      if not Version.Files.Is_Ordinary_File (Dot_Git) then
         --  The directory is gone. Its admin entry is still there holding the
         --  branch checked out, and neither remove nor prune could clear it,
         --  so the only way back was to delete .git/worktrees/<name> by hand.
         if not Ada.Directories.Exists (Native (Work_Path)) then
            declare
               Root  : constant String := Worktrees_Dir (Caller);
               Found : Boolean := False;
            begin
               for Item of Prunable loop
                  declare
                     Admin : constant String :=
                       Join (Root, To_String (Item.Name));
                     Gitdir_File : constant String := Join (Admin, "gitdir");
                  begin
                     if Version.Files.Is_Ordinary_File (Gitdir_File)
                       and then Same_Path
                                  (Ada.Directories.Containing_Directory
                                     (Native
                                        (Ada.Strings.Fixed.Trim
                                           (Version.Transport.Local
                                              .Read_First_Line (Gitdir_File),
                                            Ada.Strings.Both))),
                                   Work_Path)
                     then
                        Version.Files.Delete_Directory_Tree_If_Exists (Admin);
                        Found := True;
                     end if;
                  end;
               end loop;

               if Found then
                  return;
               end if;
            end;
         end if;

         raise Worktree_Error with "'" & Path & "' is not a working tree";
      end if;

      Git_Dir_Value :=
        To_Unbounded_String (Version.Repository.Resolve_Git_Dir (Work_Path));
      if Length (Git_Dir_Value) = 0
        or else
          Same_Path
            (To_String (Git_Dir_Value),
             Version.Repository.Common_Git_Dir (Caller))
        or else
          not Is_Admin_Dir_For_Linked_Worktree
                (Repo      => Caller,
                 Admin     => To_String (Git_Dir_Value),
                 Work_Path => Work_Path)
      then
         raise Ada.IO_Exceptions.Data_Error
           with "not a linked worktree: " & Path;
      end if;

      Require_Linked_Common_Dir (Caller, Work_Path);

      --  A locked worktree is one the user asked not to be touched; saying
      --  the tree is unclean instead names the wrong reason and points at
      --  the wrong remedy.  A second --force (Force) overrides the lock.
      if Is_Locked (Work_Path) and then Force < 2 then
         declare
            Why : constant String := Lock_Reason (Path);
         begin
            raise Worktree_Error with
              (if Why'Length > 0
               then "cannot remove a locked working tree, lock reason: " & Why
               else "cannot remove a locked working tree;")
              & Character'Val (10)
              & "use 'remove -f -f' to override or unlock first";
         end;
      end if;

      --  --force also lets a worktree with local modifications be removed.
      if Force < 1 then
         Require_Clean (Work_Path, Path);
      end if;
      Version.Files.Delete_Directory_Tree_If_Exists (Work_Path);
      if Ada.Directories.Exists (Native (To_String (Git_Dir_Value))) then
         Version.Files.Delete_Directory_Tree_If_Exists
           (To_String (Git_Dir_Value));
      end if;
   end Remove;

end Version.Worktrees;
