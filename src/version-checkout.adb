with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Refs;
with Version.Repository;
with Version.Restore;
with Version.Status;
with Version.Reflog;
with Version.Rebase_State;
with Version.Cherry_Pick_State;
with Version.Revert_State;
with Version.Hooks;
with Version.Files;

package body Version.Checkout is

   function Short_Id (Id : String) return String is
   begin
      if Id'Length <= 12 then
         return Id;
      else
         return Id (Id'First .. Id'First + 11);
      end if;
   end Short_Id;

   --  An untracked file only blocks a checkout when the commit being checked
   --  out would overwrite it -- that is git's rule, and refusing on *any*
   --  untracked file made ordinary things (a build artifact, `bisect run`'s own
   --  test script) impossible.
   procedure Require_Clean_Status
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Result : constant Version.Status.Status_Result :=
        Version.Status.Current_Status (All_Untracked => True);
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      if not Result.Changes.Is_Empty
        or else not Result.Staged.Is_Empty
        or else not Result.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot checkout commit: working tree is not clean";
      end if;

      if Result.Untracked.Is_Empty then
         return;
      end if;

      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
         Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree
             (Repo    => Repo,
              Cache   => Trees,
              Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
      begin
         for U of Result.Untracked loop
            for E of Items loop
               if Ada.Strings.Unbounded.To_String (E.Path)
                 = Ada.Strings.Unbounded.To_String (U.Path)
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "cannot checkout commit: untracked working tree file "
                    & Ada.Strings.Unbounded.To_String (U.Path)
                    & " would be overwritten";
               end if;
            end loop;
         end loop;
      end;
   end Require_Clean_Status;

   function Head_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Version.Files.Join (Version.Repository.Git_Dir (Repo), "HEAD");
   end Head_Path;

   procedure Require_No_Lock (Path : String) is
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Path;
      end if;
   end Require_No_Lock;

   procedure Preflight_Checkout_Metadata
     (Repo : Version.Repository.Repository_Handle) is
   begin
      Require_No_Lock (Head_Path (Repo) & ".lock");
      Version.Reflog.Preflight_Append
        (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
   end Preflight_Checkout_Metadata;

   procedure Restore_Head_File
     (Repo    : Version.Repository.Repository_Handle;
      Content : String) is
   begin
      Version.Files.Write_Binary_File_Atomic
        (Path    => Head_Path (Repo),
         Content => Content);
   end Restore_Head_File;

   procedure Checkout_Commit (Commit_Id : Version.Objects.Hex_Object_Id) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Old_Text : constant String := Version.Refs.Current_Commit_Id (Repo);

      Old_Id : constant String :=
        (if Old_Text'Length = 0
         then "0000000000000000000000000000000000000000"
         else Old_Text);

      Objects       : Version.Object_Cache.Object_Cache;
      Trees         : Version.Tree_Cache.Tree_Cache;
      Target_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
   begin
      if Version.Objects.Kind (Target_Object) /= Version.Objects.Commit_Object
      then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit";
      end if;

      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot checkout commit: rebase in progress";
      end if;

      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot checkout commit: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot checkout commit: revert in progress";
      end if;

      Require_Clean_Status (Repo, Commit_Id);
      Preflight_Checkout_Metadata (Repo);
      Version.Restore.Preflight_Working_Tree_For_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id);

      declare
         Old_Head_Content : constant String :=
           Version.Files.Read_Binary_File (Head_Path (Repo));
         Head_Moved       : Boolean := False;
      begin
         Version.Refs.Write_Detached_HEAD (Repo => Repo, Commit_Id => Commit_Id);
         Head_Moved := True;

         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Objects   => Objects,
            Trees     => Trees);
         Version.Restore.Write_Index_For_Commit
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Objects   => Objects,
            Trees     => Trees);

         Version.Reflog.Append
           (Repo    => Repo,
            Ref     => "HEAD",
            Old_Id  => Old_Id,
            New_Id  => To_String (Commit_Id),
            Message => "checkout: moving to " & Short_Id (To_String (Commit_Id)));

         Version.Hooks.Run_Post_Checkout
           (Repo   => Repo,
            Old_Id => Old_Id,
            New_Id => To_String (Commit_Id),
            Flag   => "1");
      exception
         when others =>
            if Head_Moved then
               Restore_Head_File (Repo, Old_Head_Content);
            end if;
            raise;
      end;
   end Checkout_Commit;

   procedure Checkout_Path_From_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id; Path : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Objects       : Version.Object_Cache.Object_Cache;
      Trees         : Version.Tree_Cache.Tree_Cache;
      Target_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
   begin
      if Version.Objects.Kind (Target_Object) /= Version.Objects.Commit_Object
      then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit";
      end if;

      Version.Restore.Restore_Path_From_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Path      => Path,
         Objects   => Objects,
         Trees     => Trees);

      Version.Restore.Restore_Index_Path_From_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Path      => Path,
         Objects   => Objects,
         Trees     => Trees);

      Version.Hooks.Run_Post_Checkout
        (Repo   => Repo,
         Old_Id => Version.Refs.Current_Commit_Id (Repo),
         New_Id => To_String (Commit_Id),
         Flag   => "0");
   end Checkout_Path_From_Commit;

end Version.Checkout;
