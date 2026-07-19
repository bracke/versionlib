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
with Version.Path_Safety;

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
   procedure Require_Switch_Safe
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Carried   : out Version.Path_Safety.Path_Vector)
   is
      use Ada.Strings.Unbounded;

      Result : constant Version.Status.Status_Result :=
        Version.Status.Current_Status (All_Untracked => True);
      Trees   : Version.Tree_Cache.Tree_Cache;

      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo    => Repo,
           Cache   => Trees,
           Tree_Id => Version.Objects.Commit_Tree_Id (Obj));

      --  The tree being left, to compare the target against. An unborn HEAD
      --  has none, and then nothing can be overwritten.
      function Head_Tree_Items
        return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Empty : Version.Objects.Tree_Entry_Vectors.Vector;
      begin
         return Version.Tree_Cache.Flatten_Tree
           (Repo    => Repo,
            Cache   => Trees,
            Tree_Id =>
              Version.Objects.Commit_Tree_Id
                (Version.Objects.Read_Object
                   (Repo,
                    Version.Objects.To_Object_Id
                      (Version.Refs.Current_Commit_Id (Repo)))));
      exception
         when others =>
            return Empty;
      end Head_Tree_Items;

      Head_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Head_Tree_Items;

      function Entry_In
        (Where : Version.Objects.Tree_Entry_Vectors.Vector;
         Path  : String;
         Id    : out Unbounded_String)
         return Boolean is
      begin
         for E of Where loop
            if To_String (E.Path) = Path then
               Id := To_Unbounded_String (Version.Objects.To_String (E.Id));
               return True;
            end if;
         end loop;

         Id := Null_Unbounded_String;
         return False;
      end Entry_In;

      --  A local modification only blocks the checkout when the target commit
      --  would write over it -- that is, when the path's content differs
      --  between HEAD and the target. A path that is the same in both is
      --  simply carried across, which is what makes `checkout <branch>` with
      --  edits in flight work in git. "Differs" includes existing on only one
      --  side, since that is an add or a delete to apply.
      function Would_Be_Overwritten (Path : String) return Boolean is
         Head_Id, Target_Id : Unbounded_String;
         In_Head : constant Boolean :=
           Entry_In (Head_Items, Path, Head_Id);
         In_Target : constant Boolean :=
           Entry_In (Items, Path, Target_Id);
      begin
         if In_Head /= In_Target then
            return True;
         elsif not In_Head then
            return False;
         else
            return Head_Id /= Target_Id;
         end if;
      end Would_Be_Overwritten;

      Blocked : Unbounded_String;

      procedure Note (Changes : Version.Status.File_Change_Vectors.Vector) is
      begin
         for C of Changes loop
            if Would_Be_Overwritten (To_String (C.Path)) then
               Append (Blocked, Character'Val (9));
               Append (Blocked, C.Path);
               Append (Blocked, Character'Val (10));
            else
               --  Same content on both sides: the edit rides along, so the
               --  working file must not be rewritten from the object store.
               Carried.Append (To_String (C.Path));
            end if;
         end loop;
      end Note;
   begin
      Carried.Clear;
      Note (Result.Changes);
      Note (Result.Staged);
      Note (Result.Conflicted);

      if Length (Blocked) > 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "Your local changes to the following files would be overwritten by"
           & " checkout:" & Character'Val (10) & To_String (Blocked)
           & "Please commit your changes or stash them before you switch"
           & " branches." & Character'Val (10) & "Aborting";
      end if;

      for U of Result.Untracked loop
         for E of Items loop
            if To_String (E.Path) = To_String (U.Path) then
               raise Ada.IO_Exceptions.Data_Error with
                 "cannot checkout commit: untracked working tree file "
                 & To_String (U.Path)
                 & " would be overwritten";
            end if;
         end loop;
      end loop;
   end Require_Switch_Safe;

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

   procedure Checkout_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Branch    : String := "")
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Old_Head : constant Version.Refs.Head_Info :=
        Version.Refs.Read_Head (Repo);

      Old_Text : constant String := Version.Refs.Current_Commit_Id (Repo);

      Old_Id : constant String :=
        (if Old_Text'Length = 0
         then "0000000000000000000000000000000000000000"
         else Old_Text);

      --  The reflog "from" name: the departed branch when HEAD was attached,
      --  or the full commit id when it was detached (git's "moving from X").
      Old_Name : constant String :=
        (if Version.Refs.Is_Attached (Old_Head)
         then Version.Refs.Branch_Name (Old_Head)
         else Old_Id);

      Objects       : Version.Object_Cache.Object_Cache;
      Trees         : Version.Tree_Cache.Tree_Cache;
      Target_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);

      --  Paths whose local edit survives the switch untouched.
      Carried : Version.Path_Safety.Path_Vector;
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

      Require_Switch_Safe (Repo, Commit_Id, Carried);
      Preflight_Checkout_Metadata (Repo);
      Version.Restore.Preflight_Working_Tree_For_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id);

      declare
         Old_Head_Content : constant String :=
           Version.Files.Read_Binary_File (Head_Path (Repo));
         Head_Moved       : Boolean := False;
      begin
         if Branch = "" then
            Version.Refs.Write_Detached_HEAD
              (Repo => Repo, Commit_Id => Commit_Id);
         else
            Version.Refs.Write_Symbolic_HEAD
              (Repo => Repo, Target => "refs/heads/" & Branch);
         end if;
         Head_Moved := True;

         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo      => Repo,
            Commit_Id => Commit_Id,
            Objects   => Objects,
            Trees     => Trees,
            Keep      => Carried);
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
            Message =>
              (if Branch = ""
               then "checkout: moving to " & Short_Id (To_String (Commit_Id))
               else "checkout: moving from " & Old_Name & " to " & Branch));

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
