with Ada.Characters.Handling;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;

with Version.Config;
with Version.Files;
with Version.Objects;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Revisions;
with Version.Worktrees;

package body Version.Branches is

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Cfg
     (Repo : Version.Repository.Repository_Handle; Key : String) return String is
     (if Version.Config.Has_Key (Repo, Key)
      then Version.Config.Get_Value (Repo, Key) else "");

   function Lower (S : String) return String
     renames Ada.Characters.Handling.To_Lower;

   function Default_Track
     (Repo : Version.Repository.Repository_Handle) return Track_Mode
   is
      V : constant String := Lower (Cfg (Repo, "branch.autoSetupMerge"));
   begin
      if V = "" or else V = "true" or else V = "yes" or else V = "on"
        or else V = "1"
      then
         return Track_Remote;
      elsif V = "false" or else V = "no" or else V = "off" or else V = "0" then
         return Track_Never;
      elsif V = "always" then
         return Track_Always;
      elsif V = "inherit" then
         return Track_Inherit;
      elsif V = "simple" then
         return Track_Simple;
      end if;
      return Track_Remote;
   end Default_Track;

   function Branch_Ref_Of
     (Repo : Version.Repository.Repository_Handle; Spec : String)
      return String is
   begin
      if Starts_With (Spec, "refs/") then
         return (if Version.Refs.Ref_Exists (Repo, Spec) then Spec else "");
      end if;
      if Version.Refs.Ref_Exists (Repo, "refs/heads/" & Spec) then
         return "refs/heads/" & Spec;
      elsif Version.Refs.Ref_Exists (Repo, "refs/remotes/" & Spec) then
         return "refs/remotes/" & Spec;
      end if;
      --  git's dwim_ref follows a symbolic ref, so `--track <new> HEAD`
      --  tracks the branch HEAD points at.
      if Spec = "HEAD" and then not Version.Refs.Is_Detached (Repo) then
         return "refs/heads/" & Version.Refs.Current_Branch_Name (Repo);
      end if;
      return "";
   end Branch_Ref_Of;

   --  The current worktree's checked-out branch ("" when detached).
   function Checked_Out_Here
     (Repo : Version.Repository.Repository_Handle) return String
   is
      H : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      return (if Version.Refs.Is_Attached (H) then Version.Refs.Branch_Name (H)
              else "");
   end Checked_Out_Here;

   --  git's branch_checked_out: the worktree path holding Name, or "".
   function Worktree_Holding
     (Repo : Version.Repository.Repository_Handle; Name : String) return String
   is
   begin
      if Checked_Out_Here (Repo) = Name then
         return Version.Repository.Root_Path (Repo);
      end if;
      for W of Version.Worktrees.List loop
         if not W.Detached and then To_String (W.Branch) = Name then
            return To_String (W.Path);
         end if;
      end loop;
      return "";
   exception
      when others =>
         return "";
   end Worktree_Holding;

   --  git's find_tracked_branch: the remote whose fetch refspec produces
   --  the remote-tracking ref Orig_Ref, and the branch it fetches.
   procedure Find_Tracked
     (Repo     : Version.Repository.Repository_Handle;
      Orig_Ref : String;
      Remote   : out Unbounded_String;
      Source   : out Unbounded_String;
      Matches  : out Natural) is
   begin
      Remote  := Null_Unbounded_String;
      Source  := Null_Unbounded_String;
      Matches := 0;
      for Item of Version.Config.Read_All (Repo) loop
         declare
            Full : constant String := Version.Config.Config_Entry_Name (Item);
            Key  : constant String := Lower (Full);
         begin
            if Starts_With (Key, "remote.")
              and then Key'Length > 13
              and then Key (Key'Last - 5 .. Key'Last) = ".fetch"
            then
               declare
                  Rname : constant String :=
                    Full (Full'First + 7 .. Full'Last - 6);
                  Spec  : String := To_String (Item.Value);
                  Colon : Natural;
               begin
                  if Spec'Length > 0 and then Spec (Spec'First) = '+' then
                     Spec := Spec (Spec'First + 1 .. Spec'Last) & " ";
                  end if;
                  declare
                     S : constant String :=
                       Ada.Strings.Fixed.Trim (Spec, Ada.Strings.Both);
                  begin
                     Colon := Ada.Strings.Fixed.Index (S, ":");
                     if Colon > 0 then
                        declare
                           Src : constant String := S (S'First .. Colon - 1);
                           Dst : constant String := S (Colon + 1 .. S'Last);
                           Star_S : constant Natural :=
                             Ada.Strings.Fixed.Index (Src, "*");
                           Star_D : constant Natural :=
                             Ada.Strings.Fixed.Index (Dst, "*");
                        begin
                           if Star_S > 0 and then Star_D > 0
                             and then Starts_With
                                        (Orig_Ref, Dst (Dst'First .. Star_D - 1))
                           then
                              Matches := Matches + 1;
                              Remote := To_Unbounded_String (Rname);
                              Source := To_Unbounded_String
                                (Src (Src'First .. Star_S - 1)
                                 & Orig_Ref (Orig_Ref'First + (Star_D - Dst'First)
                                             .. Orig_Ref'Last));
                           elsif Star_S = 0 and then Dst = Orig_Ref then
                              Matches := Matches + 1;
                              Remote := To_Unbounded_String (Rname);
                              Source := To_Unbounded_String (Src);
                           end if;
                        end;
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;
   end Find_Tracked;

   --  git's install_branch_config: the config and the line it prints.
   procedure Install_Config
     (Repo   : Version.Repository.Repository_Handle;
      Name   : String;
      Remote : String;
      Source : String;
      Quiet  : Boolean;
      Note   : out Unbounded_String;
      Local  : Boolean := False)
   is
      --  git names a local upstream found by dwim by its short name, but an
      --  inherited "." remote as "./<name>" like any other remote.
      Short : constant String :=
        (if Starts_With (Source, "refs/heads/")
         then Source (Source'First + 11 .. Source'Last) else Source);
      Rebase_Cfg : constant String :=
        Lower (Cfg (Repo, "branch.autoSetupRebase"));
      Rebasing : constant Boolean :=
        Rebase_Cfg = "always"
        or else (Rebase_Cfg = "local" and then Remote = ".")
        or else (Rebase_Cfg = "remote" and then Remote /= ".");
   begin
      Version.Config.Set_Key (Repo, "branch." & Name & ".remote", Remote);
      Version.Config.Set_Key (Repo, "branch." & Name & ".merge", Source);
      if Rebasing then
         Version.Config.Set_Key (Repo, "branch." & Name & ".rebase", "true");
      end if;
      Note := Null_Unbounded_String;
      if not Quiet then
         Note := To_Unbounded_String
           ("branch '" & Name & "' set up to track '"
            & (if Local then Short else Remote & "/" & Short) & "'"
            & (if Rebasing then " by rebasing." else "."));
      end if;
   end Install_Config;

   procedure Setup_Tracking
     (Repo     : Version.Repository.Repository_Handle;
      Name     : String;
      Orig_Ref : String;
      Track    : Track_Mode;
      Quiet    : Boolean;
      Note     : out Unbounded_String;
      Warning  : out Unbounded_String)
   is
      Remote, Source : Unbounded_String;
      Matches        : Natural;
   begin
      Note := Null_Unbounded_String;
      Warning := Null_Unbounded_String;
      if Track = Track_Inherit then
         --  Copy the start branch's own upstream.
         declare
            Short : constant String :=
              (if Starts_With (Orig_Ref, "refs/heads/")
               then Orig_Ref (Orig_Ref'First + 11 .. Orig_Ref'Last)
               else Orig_Ref);
            R : constant String := Cfg (Repo, "branch." & Short & ".remote");
            M : constant String := Cfg (Repo, "branch." & Short & ".merge");
         begin
            if R = "" or else M = "" then
               --  git warns and sets nothing up.
               Warning := To_Unbounded_String
                 ("asked to inherit tracking from '" & Short
                  & "', but no remote is set");
               return;
            end if;
            Install_Config (Repo, Name, R, M, Quiet, Note);
            return;
         end;
      end if;

      Find_Tracked (Repo, Orig_Ref, Remote, Source, Matches);
      if Matches = 0 then
         case Track is
            when Track_Always | Track_Explicit =>
               null;
            when others =>
               return;   --  a local start point sets nothing up
         end case;
         --  A local branch is tracked through the "." remote.
         Remote := To_Unbounded_String (".");
         Source := To_Unbounded_String (Orig_Ref);
      elsif Matches > 1 then
         raise Branch_Error with
           "not tracking: ambiguous information for ref '" & Orig_Ref & "'";
      end if;

      if Track = Track_Simple then
         --  Only a remote branch of the same name.
         declare
            S : constant String := To_String (Source);
         begin
            if To_String (Remote) = "." or else not Starts_With (S, "refs/heads/")
              or else S (S'First + 11 .. S'Last) /= Name
            then
               return;
            end if;
         end;
      end if;

      Install_Config
        (Repo, Name, To_String (Remote), To_String (Source), Quiet, Note,
         Local => To_String (Remote) = ".");
   end Setup_Tracking;

   procedure Create
     (Repo       : Version.Repository.Repository_Handle;
      Name       : String;
      Start_Name : String;
      Force      : Boolean;
      Track      : Track_Mode;
      Quiet      : Boolean;
      Reflog     : Boolean;
      Note       : out Unbounded_String;
      Warning    : out Unbounded_String)
   is
      Ref      : constant String := "refs/heads/" & Name;
      Real_Ref : constant String := Branch_Ref_Of (Repo, Start_Name);
      Start_Id : Unbounded_String;
      Old_Id   : Unbounded_String;
      Existed  : Boolean := False;
   begin
      Note := Null_Unbounded_String;
      Warning := Null_Unbounded_String;

      --  git's validate_branch_start.
      begin
         Start_Id := To_Unbounded_String
           (Version.Objects.To_String
              (Version.Revisions.Resolve (Repo, Start_Name)));
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
            raise Branch_Error with
              "not a valid object name: '" & Start_Name & "'";
      end;
      if Track = Track_Explicit and then Real_Ref = "" then
         raise Branch_Error with
           "cannot set up tracking information; starting point '"
           & Start_Name & "' is not a branch";
      end if;
      begin
         Start_Id := To_Unbounded_String
           (Version.Objects.To_String
              (Version.Revisions.Resolve_Commit (Repo, To_String (Start_Id))));
      exception
         when Ada.IO_Exceptions.Data_Error =>
            raise Branch_Error with
              "not a valid branch point: '" & Start_Name & "'";
      end;

      --  git's validate_new_branchname.
      if Name'Length = 0 or else Name (Name'First) = '-'
        or else not Version.Ref_Names.Is_Valid_Branch_Name (Name)
      then
         raise Branch_Error with "'" & Name & "' is not a valid branch name";
      end if;
      if Version.Refs.Ref_Exists (Repo, Ref) then
         Existed := True;
         Old_Id := To_Unbounded_String
           (Version.Objects.To_String (Version.Refs.Resolve_Ref (Repo, Ref)));
         if not Force then
            raise Branch_Error with
              "a branch named '" & Name & "' already exists";
         end if;
         declare
            Path : constant String := Worktree_Holding (Repo, Name);
         begin
            if Path'Length > 0 then
               raise Branch_Error with
                 "cannot force update the branch '" & Name
                 & "' used by worktree at '" & Path & "'";
            end if;
         end;
      end if;

      declare
         Tx  : Version.Ref_Transaction.Transaction;
         Msg : constant String :=
           (if Existed then "branch: Reset to " & Start_Name
            else "branch: Created from " & Start_Name);
         Log_Cfg : constant String := Lower (Cfg (Repo, "core.logAllRefUpdates"));
         Logs : constant Boolean :=
           Reflog or else Log_Cfg = "" or else Log_Cfg = "true"
           or else Log_Cfg = "always" or else Log_Cfg = "yes"
           or else Log_Cfg = "on" or else Log_Cfg = "1";
      begin
         Version.Ref_Transaction.Start (Tx, Repo);
         Version.Ref_Transaction.Add_Update
           (Tx, Ref, Version.Objects.To_Object_Id (To_String (Start_Id)),
            Expected_Old =>
              (if Existed then To_String (Old_Id)
               else "0000000000000000000000000000000000000000"));
         Version.Ref_Transaction.Commit (Tx);
         if Logs then
            Version.Reflog.Append
              (Repo, Ref,
               (if Existed then To_String (Old_Id)
                else "0000000000000000000000000000000000000000"),
               To_String (Start_Id), Msg);
         end if;
      end;

      if Real_Ref'Length > 0 and then Track /= Track_Never then
         Setup_Tracking (Repo, Name, Real_Ref, Track, Quiet, Note, Warning);
      end if;
   end Create;

   procedure Set_Upstream_To
     (Repo     : Version.Repository.Repository_Handle;
      Name     : String;
      Upstream : String;
      Quiet    : Boolean;
      Note     : out Unbounded_String)
   is
      Real_Ref : constant String := Branch_Ref_Of (Repo, Upstream);
      Warning  : Unbounded_String;
   begin
      Note := Null_Unbounded_String;
      if Real_Ref'Length = 0 then
         raise Branch_Error with
           "the requested upstream branch '" & Upstream & "' does not exist";
      end if;
      Setup_Tracking (Repo, Name, Real_Ref, Track_Explicit, Quiet, Note, Warning);
   end Set_Upstream_To;

   function Has_Upstream_Config
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Boolean is
     (Version.Config.Has_Key (Repo, "branch." & Name & ".remote")
      or else Version.Config.Has_Key (Repo, "branch." & Name & ".merge"));

   procedure Unset_Upstream
     (Repo : Version.Repository.Repository_Handle; Name : String) is
   begin
      if not Has_Upstream_Config (Repo, Name) then
         raise Branch_Error with
           "branch '" & Name & "' has no upstream information";
      end if;
      if Version.Config.Has_Key (Repo, "branch." & Name & ".remote") then
         Version.Config.Unset_All (Repo, "branch." & Name & ".remote");
      end if;
      if Version.Config.Has_Key (Repo, "branch." & Name & ".merge") then
         Version.Config.Unset_All (Repo, "branch." & Name & ".merge");
      end if;
   end Unset_Upstream;

   procedure Rename_Or_Copy
     (Repo        : Version.Repository.Repository_Handle;
      Old_Name    : String;
      New_Name    : String;
      Copy        : Boolean;
      Force       : Boolean;
      Head_Branch : String)
   is
      Old_Ref  : constant String := "refs/heads/" & Old_Name;
      New_Ref  : constant String := "refs/heads/" & New_Name;
      Is_Head  : constant Boolean := Head_Branch = Old_Name;
      Old_Exists : constant Boolean := Version.Refs.Ref_Exists (Repo, Old_Ref);
      Log_Msg   : constant String :=
        "Branch: " & (if Copy then "copied " else "renamed ")
        & Old_Ref & " to " & New_Ref;
   begin
      --  A misnamed branch that nonetheless exists may still be renamed
      --  away (git's "recovery"); a bad name that does not is refused.
      if (Old_Name'Length = 0 or else Old_Name (Old_Name'First) = '-'
          or else not Version.Ref_Names.Is_Valid_Branch_Name (Old_Name))
        and then not Old_Exists
      then
         raise Branch_Error with "invalid branch name: '" & Old_Name & "'";
      end if;

      if (Copy or else not Is_Head) and then not Old_Exists then
         if Is_Head then
            raise Branch_Error with "no commit on branch '" & Old_Name & "' yet";
         end if;
         raise Branch_Error with "no branch named '" & Old_Name & "'";
      end if;

      --  git's validate_(new_)branchname on the destination.
      if New_Name'Length = 0 or else New_Name (New_Name'First) = '-'
        or else not Version.Ref_Names.Is_Valid_Branch_Name (New_Name)
      then
         raise Branch_Error with "'" & New_Name & "' is not a valid branch name";
      end if;
      if Old_Name /= New_Name and then Version.Refs.Ref_Exists (Repo, New_Ref) then
         if not Force then
            raise Branch_Error with
              "a branch named '" & New_Name & "' already exists";
         end if;
         declare
            Path : constant String := Worktree_Holding (Repo, New_Name);
         begin
            if Path'Length > 0 then
               raise Branch_Error with
                 "cannot force update the branch '" & New_Name
                 & "' used by worktree at '" & Path & "'";
            end if;
         end;
      end if;

      if Old_Exists then
         declare
            Id : constant Version.Objects.Hex_Object_Id :=
              Version.Refs.Resolve_Ref (Repo, Old_Ref);
            Old_Log : constant String := Version.Reflog.Path (Repo, Old_Ref);
            New_Log : constant String := Version.Reflog.Path (Repo, New_Ref);
            Tx : Version.Ref_Transaction.Transaction;
            Dest_Old : constant String :=
              (if Version.Refs.Ref_Exists (Repo, New_Ref)
               then Version.Objects.To_String
                      (Version.Refs.Resolve_Ref (Repo, New_Ref))
               else "0000000000000000000000000000000000000000");
         begin
            if Old_Name /= New_Name then
               Version.Ref_Transaction.Start (Tx, Repo);
               Version.Ref_Transaction.Add_Update (Tx, New_Ref, Id, Dest_Old);
               if not Copy then
                  Version.Ref_Transaction.Add_Delete
                    (Tx, Old_Ref, Version.Objects.To_String (Id));
               end if;
               Version.Ref_Transaction.Commit (Tx);

               --  The reflog travels with the branch (git's rename_ref
               --  moves it, copy_existing_ref copies it) ...
               if Ada.Directories.Exists (Old_Log) then
                  Version.Files.Create_Parent_Directories (New_Log);
                  if Copy then
                     Version.Files.Write_Binary_File
                       (New_Log, Version.Files.Read_Binary_File (Old_Log));
                  else
                     Version.Files.Delete_File_If_Exists (New_Log);
                     Ada.Directories.Rename (Old_Log, New_Log);
                  end if;
               end if;
            end if;
            --  ... and records the move.
            Version.Reflog.Append
              (Repo, New_Ref, Version.Objects.To_String (Id),
               Version.Objects.To_String (Id), Log_Msg);
         end;
      end if;

      if not Copy and then Is_Head and then Old_Name /= New_Name then
         Version.Refs.Write_Symbolic_HEAD (Repo, New_Ref);
         if Old_Exists then
            declare
               Id : constant String :=
                 Version.Objects.To_String (Version.Refs.Resolve_Ref (Repo, New_Ref));
            begin
               --  git's files backend logs the rename on HEAD twice: the
               --  branch going away, then HEAD landing on the new name.
               Version.Reflog.Append
                 (Repo, "HEAD", Id, "0000000000000000000000000000000000000000",
                  Log_Msg);
               Version.Reflog.Append (Repo, "HEAD", Id, Id, Log_Msg);
            end;
         end if;
      end if;

      --  The branch.<name> configuration follows the branch.
      if Old_Name /= New_Name then
         begin
            if Copy then
               begin
                  for Item of Version.Config.Read_All (Repo) loop
                     declare
                        Full : constant String :=
                          Version.Config.Config_Entry_Name (Item);
                     begin
                        if Starts_With (Full, "branch." & Old_Name & ".")
                          and then Ada.Strings.Fixed.Index
                                     (Full (Full'First + 8 + Old_Name'Length
                                            .. Full'Last), ".") = 0
                        then
                           Version.Config.Add_Value
                             (Repo,
                              "branch." & New_Name & "."
                              & Full (Full'First + 8 + Old_Name'Length .. Full'Last),
                              To_String (Item.Value));
                        end if;
                     end;
                  end loop;
               end;
            else
               Version.Config.Rename_Section
                 (Repo, "branch """ & Old_Name & """", "branch """ & New_Name & """");
            end if;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;   --  no section to move
         end;
      end if;
   end Rename_Or_Copy;

   procedure Remove
     (Repo   : Version.Repository.Repository_Handle;
      Name   : String;
      Remote : Boolean)
   is
      Ref : constant String :=
        (if Remote then "refs/remotes/" & Name else "refs/heads/" & Name);
      Tx  : Version.Ref_Transaction.Transaction;
      Log : constant String := Version.Reflog.Path (Repo, Ref);
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Delete (Tx, Ref, "");
      Version.Ref_Transaction.Commit (Tx);
      Version.Files.Delete_File_If_Exists (Log);
      if not Remote then
         begin
            Version.Config.Remove_Section (Repo, "branch """ & Name & """");
         exception
            when Ada.IO_Exceptions.Data_Error =>
               null;
         end;
      end if;
   end Remove;

end Version.Branches;
