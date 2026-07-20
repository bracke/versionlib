with Ada.Containers; use Ada.Containers;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories; use Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Version.Cherry_Pick_State;
with Version.Revert_State;
with Version.Compression;
with Version.Config;
with Version.Files;
with Version.Hooks;
with Version.History;
with Version.Merge;
with Version.Merge_State;
with Version.Object_Cache;
with Version.Objects; use Version.Objects;
with Version.Reflog;
with Version.Refs;
with Version.Ref_Names;
with Version.Ref_Transaction;

with Version.Restore;
with Version.Revisions;
with Version.Diff;
with Version.Staging;
with Version.Status;
with Version.Trailers;
with Version.Tree_Cache;
with Version.Write;
with Version.Timestamps;

package body Version.Rebase is

   Zero_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Branch_Name_From_Ref (Branch_Ref : String) return String is
      Prefix : constant String := "refs/heads/";
   begin
      if Branch_Ref'Length <= Prefix'Length
        or else Branch_Ref (Branch_Ref'First .. Branch_Ref'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: branch";
      end if;

      return Branch_Ref (Branch_Ref'First + Prefix'Length .. Branch_Ref'Last);
   end Branch_Name_From_Ref;

   procedure Require_Current_Rebase_Branch
     (Repo       : Version.Repository.Repository_Handle;
      Branch_Ref : String)
   is
      Expected : constant String := Branch_Name_From_Ref (Branch_Ref);
   begin
      --  A detached HEAD is the normal state during a rebase -- that is where
      --  the replayed commits are being stacked -- so it is not an error. Only
      --  an attached HEAD naming some other branch means the user has moved
      --  off the rebase and cannot continue or abort it here.
      if Version.Refs.Is_Detached (Repo) then
         return;
      end if;

      if Version.Refs.Current_Branch_Name (Repo) /= Expected then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue or abort rebase from a different branch";
      end if;
   end Require_Current_Rebase_Branch;

   function Natural_Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Natural_Image;

   procedure Require_Clean_Working_Tree is
      Result : constant Version.Status.Status_Result := Version.Status.Current_Status;
   begin
      if not Result.Changes.Is_Empty
        or else not Result.Staged.Is_Empty
        or else not Result.Untracked.Is_Empty
        or else not Result.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           "rebase requires clean working tree";
      end if;
   end Require_Clean_Working_Tree;

   function Tree_Id_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      return Version.Objects.Commit_Tree_Id (Obj);
   end Tree_Id_For_Commit;

   function First_Parent
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      if Parents.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with Root_Rebase_Not_Supported;
      elsif Parents.Length > 1 then
         raise Ada.IO_Exceptions.Data_Error with Merge_Commit_Rebase_Not_Supported;
      end if;

      return Parents.First_Element;
   end First_Parent;

   function Commits_To_Replay
     (Repo         : Version.Repository.Repository_Handle;
      Current_Head : Version.Objects.Hex_Object_Id;
      Target_Head  : Version.Objects.Hex_Object_Id)
      return Version.Rebase_State.Commit_Vectors.Vector
   is
      Base : Version.Objects.Hex_Object_Id := Zero_Id;
      Walk : Version.Objects.Hex_Object_Id := Current_Head;
      Reverse_Order : Version.Rebase_State.Commit_Vectors.Vector;
      Result : Version.Rebase_State.Commit_Vectors.Vector;
   begin
      begin
         Base :=
           Version.History.Merge_Base
             (Repo => Repo, Left => Current_Head, Right => Target_Head);
      exception
         when others =>
            raise Ada.IO_Exceptions.Data_Error with "invalid replay commit graph";
      end;

      while Walk /= Base loop
         declare
            Obj     : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Walk);
            Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Objects.Commit_Parent_Ids (Obj);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
               raise Ada.IO_Exceptions.Data_Error with "invalid replay commit graph";
            elsif Parents.Is_Empty then
               raise Ada.IO_Exceptions.Data_Error with Root_Rebase_Not_Supported;
            elsif Parents.Length > 1 then
               raise Ada.IO_Exceptions.Data_Error with Merge_Commit_Rebase_Not_Supported;
            end if;

            Reverse_Order.Append (Walk);
            Walk := Parents.First_Element;
         end;
      end loop;

      if not Reverse_Order.Is_Empty then
         for I in reverse Reverse_Order.First_Index .. Reverse_Order.Last_Index loop
            Result.Append (Reverse_Order.Element (I));
         end loop;
      end if;

      return Result;
   end Commits_To_Replay;

   function Commit_Message (Obj : Version.Objects.Git_Object) return String is
      Text : constant String := Version.Objects.Content (Obj);
      Sep  : constant Natural := Ada.Strings.Fixed.Index
        (Source => Text, Pattern => Character'Val (10) & Character'Val (10));
   begin
      if Sep = 0 then
         return "";
      end if;

      declare
         First : constant Natural := Sep + 2;
      begin
         if First > Text'Last then
            return "";
         end if;

         return Text (First .. Text'Last);
      end;
   end Commit_Message;

   function Author_Line (Obj : Version.Objects.Git_Object) return String is
      Text  : constant String := Version.Objects.Content (Obj);
      Start : Natural := Text'First;
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
               Stop := Stop + 1;
            end loop;

            exit when Stop = Start;

            declare
               Line_Last : constant Natural := Stop - 1;
            begin
               if Line_Last >= Start + 6
                 and then Text (Start .. Start + 6) = "author "
               then
                  return Text (Start .. Line_Last);
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "invalid replay commit graph";
   end Author_Line;

   function Unix_Time_Image return String is
   begin
      return Natural_Image (Natural (Version.Timestamps.Unix_Now));
   end Unix_Time_Image;

   function Timestamp_Line return String is
   begin
      return Unix_Time_Image & " +0000";
   end Timestamp_Line;

   function Object_Id_For
     (Repo : Version.Repository.Repository_Handle;
      Kind : String; Content : String) return Version.Objects.Hex_Object_Id
   is
   begin
      return Version.Objects.Compute_Object_Id
        (Version.Repository.Algorithm (Repo), Kind, Content);
   end Object_Id_For;

   procedure Write_String_File (Path : String; Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
      Data : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
   begin
      for I in Content'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Content (I)));
      end loop;

      Version.Files.Create_Parent_Directories (Path);
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Version.Files.To_Native_Path (Path));
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         raise;
   end Write_String_File;

   procedure Write_Loose_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Content : String)
   is
      Id : constant Version.Objects.Hex_Object_Id := Object_Id_For (Repo, "commit", Content);
      Raw : constant String := "commit" & Natural'Image (Content'Length) & Character'Val (0) & Content;
      Obj_Dir : constant String :=
        Join
          (Join (Version.Repository.Common_Git_Dir (Repo), "objects"),
           To_String (Id) (1 .. 2));
      Obj_Path : constant String := Join (Obj_Dir, To_String (Id) (3 .. To_String (Id)'Last));
   begin
      if not Ada.Directories.Exists (Obj_Dir) then
         Ada.Directories.Create_Directory (Obj_Dir);
      end if;

      if not Ada.Directories.Exists (Obj_Path) then
         Write_String_File (Obj_Path, Version.Compression.Deflate_Zlib (Raw));
      end if;
   end Write_Loose_Commit;

   --  Commit-message editor precedence for reword (git message editor: unlike
   --  the sequence editor it does not consult GIT_SEQUENCE_EDITOR).
   function Message_Editor return String is
   begin
      if Ada.Environment_Variables.Exists ("GIT_EDITOR") then
         return Ada.Environment_Variables.Value ("GIT_EDITOR");
      elsif Ada.Environment_Variables.Exists ("EDITOR") then
         return Ada.Environment_Variables.Value ("EDITOR");
      else
         raise Ada.IO_Exceptions.Data_Error with
           "reword requires a commit-message editor (set GIT_EDITOR)";
      end if;
   end Message_Editor;

   --  Git commit-message cleanup=strip: drop lines beginning with '#', strip
   --  trailing whitespace per line, remove leading/trailing blank lines,
   --  collapse consecutive blank lines to one, and end with a single newline.
   function Cleanup_Editor_Message (Raw : String) return String is
      LF            : constant Character := Character'Val (10);
      Result        : Unbounded_String;
      Start         : Positive := Raw'First;
      Pending_Blank : Boolean := False;
      Wrote_Line    : Boolean := False;

      function Rstrip (S : String) return String is
         Last : Integer := S'Last;
      begin
         while Last >= S'First
           and then (S (Last) = ' ' or else S (Last) = Character'Val (9)
                     or else S (Last) = Character'Val (13))
         loop
            Last := Last - 1;
         end loop;
         return S (S'First .. Last);
      end Rstrip;

      procedure Emit (Line : String) is
         Stripped : constant String := Rstrip (Line);
      begin
         if Stripped'Length >= 1 and then Stripped (Stripped'First) = '#' then
            return;
         end if;
         if Stripped'Length = 0 then
            if Wrote_Line then
               Pending_Blank := True;
            end if;
            return;
         end if;
         if Pending_Blank then
            Append (Result, LF);
            Pending_Blank := False;
         end if;
         Append (Result, Stripped & LF);
         Wrote_Line := True;
      end Emit;
   begin
      for I in Raw'Range loop
         if Raw (I) = LF then
            Emit (Raw (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Raw'Last then
         Emit (Raw (Start .. Raw'Last));
      end if;
      return To_String (Result);
   end Cleanup_Editor_Message;

   --  Open the editor seeded with a commit's message, return the cleaned result.
   --  Raises on editor failure or an empty resulting message (git parity).
   function Reword_Message
     (Repo     : Version.Repository.Repository_Handle;
      Original : Version.Objects.Hex_Object_Id)
      return String
   is
      Path : constant String :=
        Join (Version.Repository.Git_Dir (Repo), "VERSION_REWORD_EDITMSG");
      Original_Msg : constant String :=
        Commit_Message (Version.Objects.Read_Object (Repo, Original));
      Editor : constant String := Message_Editor;
      Args   : GNAT.OS_Lib.Argument_List :=
        [1 => new String'("-c"),
         2 => new String'(Editor & " '" & Path & "'")];
      Status : Integer;
   begin
      Version.Files.Write_Binary_File (Path, Original_Msg);
      Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
      GNAT.OS_Lib.Free (Args (1));
      GNAT.OS_Lib.Free (Args (2));
      if Status /= 0 then
         Version.Files.Delete_File_If_Exists (Path);
         raise Ada.IO_Exceptions.Data_Error with "reword: editor failed";
      end if;

      declare
         Cleaned : constant String :=
           Cleanup_Editor_Message (Version.Files.Read_Binary_File (Path));
      begin
         Version.Files.Delete_File_If_Exists (Path);
         if Cleaned'Length = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "aborting reword due to empty commit message";
         end if;
         return Cleaned;
      end;
   end Reword_Message;

   function Write_Replayed_Commit
     (Repo             : Version.Repository.Repository_Handle;
      Tree_Id          : Version.Objects.Hex_Object_Id;
      Parent_Id        : Version.Objects.Hex_Object_Id;
      Original         : Version.Objects.Hex_Object_Id;
      Message_Override : String := "")
      return Version.Objects.Hex_Object_Id
   is
      Original_Obj : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Original);
      User : constant Version.Config.Identity := Version.Config.User_Identity (Repo);
      --  A reword supplies the final, user-edited message directly; a pick runs
      --  the original message through the prepare-commit-msg hook path.
      Message : constant String :=
        (if Message_Override /= "" then Message_Override
         else Version.Hooks.Prepare_Commit_Message
                (Repo      => Repo,
                 Message   => Commit_Message (Original_Obj),
                 Run_Hooks => True));
      Content : Unbounded_String;
   begin
      Append (Content, "tree " & To_String (Tree_Id) & Character'Val (10));
      --  A bare `rebase --root` recreates the root commit parentless, so the
      --  "parent" header is omitted when Parent_Id is the null object id.
      if Parent_Id /= Zero_Id then
         Append (Content, "parent " & To_String (Parent_Id) & Character'Val (10));
      end if;
      Append (Content, Author_Line (Original_Obj) & Character'Val (10));
      Append
        (Content,
         "committer " & Version.Config.Committer_Signature (Repo)
         & Character'Val (10));
      Append (Content, Character'Val (10));
      Append (Content, Message);
      declare
         Commit_Content : constant String := To_String (Content);
         Id : constant Version.Objects.Hex_Object_Id := Object_Id_For (Repo, "commit", Commit_Content);
      begin
         Write_Loose_Commit (Repo => Repo, Content => Commit_Content);
         return Id;
      end;
   end Write_Replayed_Commit;

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

   procedure Require_Paused_Merge_State
     (Repo      : Version.Repository.Repository_Handle;
      State     : Version.Rebase_State.Rebase_State;
      Conflicts : in out Version.Merge.Conflict_Vectors.Vector)
   is
      Current_Id    : Version.Objects.Object_Id_Storage;
      Target_Id     : Version.Objects.Object_Id_Storage;
      Base_Id       : Version.Objects.Object_Id_Storage;
      Target_Branch : Unbounded_String;
   begin
      Conflicts.Clear;

      --  A rebase git paused has no merge state of ours -- git records the
      --  stop in rebase-merge/ alone. That is not a broken rebase, so instead
      --  of demanding our own file, fall back to the index: unmerged entries
      --  are what "still conflicted" means, and both tools write them.
      if not Version.Merge_State.State_Exists (Repo) then
         for E of Version.Staging.Load (Repo) loop
            if E.Stage /= 0 then
               declare
                  Already : Boolean := False;
               begin
                  for C of Conflicts loop
                     if C.Path = E.Path then
                        Already := True;
                     end if;
                  end loop;
                  if not Already then
                     Conflicts.Append
                       (Version.Merge.Conflict'
                          (Path => E.Path, others => <>));
                  end if;
               end;
            end if;
         end loop;
         return;
      end if;

      Version.Merge_State.Read_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Base_Id,
         Target_Branch => Target_Branch,
         Conflicts     => Conflicts);

      if To_String (Target_Branch) /= "rebase"
        or else Current_Id /= Version.Rebase_State.Current_Replay_Head (State)
        or else Target_Id /= Version.Rebase_State.Current_Commit (State)
        or else Conflicts.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue rebase: merge state does not match rebase state";
      end if;
   end Require_Paused_Merge_State;

   --  git will not continue while the index still holds unmerged stages, even
   --  if the working file no longer has markers in it: editing a file is not
   --  the same as resolving it, and continuing anyway would commit whatever
   --  the index still had rather than the edit the user made.
   procedure Require_Index_Fully_Merged
     (Repo : Version.Repository.Repository_Handle) is
   begin
      for E of Version.Staging.Load (Repo) loop
         if E.Stage /= 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot continue rebase: unresolved conflict in "
              & To_String (E.Path)
              & " -- resolve it and mark it resolved with `add`";
         end if;
      end loop;
   end Require_Index_Fully_Merged;

   function Conflict_Paths_Have_Markers
     (Repo      : Version.Repository.Repository_Handle;
      Conflicts : Version.Merge.Conflict_Vectors.Vector) return Boolean
   is
   begin
      if not Conflicts.Is_Empty then
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            declare
               Relative_Path : constant String := To_String (Conflicts.Element (I).Path);
               Absolute_Path : constant String := Join (Version.Repository.Root_Path (Repo), Relative_Path);
            begin
               if File_Contains_Conflict_Marker (Absolute_Path) then
                  return True;
               end if;
            end;
         end loop;
      end if;
      return False;
   end Conflict_Paths_Have_Markers;

   procedure Require_No_Untracked_During_Continue is
      Result : constant Version.Status.Status_Result := Version.Status.Current_Status;
   begin
      if not Result.Untracked.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue rebase: untracked files present";
      end if;
   end Require_No_Untracked_During_Continue;

   --  The resolution is what the user staged, exactly as git commits the index
   --  on `rebase --continue`. Rebuilding it from the working tree instead --
   --  which this used to do -- both accepted a resolution that was never
   --  marked resolved and swept up every unrelated edit lying around.
   procedure Load_Staged_Index
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Version.Staging.Index_Entry_Vectors.Vector)
   is
   begin
      Result := Version.Staging.Load (Repo);
   end Load_Staged_Index;

   function Replay_Commit
     (Repo          : Version.Repository.Repository_Handle;
      Replay_Parent : Version.Objects.Hex_Object_Id;
      Commit_Id     : Version.Objects.Hex_Object_Id;
      Allow_Root    : Boolean := False;
      Reword        : Boolean := False)
      return Replay_Result
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Commit_Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids
          (Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id));
      Is_Root : constant Boolean := Commit_Parents.Is_Empty;
      --  First_Parent (only called for non-root) keeps the merge-commit and
      --  object-kind rejections; a root commit's base is the empty tree.
      Base_Id : constant Version.Objects.Hex_Object_Id :=
        (if Is_Root then Zero_Id else First_Parent (Repo, Objects, Commit_Id));
      Current_Tree_Id : constant Version.Objects.Hex_Object_Id := Tree_Id_For_Commit (Repo, Objects, Replay_Parent);
      Target_Tree_Id : constant Version.Objects.Hex_Object_Id := Tree_Id_For_Commit (Repo, Objects, Commit_Id);
      Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        (if Is_Root then Version.Objects.Tree_Entry_Vectors.Empty_Vector
         else Version.Tree_Cache.Flatten_Tree
                (Repo => Repo, Cache => Trees,
                 Tree_Id => Tree_Id_For_Commit (Repo, Objects, Base_Id)));
      Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree (Repo => Repo, Cache => Trees, Tree_Id => Current_Tree_Id);
      Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree (Repo => Repo, Cache => Trees, Tree_Id => Target_Tree_Id);
      Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts : Version.Merge.Conflict_Vectors.Vector;
   begin
      if Is_Root and then not Allow_Root then
         raise Ada.IO_Exceptions.Data_Error with Root_Rebase_Not_Supported;
      end if;

      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Replay_Parent, Objects => Objects, Trees => Trees);
      Version.Restore.Write_Index_For_Commit
        (Repo => Repo, Commit_Id => Replay_Parent, Objects => Objects, Trees => Trees);

      Version.Merge.Merge_Trees
        (Repo          => Repo,
         Current_Name  => "HEAD",
         Target_Name   => Version.Merge.Commit_Label_For (Repo, Commit_Id),
         Base_Items    => Base_Items,
         Current_Items => Current_Items,
         Target_Items  => Target_Items,
         Merged_Index  => Merged_Index,
         Conflicts     => Conflicts,
         Behavior      => Version.Merge.Merge_Behavior'
           (Base_Label => Ada.Strings.Unbounded.To_Unbounded_String
              (Version.Merge.Base_Label_For (Repo, Base_Id)),
            others     => <>));

      if not Conflicts.Is_Empty then
         Version.Merge_State.Clear_State (Repo);
         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Replay_Parent,
            Target_Id     => Commit_Id,
            Base_Id       => Base_Id,
            Target_Branch => "rebase",
            Conflicts     => Conflicts);
         --  The merged index carries the conflicted paths at stages 1/2/3,
         --  and writing it is what makes the conflict visible: left unwritten,
         --  the index still holds the replay parent's tree at stage 0, so the
         --  marked-up file reads as an ordinary modification and `commit`
         --  would take the conflict markers without a word.
         Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
         return Replay_Result'(Kind => Replay_Conflict, Commit_Id => Zero_Id);
      end if;

      Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Merged_Index);
         --  The merge is clean, so a reword now opens the editor (git only
         --  prompts once the commit applies without conflict).
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Write_Replayed_Commit
             (Repo             => Repo,
              Tree_Id          => Tree_Id,
              Parent_Id        => Replay_Parent,
              Original         => Commit_Id,
              Message_Override =>
                (if Reword then Reword_Message (Repo, Commit_Id) else ""));
      begin
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo => Repo, Commit_Id => New_Commit);
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => New_Commit);
         return Replay_Result'(Kind => Replay_Clean, Commit_Id => New_Commit);
      end;
   end Replay_Commit;

   procedure Write_Branch_Ref
     (Repo       : Version.Repository.Repository_Handle;
      Branch_Ref : String;
      Commit_Id  : Version.Objects.Hex_Object_Id)
   is
      Old_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Refs.Resolve_Ref (Repo => Repo, Name => Branch_Ref);
      Tx     : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Names.Require_Ref_Name (Branch_Ref);

      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => Branch_Ref,
         New_Id       => Commit_Id,
         Expected_Old => To_String (Old_Id));
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Write_Branch_Ref;

   procedure Write_Resume_For
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id);
   --  Declared here and defined below, next to the commit-header readers it
   --  needs: the stop sites are above them.

   --  git keeps HEAD detached for the whole rebase and advances it one commit
   --  at a time; the branch ref moves only at the end. Leaving HEAD on the
   --  branch instead makes the index describe a different commit than HEAD,
   --  which is what made every file the new base introduced look newly staged.
   procedure Move_Detached_Head
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Message   : String)
   is
      Old_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      Version.Reflog.Preflight_Append
        (Repo, "HEAD", Version.Reflog.Data_Error_On_Lock);
      Version.Refs.Write_Detached_HEAD (Repo => Repo, Commit_Id => Commit_Id);
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => Old_Id,
         New_Id  => To_String (Commit_Id),
         Message => Message);
   end Move_Detached_Head;

   function Replay_Subject
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return String is
     (Version.Objects.Commit_Message_First_Line
        (Version.Objects.Read_Object (Repo, Id)));

   procedure Finish_Rebase
     (Repo          : Version.Repository.Repository_Handle;
      Branch_Ref    : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Target_Head   : Version.Objects.Hex_Object_Id;
      Final_Head    : Version.Objects.Hex_Object_Id) is
   begin
      Write_Branch_Ref (Repo => Repo, Branch_Ref => Branch_Ref, Commit_Id => Final_Head);
      --  Reattach: the branch now holds the replayed history, so HEAD goes
      --  back to naming it rather than the commit it happens to be at.
      Version.Refs.Write_Symbolic_HEAD (Repo => Repo, Target => Branch_Ref);
      Version.Restore.Restore_Working_Tree_For_Commit (Repo => Repo, Commit_Id => Final_Head);
      Version.Restore.Write_Index_For_Commit (Repo => Repo, Commit_Id => Final_Head);
      --  git words these two differently: HEAD records where it is going back
      --  to, the branch records what it was rebased onto.
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => To_String (Original_Head),
         New_Id  => To_String (Final_Head),
         Message => "rebase (finish): returning to " & Branch_Ref);
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => Branch_Ref,
         Old_Id  => To_String (Original_Head),
         New_Id  => To_String (Final_Head),
         Message => "rebase (finish): " & Branch_Ref & " onto "
                    & To_String (Target_Head));
      Version.Rebase_State.Clear_State (Repo);
      Version.Merge_State.Clear_State (Repo);
      Version.Hooks.Run_Post_Commit (Repo => Repo, Run_Hooks => True);
   end Finish_Rebase;

   procedure Replay_Remaining
     (Repo                : Version.Repository.Repository_Handle;
      Branch_Ref          : String;
      Original_Head       : Version.Objects.Hex_Object_Id;
      Target_Head         : Version.Objects.Hex_Object_Id;
      Current_Replay_Head : Version.Objects.Hex_Object_Id;
      Next_Index          : Natural;
      Commits             : Version.Rebase_State.Commit_Vectors.Vector;
      Allow_Root          : Boolean := False;
      Actions             : Version.Rebase_State.Action_Vectors.Vector :=
        Version.Rebase_State.Action_Vectors.Empty_Vector;
      Execs               : Version.Rebase_State.Exec_Vectors.Vector :=
        Version.Rebase_State.Exec_Vectors.Empty_Vector;
      Next_Exec           : Natural := 0;
      Onto_Name           : String := "")
   is
      use type Version.Rebase_State.Rebase_Action;
      Replay_Head : Version.Objects.Hex_Object_Id := Current_Replay_Head;
      Index       : Natural := Next_Index;
      Exec_Cursor : Natural := Next_Exec;

      function Is_Reword (I : Natural) return Boolean is
        (not Actions.Is_Empty
         and then Actions.Element (Actions.First_Index + I)
                    = Version.Rebase_State.Reword);

      function Is_Edit (I : Natural) return Boolean is
        (not Actions.Is_Empty
         and then Actions.Element (Actions.First_Index + I)
                    = Version.Rebase_State.Edit);

      procedure Persist
        (Paused     : Boolean := False;
         Cur_Commit : String := "";
         Reason     : Version.Rebase_State.Pause_Kind :=
           Version.Rebase_State.Pause_Conflict) is
      begin
         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Branch_Ref,
            Original_Head       => Original_Head,
            Target_Head         => Target_Head,
            Current_Replay_Head => Replay_Head,
            Next_Index          => Index,
            Commits             => Commits,
            Paused              => Paused,
            Current_Commit      => Cur_Commit,
            Actions             => Actions,
            Execs               => Execs,
            Next_Exec           => Exec_Cursor,
            Pause_Reason        => Reason);
      end Persist;

      --  Run every exec now due (After <= the number of commits applied so far)
      --  in todo order. On a non-zero exit, persist an exec pause and raise --
      --  like a conflict stop it yields a non-zero exit and a resumable state;
      --  --continue then advances past the failed exec to the next todo entry.
      procedure Run_Due_Execs is
      begin
         while Exec_Cursor < Natural (Execs.Length)
           and then Execs.Element (Execs.First_Index + Exec_Cursor).After <= Index
         loop
            declare
               Command : constant String :=
                 To_String
                   (Execs.Element (Execs.First_Index + Exec_Cursor).Command);
               Args    : GNAT.OS_Lib.Argument_List :=
                 [1 => new String'("-c"), 2 => new String'(Command)];
               Status  : Integer;
            begin
               Ada.Text_IO.Put_Line ("Executing: " & Command);
               Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
               GNAT.OS_Lib.Free (Args (1));
               GNAT.OS_Lib.Free (Args (2));
               if Status /= 0 then
                  Persist
                    (Paused => True,
                     Reason => Version.Rebase_State.Pause_Exec);
                  raise Ada.IO_Exceptions.Data_Error with
                    "rebase stopped: exec failed: " & Command;
               end if;
            end;
            Exec_Cursor := Exec_Cursor + 1;
            Persist;
         end loop;
      end Run_Due_Execs;
   begin
      --  Detach at the replay point before touching anything. On --continue
      --  HEAD is already there, so this is a no-op rather than a second move.
      if not Version.Refs.Is_Detached (Repo)
        or else Version.Refs.Current_Commit_Id (Repo) /= To_String (Replay_Head)
      then
         --  git records the onto the user named ("main"), not the id it
         --  resolved to, so the reflog reads the way the command was typed.
         Move_Detached_Head
           (Repo, Replay_Head,
            "rebase (start): checkout "
            & (if Onto_Name'Length > 0 then Onto_Name
               else To_String (Target_Head)));
      end if;

      loop
         Run_Due_Execs;
         exit when Index >= Natural (Commits.Length);
         declare
            Commit_Id : constant Version.Objects.Hex_Object_Id := Commits.Element (Commits.First_Index + Index);
            Result : constant Replay_Result :=
              Replay_Commit (Repo => Repo, Replay_Parent => Replay_Head,
                             Commit_Id => Commit_Id, Allow_Root => Allow_Root,
                             Reword => Is_Reword (Index));
         begin
            if Result.Kind = Replay_Conflict then
               Persist (Paused => True, Cur_Commit => To_String (Commit_Id),
                        Reason => Version.Rebase_State.Pause_Conflict);
               Write_Resume_For (Repo, Commit_Id);
               raise Ada.IO_Exceptions.Data_Error with "rebase paused: conflicts recorded";
            end if;

            Replay_Head := Result.Commit_Id;
            Move_Detached_Head
              (Repo, Replay_Head,
               "rebase (pick): " & Replay_Subject (Repo, Replay_Head));

            if Is_Edit (Index) then
               --  Stop for edit: HEAD is already on the applied commit, so the
               --  user can amend or add commits from here. Leave a clean
               --  working tree and pause. Return cleanly -- an edit-stop is an
               --  intentional stop, not an error (git exits 0).
               Version.Restore.Restore_Working_Tree_For_Commit
                 (Repo => Repo, Commit_Id => Replay_Head);
               Version.Restore.Write_Index_For_Commit
                 (Repo => Repo, Commit_Id => Replay_Head);
               Persist (Paused => True, Cur_Commit => To_String (Commit_Id),
                        Reason => Version.Rebase_State.Pause_Edit);
               return;
            end if;

            Index := Index + 1;
            Persist;
         end;
      end loop;

      Finish_Rebase
        (Repo          => Repo,
         Branch_Ref    => Branch_Ref,
         Original_Head => Original_Head,
         Target_Head   => Target_Head,
         Final_Head    => Replay_Head);
   end Replay_Remaining;

   procedure Start (Target : String) is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   begin
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase detached HEAD";
      end if;

      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "rebase already in progress";
      end if;

      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase: revert in progress";
      end if;

      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase: merge state already exists";
      end if;

      Require_Clean_Working_Tree;

      declare
         Branch_Name : constant String := Version.Refs.Current_Branch_Name (Repo);
         Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
         Original_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Target_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo => Repo, Text => Target);
         Commits : constant Version.Rebase_State.Commit_Vectors.Vector :=
           Commits_To_Replay
             (Repo         => Repo,
              Current_Head => Original_Head,
              Target_Head  => Target_Head);
      begin
         Version.Ref_Names.Require_Ref_Name (Branch_Ref);

         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Branch_Ref,
            Original_Head       => Original_Head,
            Target_Head         => Target_Head,
            Current_Replay_Head => Target_Head,
            Next_Index          => 0,
            Commits             => Commits);

         begin
            Replay_Remaining
              (Repo                => Repo,
               Branch_Ref          => Branch_Ref,
               Original_Head       => Original_Head,
               Target_Head         => Target_Head,
               Current_Replay_Head => Target_Head,
               Next_Index          => 0,
               Commits             => Commits,
               Onto_Name           => Target);
         exception
            when others =>
               declare
                  Preserve_State : Boolean := False;
               begin
                  if Version.Rebase_State.State_Exists (Repo) then
                     begin
                        Preserve_State :=
                          Version.Rebase_State.Paused
                            (Version.Rebase_State.Read_State (Repo));
                     exception
                        when others =>
                           Preserve_State := False;
                     end;
                  end if;

                  if not Preserve_State then
                     Version.Rebase_State.Clear_State (Repo);
                     Version.Merge_State.Clear_State (Repo);
                  end if;
               end;
               raise;
         end;
      end;
   end Start;

   --  The "author Name <email> ts tz" value of a commit (for squash, which
   --  keeps the first commit's authorship).
   function IR_Author_Line
     (Repo : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id) return String
   is
      Content : constant String :=
        Version.Objects.Content (Version.Objects.Read_Object (Repo, Commit));
      Pos : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            EOL : Natural := Content'Last + 1;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = Character'Val (10) then
                  EOL := K;
                  exit;
               end if;
            end loop;
            exit when Pos = EOL;
            if EOL - Pos >= 7
              and then Content (Pos .. Pos + 6) = "author "
            then
               return Content (Pos + 7 .. EOL - 1);
            end if;
            Pos := EOL + 1;
         end;
      end loop;
      return "";
   end IR_Author_Line;

   --  A commit's message body (after the header blank line), trailing newlines
   --  trimmed.
   function IR_Full_Message
     (Repo : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id) return String
   is
      Content : constant String :=
        Version.Objects.Content (Version.Objects.Read_Object (Repo, Commit));
      Start : Natural := Content'Last + 1;
      Last  : Integer;
   begin
      for I in Content'First .. Content'Last - 1 loop
         if Content (I) = Character'Val (10)
           and then Content (I + 1) = Character'Val (10)
         then
            Start := I + 2;
            exit;
         end if;
      end loop;
      if Start > Content'Last then
         return "";
      end if;
      Last := Content'Last;
      while Last >= Start and then Content (Last) = Character'Val (10) loop
         Last := Last - 1;
      end loop;
      return Content (Start .. Last);
   end IR_Full_Message;

   --  Leave behind what `git rebase --continue` needs to finish the commit we
   --  stopped on: its authorship, its message with git's "# Conflicts:" note,
   --  and the diff being applied. None of it is read back by this tool.
   procedure Write_Resume_For
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
   is
      function Conflicts_Note return String is
         Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Version.Staging.Load (Repo);
         Seen    : Version.Trailers.String_Vectors.Vector;
         Text    : Unbounded_String;
      begin
         for E of Entries loop
            if E.Stage /= 0
              and then not Seen.Contains (To_String (E.Path))
            then
               Seen.Append (To_String (E.Path));
               Append (Text, "#" & Character'Val (9)
                       & To_String (E.Path) & Character'Val (10));
            end if;
         end loop;

         if Length (Text) = 0 then
            return "";
         end if;

         return Character'Val (10) & "# Conflicts:" & Character'Val (10)
           & To_String (Text);
      end Conflicts_Note;

      function Patch_Text return String is
         Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
           Version.Objects.Commit_Parent_Ids
             (Version.Objects.Read_Object (Repo, Commit));
      begin
         if Parents.Is_Empty then
            return Version.Diff.Diff_Root_Commit (Repo, Commit);
         end if;
         return Version.Diff.Diff_Commits
           (Repo, Parents.First_Element, Commit);
      exception
         when others =>
            return "";
      end Patch_Text;
   begin
      Version.Rebase_State.Write_Resume_Info
        (Repo        => Repo,
         Author_Line => IR_Author_Line (Repo, Commit),
         Message     =>
           IR_Full_Message (Repo, Commit) & Character'Val (10)
           & Conflicts_Note,
         Patch       => Patch_Text);
   exception
      --  Best effort: these files only help the other tool, and failing to
      --  write them must not turn a normal conflict stop into an error.
      when others =>
         null;
   end Write_Resume_For;

   procedure Start_Interactive (Upstream : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      function Sequence_Editor return String is
      begin
         if Ada.Environment_Variables.Exists ("GIT_SEQUENCE_EDITOR") then
            return Ada.Environment_Variables.Value ("GIT_SEQUENCE_EDITOR");
         elsif Ada.Environment_Variables.Exists ("GIT_EDITOR") then
            return Ada.Environment_Variables.Value ("GIT_EDITOR");
         elsif Ada.Environment_Variables.Exists ("EDITOR") then
            return Ada.Environment_Variables.Value ("EDITOR");
         else
            raise Ada.IO_Exceptions.Data_Error with
              "interactive rebase requires a sequence editor "
              & "(set GIT_SEQUENCE_EDITOR)";
         end if;
      end Sequence_Editor;
   begin
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase detached HEAD";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "rebase already in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: revert in progress";
      end if;
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: merge state already exists";
      end if;

      Require_Clean_Working_Tree;

      declare
         Branch_Name : constant String :=
           Version.Refs.Current_Branch_Name (Repo);
         Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
         Original_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Target_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, Upstream);
         All_Commits : constant Version.Rebase_State.Commit_Vectors.Vector :=
           Commits_To_Replay (Repo, Original_Head, Target_Head);
         Todo_Path : constant String :=
           Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "version-rebase-todo");

         type Todo_Cmd is
           (Cmd_Pick, Cmd_Reword, Cmd_Edit, Cmd_Squash, Cmd_Fixup);
         type Todo_Entry is record
            Kind : Todo_Cmd;
            Id   : Version.Objects.Object_Id_Storage;
         end record;
         package Entry_Vectors is new Ada.Containers.Vectors
           (Index_Type => Positive, Element_Type => Todo_Entry);

         Entries     : Entry_Vectors.Vector;
         Has_Squash  : Boolean := False;
         Has_Reword  : Boolean := False;
         Has_Edit    : Boolean := False;
         Has_Exec    : Boolean := False;
         --  True once any non-comment, non-blank todo line is seen. git aborts
         --  with "nothing to do" only for an emptied/all-comment todo; a todo
         --  that explicitly `drop`s every commit is a successful rebase that
         --  moves the branch to the upstream.
         Has_Command : Boolean := False;
         Picked      : Version.Rebase_State.Commit_Vectors.Vector;
         Pick_Actions : Version.Rebase_State.Action_Vectors.Vector;
         Parsed_Execs : Version.Rebase_State.Exec_Vectors.Vector;
      begin
         Version.Ref_Names.Require_Ref_Name (Branch_Ref);

         --  Write the todo.
         declare
            Todo : Unbounded_String;
         begin
            for C of All_Commits loop
               Append
                 (Todo,
                  "pick " & To_String (C) (To_String (C)'First .. To_String (C)'First + 6) & " "
                  & Version.Objects.Commit_Message_First_Line
                      (Version.Objects.Read_Object (Repo, C))
                  & Character'Val (10));
            end loop;
            Append (Todo,
               "# pick = keep, drop = remove; reorder lines to reorder."
               & Character'Val (10));
            Version.Files.Write_Binary_File (Todo_Path, To_String (Todo));
         end;

         --  Edit it.
         declare
            Args : GNAT.OS_Lib.Argument_List :=
              [1 => new String'("-c"),
               2 => new String'(Sequence_Editor & " '" & Todo_Path & "'")];
            Status : Integer;
         begin
            Status := GNAT.OS_Lib.Spawn ("/bin/sh", Args);
            GNAT.OS_Lib.Free (Args (1));
            GNAT.OS_Lib.Free (Args (2));
            if Status /= 0 then
               Version.Files.Delete_File_If_Exists (Todo_Path);
               raise Ada.IO_Exceptions.Data_Error with
                 "interactive rebase: sequence editor failed";
            end if;
         end;

         --  Parse the edited todo into the picked commit list.
         declare
            Content : constant String :=
              Version.Files.Read_Binary_File (Todo_Path);
            Start_L : Positive := Content'First;

            procedure Handle (Line : String) is
               F : Natural := Line'First;
            begin
               while F <= Line'Last and then Line (F) = ' ' loop
                  F := F + 1;
               end loop;
               if F > Line'Last or else Line (F) = '#' then
                  return;
               end if;
               Has_Command := True;

               declare
                  CE : Natural := F;
               begin
                  while CE <= Line'Last and then Line (CE) /= ' ' loop
                     CE := CE + 1;
                  end loop;
                  declare
                     Cmd : constant String := Line (F .. CE - 1);
                     S1  : Natural := CE;
                  begin
                     while S1 <= Line'Last and then Line (S1) = ' ' loop
                        S1 := S1 + 1;
                     end loop;

                     if Cmd = "exec" or else Cmd = "x" then
                        --  `exec <command>`: the rest of the line is the shell
                        --  command; anchor it after the commits seen so far.
                        if S1 > Line'Last then
                           raise Ada.IO_Exceptions.Data_Error with
                             "interactive rebase: exec requires a command";
                        end if;
                        Has_Exec := True;
                        Parsed_Execs.Append
                          (Version.Rebase_State.Exec_Step'
                             (After   => Natural (Entries.Length),
                              Command =>
                                To_Unbounded_String (Line (S1 .. Line'Last))));
                        return;
                     end if;

                     declare
                        SE : Natural := S1;
                     begin
                        while SE <= Line'Last and then Line (SE) /= ' ' loop
                           SE := SE + 1;
                        end loop;
                        declare
                           Sha : constant String :=
                             (if S1 <= Line'Last then Line (S1 .. SE - 1)
                              else "");
                        begin
                           if Cmd = "drop" or else Cmd = "d" then
                              null;
                           else
                              declare
                                 Kind  : Todo_Cmd;
                                 Found : Boolean := False;
                              begin
                                 if Cmd = "pick" or else Cmd = "p" then
                                    Kind := Cmd_Pick;
                                 elsif Cmd = "reword" or else Cmd = "r" then
                                    Kind := Cmd_Reword;
                                    Has_Reword := True;
                                 elsif Cmd = "edit" or else Cmd = "e" then
                                    Kind := Cmd_Edit;
                                    Has_Edit := True;
                                 elsif Cmd = "squash" or else Cmd = "s" then
                                    Kind := Cmd_Squash;
                                    Has_Squash := True;
                                 elsif Cmd = "fixup" or else Cmd = "f" then
                                    Kind := Cmd_Fixup;
                                    Has_Squash := True;
                                 else
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "interactive rebase: command not "
                                      & "supported: " & Cmd;
                                 end if;

                                 for C of All_Commits loop
                                    if Sha'Length > 0
                                      and then Sha'Length <= 64
                                      and then To_String (C)
                                                 (To_String (C)'First .. To_String (C)'First + Sha'Length - 1)
                                               = Sha
                                    then
                                       Entries.Append
                                         (Todo_Entry'(Kind => Kind, Id => C));
                                       Found := True;
                                       exit;
                                    end if;
                                 end loop;
                                 if not Found then
                                    raise Ada.IO_Exceptions.Data_Error with
                                      "interactive rebase: unknown commit " & Sha;
                                 end if;
                              end;
                           end if;
                        end;
                     end;
                  end;
               end;
            end Handle;
         begin
            for I in Content'Range loop
               if Content (I) = Character'Val (10) then
                  Handle (Content (Start_L .. I - 1));
                  Start_L := I + 1;
               end if;
            end loop;
            if Start_L <= Content'Last then
               Handle (Content (Start_L .. Content'Last));
            end if;
         end;

         Version.Files.Delete_File_If_Exists (Todo_Path);

         --  git aborts an emptied/all-comment todo without touching the branch.
         --  An explicit `drop` of every commit is NOT empty (Has_Command is
         --  set): that is a successful rebase that advances to the upstream.
         if not Has_Command then
            raise Ada.IO_Exceptions.Data_Error with "nothing to do";
         end if;

         if (Has_Reword or else Has_Edit or else Has_Exec)
           and then Has_Squash
         then
            raise Ada.IO_Exceptions.Data_Error with
              "interactive rebase: reword/edit/exec combined with squash/fixup "
              & "is not supported";
         end if;

         if not Has_Squash then
            --  Pick/reword/drop/reorder: replay through the shared state
            --  machine so --continue/--abort work.
            for E of Entries loop
               Picked.Append (E.Id);
               Pick_Actions.Append
                 (if E.Kind = Cmd_Reword
                  then Version.Rebase_State.Reword
                  elsif E.Kind = Cmd_Edit
                  then Version.Rebase_State.Edit
                  else Version.Rebase_State.Pick);
            end loop;

            Version.Rebase_State.Write_State
              (Repo                => Repo,
               Branch_Ref          => Branch_Ref,
               Original_Head       => Original_Head,
               Target_Head         => Target_Head,
               Current_Replay_Head => Target_Head,
               Next_Index          => 0,
               Commits             => Picked,
               Actions             => Pick_Actions,
               Execs               => Parsed_Execs);

            begin
               Replay_Remaining
                 (Repo                => Repo,
                  Branch_Ref          => Branch_Ref,
                  Original_Head       => Original_Head,
                  Target_Head         => Target_Head,
                  Current_Replay_Head => Target_Head,
                  Next_Index          => 0,
                  Commits             => Picked,
                  Actions             => Pick_Actions,
                  Execs               => Parsed_Execs);
            exception
               when others =>
                  declare
                     Preserve_State : Boolean := False;
                  begin
                     if Version.Rebase_State.State_Exists (Repo) then
                        begin
                           Preserve_State :=
                             Version.Rebase_State.Paused
                               (Version.Rebase_State.Read_State (Repo));
                        exception
                           when others =>
                              Preserve_State := False;
                        end;
                     end if;
                     if not Preserve_State then
                        Version.Rebase_State.Clear_State (Repo);
                        Version.Merge_State.Clear_State (Repo);
                     end if;
                  end;
                  raise;
            end;
         else
            --  squash/fixup present: one-shot executor. Conflicts abort and
            --  restore the original head (--continue is not available here).
            declare
               Replay_Head : Version.Objects.Hex_Object_Id := Target_Head;
               Have_Prev   : Boolean := False;
               Prev_Parent : Version.Objects.Hex_Object_Id := Target_Head;
               Prev_Author : Unbounded_String;
               Prev_Msg    : Unbounded_String;

               procedure Abort_Interactive is
               begin
                  Version.Restore.Restore_Working_Tree_For_Commit
                    (Repo, Original_Head);
                  Version.Restore.Write_Index_For_Commit (Repo, Original_Head);
                  Version.Merge_State.Clear_State (Repo);
                  raise Ada.IO_Exceptions.Data_Error with
                    "interactive rebase aborted: conflict "
                    & "(resolution unsupported with squash)";
               end Abort_Interactive;
            begin
               for E of Entries loop
                  case E.Kind is
                     when Cmd_Pick =>
                        declare
                           R : constant Replay_Result :=
                             Replay_Commit (Repo, Replay_Head, E.Id);
                        begin
                           if R.Kind = Replay_Conflict then
                              Abort_Interactive;
                           end if;
                           Prev_Parent := Replay_Head;
                           Replay_Head := R.Commit_Id;
                           Prev_Author := To_Unbounded_String
                             (IR_Author_Line (Repo, R.Commit_Id));
                           Prev_Msg := To_Unbounded_String
                             (IR_Full_Message (Repo, R.Commit_Id));
                           Have_Prev := True;
                        end;

                     when Cmd_Reword | Cmd_Edit =>
                        --  Rejected up front (guard before this branch); kept
                        --  for case coverage.
                        raise Ada.IO_Exceptions.Data_Error with
                          "interactive rebase: reword/edit combined with "
                          & "squash/fixup is not supported";

                     when Cmd_Squash | Cmd_Fixup =>
                        if not Have_Prev then
                           raise Ada.IO_Exceptions.Data_Error with
                             "interactive rebase: squash without a preceding "
                             & "pick";
                        end if;
                        declare
                           S : constant Replay_Result :=
                             Replay_Commit (Repo, Replay_Head, E.Id);
                        begin
                           if S.Kind = Replay_Conflict then
                              Abort_Interactive;
                           end if;
                           declare
                              Tree : constant Version.Objects.Hex_Object_Id :=
                                Version.Objects.Commit_Tree_Id
                                  (Version.Objects.Read_Object
                                     (Repo, S.Commit_Id));
                              New_Msg : constant String :=
                                (if E.Kind = Cmd_Squash
                                 then To_String (Prev_Msg)
                                      & Character'Val (10) & Character'Val (10)
                                      & IR_Full_Message (Repo, E.Id)
                                 else To_String (Prev_Msg));
                              Parents :
                                Version.Objects.Object_Id_Vectors.Vector;
                           begin
                              Parents.Append (Prev_Parent);
                              Replay_Head :=
                                Version.Write.Write_Commit_With_Author
                                  (Repo, Tree, Parents,
                                   To_String (Prev_Author), New_Msg);
                              Prev_Msg := To_Unbounded_String (New_Msg);
                           end;
                        end;
                  end case;
               end loop;

               Finish_Rebase
                 (Repo          => Repo,
                  Branch_Ref    => Branch_Ref,
                  Original_Head => Original_Head,
                  Target_Head   => Target_Head,
                  Final_Head    => Replay_Head);
            end;
         end if;
      end;
   end Start_Interactive;

   procedure Start_Root (Onto : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase detached HEAD";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "rebase already in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: revert in progress";
      end if;
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: merge state already exists";
      end if;

      Require_Clean_Working_Tree;

      declare
         Branch_Name : constant String :=
           Version.Refs.Current_Branch_Name (Repo);
         Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
         Original_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Target_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, Onto);
         Chain : Version.Rebase_State.Commit_Vectors.Vector;
      begin
         Version.Ref_Names.Require_Ref_Name (Branch_Ref);

         --  Collect the whole first-parent chain, newest first, then reverse
         --  it so the root commit is replayed first.
         declare
            Newest_First : Version.Rebase_State.Commit_Vectors.Vector;
            Walk : Version.Objects.Hex_Object_Id := Original_Head;
         begin
            loop
               Newest_First.Append (Walk);
               declare
                  Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
                    Version.Objects.Commit_Parent_Ids
                      (Version.Objects.Read_Object (Repo, Walk));
               begin
                  exit when Parents.Is_Empty;
                  Walk := Parents.First_Element;
               end;
            end loop;
            for I in reverse
              Newest_First.First_Index .. Newest_First.Last_Index
            loop
               Chain.Append (Newest_First.Element (I));
            end loop;
         end;

         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Branch_Ref,
            Original_Head       => Original_Head,
            Target_Head         => Target_Head,
            Current_Replay_Head => Target_Head,
            Next_Index          => 0,
            Commits             => Chain);

         begin
            Replay_Remaining
              (Repo                => Repo,
               Branch_Ref          => Branch_Ref,
               Original_Head       => Original_Head,
               Target_Head         => Target_Head,
               Current_Replay_Head => Target_Head,
               Next_Index          => 0,
               Commits             => Chain,
               Allow_Root          => True);
         exception
            when others =>
               declare
                  Preserve_State : Boolean := False;
               begin
                  if Version.Rebase_State.State_Exists (Repo) then
                     begin
                        Preserve_State :=
                          Version.Rebase_State.Paused
                            (Version.Rebase_State.Read_State (Repo));
                     exception
                        when others =>
                           Preserve_State := False;
                     end;
                  end if;
                  if not Preserve_State then
                     Version.Rebase_State.Clear_State (Repo);
                     Version.Merge_State.Clear_State (Repo);
                  end if;
               end;
               raise;
         end;
      end;
   end Start_Root;

   procedure Start_Root_Bare is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase detached HEAD";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "rebase already in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: revert in progress";
      end if;
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: merge state already exists";
      end if;

      Require_Clean_Working_Tree;

      declare
         Branch_Name : constant String :=
           Version.Refs.Current_Branch_Name (Repo);
         Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
         Original_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Chain : Version.Rebase_State.Commit_Vectors.Vector;
      begin
         Version.Ref_Names.Require_Ref_Name (Branch_Ref);

         --  Collect the whole first-parent chain, root first.
         declare
            Newest_First : Version.Rebase_State.Commit_Vectors.Vector;
            Walk : Version.Objects.Hex_Object_Id := Original_Head;
         begin
            loop
               Newest_First.Append (Walk);
               declare
                  Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
                    Version.Objects.Commit_Parent_Ids
                      (Version.Objects.Read_Object (Repo, Walk));
               begin
                  exit when Parents.Is_Empty;
                  Walk := Parents.First_Element;
               end;
            end loop;
            for I in reverse
              Newest_First.First_Index .. Newest_First.Last_Index
            loop
               Chain.Append (Newest_First.Element (I));
            end loop;
         end;

         --  Recreate the root commit parentless (empty base tree), then replay
         --  the remaining commits on top of it. New_Root becomes the base the
         --  state machine chains onto.
         declare
            Root_Id   : constant Version.Objects.Hex_Object_Id :=
              Chain.First_Element;
            Root_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id
                (Version.Objects.Read_Object (Repo, Root_Id));
            New_Root  : constant Version.Objects.Hex_Object_Id :=
              Write_Replayed_Commit
                (Repo      => Repo,
                 Tree_Id   => Root_Tree,
                 Parent_Id => Zero_Id,
                 Original  => Root_Id);
         begin
            Version.Rebase_State.Write_State
              (Repo                => Repo,
               Branch_Ref          => Branch_Ref,
               Original_Head       => Original_Head,
               Target_Head         => New_Root,
               Current_Replay_Head => New_Root,
               Next_Index          => 1,
               Commits             => Chain);

            begin
               Replay_Remaining
                 (Repo                => Repo,
                  Branch_Ref          => Branch_Ref,
                  Original_Head       => Original_Head,
                  Target_Head         => New_Root,
                  Current_Replay_Head => New_Root,
                  Next_Index          => 1,
                  Commits             => Chain,
                  Allow_Root          => True);
            exception
               when others =>
                  declare
                     Preserve_State : Boolean := False;
                  begin
                     if Version.Rebase_State.State_Exists (Repo) then
                        begin
                           Preserve_State :=
                             Version.Rebase_State.Paused
                               (Version.Rebase_State.Read_State (Repo));
                        exception
                           when others =>
                              Preserve_State := False;
                        end;
                     end if;
                     if not Preserve_State then
                        Version.Rebase_State.Clear_State (Repo);
                        Version.Merge_State.Clear_State (Repo);
                     end if;
                  end;
                  raise;
            end;
         end;
      end;
   end Start_Root_Bare;

   package Merges_Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);


   ------------------------  merges todo: generation  ------------------------

   --  A label has to be a usable ref component, and it has to be stable across
   --  a pause: the abbreviated id is both, and unlike a branch name it cannot
   --  collide with another side of the same topology.
   function Label_For (Id : Version.Objects.Hex_Object_Id) return String is
      Full : constant String := Version.Objects.To_String (Id);
   begin
      return Full (Full'First .. Full'First + 6);
   end Label_For;

   Onto_Label : constant String := "onto";

   --  Turn the topological order into git's todo grammar. A commit is labelled
   --  only when something later comes back to it -- a merge side, or a commit
   --  whose first parent is not the line we are already on -- because every
   --  label is a ref git has to write.
   function Build_Merges_Todo
     (Repo          : Version.Repository.Repository_Handle;
      Topo          : Version.Rebase_State.Commit_Vectors.Vector;
      In_Set        : Merges_Id_Sets.Set)
      return Version.Rebase_State.Todo_Command_Vectors.Vector
   is
      use Version.Rebase_State;

      Result : Todo_Command_Vectors.Vector;
      Needs_Label : Merges_Id_Sets.Set;

      function Position_Of (Id : Version.Objects.Hex_Object_Id) return Integer is
      begin
         for I in Topo.First_Index .. Topo.Last_Index loop
            if Topo.Element (I) = Id then
               return I;
            end if;
         end loop;
         return -1;
      end Position_Of;
   begin
      --  Pass one: who is come back to later.
      for I in Topo.First_Index .. Topo.Last_Index loop
         declare
            Parents : constant Version.History.Commit_Id_Vectors.Vector :=
              Version.History.Parent_Commits (Repo, Topo.Element (I));
            N : Natural := 0;
         begin
            for P of Parents loop
               if In_Set.Contains (P) then
                  --  A non-first parent is always a merge side; a first parent
                  --  only needs a name when it is not the previous command.
                  if N > 0 or else Position_Of (P) /= I - 1 then
                     Needs_Label.Include (P);
                  end if;
               end if;
               N := N + 1;
            end loop;
         end;
      end loop;

      --  Pass two: emit. `label onto` first, so a reset can always get back to
      --  the base even when the first commit does not sit on it.
      Result.Append
        (Todo_Command'
           (Kind  => Cmd_Label,
            Label => To_Unbounded_String (Onto_Label),
            others => <>));

      declare
         --  Which commit HEAD stands on. Zero means "not on a replayed commit
         --  yet", which forces the opening `reset onto` -- git emits one too,
         --  and it is what makes the todo self-contained rather than an
         --  assumption about where HEAD happened to be.
         Current : Version.Objects.Hex_Object_Id := Zero_Id;
      begin
         for I in Topo.First_Index .. Topo.Last_Index loop
            declare
               C : constant Version.Objects.Hex_Object_Id := Topo.Element (I);
               Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Parent_Commits (Repo, C);

               First_In_Set : constant Boolean :=
                 not Parents.Is_Empty
                 and then In_Set.Contains (Parents.First_Element);

               --  Where this commit has to be applied: its first parent when
               --  that is being replayed too, otherwise the base.
               Want : constant Version.Objects.Hex_Object_Id :=
                 (if First_In_Set then Parents.First_Element else Zero_Id);

               Merge_Sides : Version.Rebase_State.Commit_Vectors.Vector;
            begin
               for K in Parents.First_Index + 1 .. Parents.Last_Index loop
                  Merge_Sides.Append (Parents.Element (K));
               end loop;

               --  Only move when we are not already standing there. Resetting
               --  to where HEAD already is would name a label that was never
               --  written, because a commit only gets one when something has
               --  to come back to it.
               if Current /= Want then
                  Result.Append
                    (Todo_Command'
                       (Kind  => Cmd_Reset,
                        Label => To_Unbounded_String
                                   (if Want = Zero_Id then Onto_Label
                                    else Label_For (Want)),
                        others => <>));
               end if;

               if Merge_Sides.Is_Empty then
                  Result.Append
                    (Todo_Command'
                       (Kind => Cmd_Pick, Id => C, others => <>));
               else
                  --  One merge command carries every side, space separated:
                  --  an octopus is a single commit with N parents, so
                  --  emitting a command per side would build a chain of
                  --  two-parent merges instead.
                  declare
                     Labels : Unbounded_String;
                  begin
                     for Side of Merge_Sides loop
                        if Length (Labels) > 0 then
                           Append (Labels, " ");
                        end if;
                        Append
                          (Labels,
                           (if In_Set.Contains (Side) then Label_For (Side)
                            else Version.Objects.To_String (Side)));
                     end loop;

                     Result.Append
                       (Todo_Command'
                          (Kind => Cmd_Merge, Id => C, Label => Labels,
                           others => <>));
                  end;
               end if;

               if Needs_Label.Contains (C) then
                  Result.Append
                    (Todo_Command'
                       (Kind  => Cmd_Label,
                        Label => To_Unbounded_String (Label_For (C)),
                        others => <>));
               end if;

               Current := C;
            end;
         end loop;
      end;

      return Result;
   end Build_Merges_Todo;

   --  Execute a --rebase-merges todo from Start_At. Labels are refs under
   --  rebase-merge/refs/rewritten/, which is git's own mechanism, so a rebase
   --  paused here carries its whole topology on disk in a form git reads.
   procedure Replay_Merges_Remaining
     (Repo          : Version.Repository.Repository_Handle;
      Branch_Ref    : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Upstream_Head : Version.Objects.Hex_Object_Id;
      Todo          : Version.Rebase_State.Todo_Command_Vectors.Vector;
      Start_At      : Natural)
   is
      use Version.Rebase_State;

      Index : Natural := Start_At;

      function Rewritten_Path (Label : String) return String is
        (Join (Join (Join (Version.Repository.Git_Dir (Repo), "rebase-merge"),
                     "refs/rewritten"),
               Label));

      procedure Put_Label (Label : String; Id : Version.Objects.Hex_Object_Id)
      is
         Path : constant String := Rewritten_Path (Label);
      begin
         Version.Files.Create_Parent_Directories (Path);
         Version.Files.Write_Binary_File_Atomic
           (Path => Path, Content => To_String (Id) & Character'Val (10));
      end Put_Label;

      --  `onto` is the one label that exists before anything is executed, so
      --  it answers from the rebase's base rather than from a written ref.
      function Get_Label (Label : String) return Version.Objects.Hex_Object_Id
      is
         Path : constant String := Rewritten_Path (Label);
      begin
         if Version.Files.Is_Ordinary_File (Path) then
            declare
               Raw  : constant String :=
                 Version.Files.Read_Binary_File (Path);
               Last : Natural := Raw'Last;
            begin
               while Last >= Raw'First
                 and then (Raw (Last) = Character'Val (10)
                           or else Raw (Last) = Character'Val (13))
               loop
                  Last := Last - 1;
               end loop;
               return Version.Objects.To_Object_Id (Raw (Raw'First .. Last));
            end;
         end if;

         if Label = "onto" then
            return Upstream_Head;
         end if;

         --  A merge side outside the rebase set is named by its own id.
         if Version.Objects.Is_Valid_Hex_Object_Id (Label) then
            return Version.Objects.To_Object_Id (Label);
         end if;

         raise Ada.IO_Exceptions.Data_Error with
           "malformed rebase state: unknown label " & Label;
      end Get_Label;

      function Head_Id return Version.Objects.Hex_Object_Id is
        (Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo)));

      procedure Persist (Paused : Boolean; Cur : String) is
      begin
         Version.Rebase_State.Write_Merges_State
           (Repo           => Repo,
            Branch_Ref     => Branch_Ref,
            Original_Head  => Original_Head,
            Target_Head    => Upstream_Head,
            Todo           => Todo,
            Done_Count     => Index,
            Paused         => Paused,
            Current_Commit => Cur);
      end Persist;

      function Items_Of (C : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Cache : Version.Tree_Cache.Tree_Cache;
      begin
         return Version.Tree_Cache.Flatten_Tree
           (Repo, Cache,
            Version.Objects.Commit_Tree_Id
              (Version.Objects.Read_Object (Repo, C)));
      end Items_Of;

      --  Recreate one merge: HEAD is the first parent and the labelled commits
      --  the rest. An octopus is merged a side at a time but committed once,
      --  so it keeps all its parents. The original's message and authorship
      --  carry over, which is what `merge -C` means.
      procedure Do_Merge
        (Original : Version.Objects.Hex_Object_Id;
         Sides    : Version.Rebase_State.Commit_Vectors.Vector)
      is
         Ours : constant Version.Objects.Hex_Object_Id := Head_Id;
         Acc  : Version.Objects.Tree_Entry_Vectors.Vector := Items_Of (Ours);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Parent_Ids   : Version.Objects.Object_Id_Vectors.Vector;
      begin
         Version.Restore.Restore_Working_Tree_For_Commit (Repo, Ours);
         Version.Restore.Write_Index_For_Commit (Repo, Ours);
         Parent_Ids.Append (Ours);

         for Side of Sides loop
            declare
               Base : constant Version.Objects.Hex_Object_Id :=
                 Version.History.Merge_Base (Repo, Ours, Side);
               Conflicts : Version.Merge.Conflict_Vectors.Vector;
            begin
               Merged_Index.Clear;
               Version.Merge.Merge_Trees
                 (Repo          => Repo,
                  Current_Name  => "HEAD",
                  Target_Name   => Version.Merge.Commit_Label_For (Repo, Side),
                  Base_Items    => Items_Of (Base),
                  Current_Items => Acc,
                  Target_Items  => Items_Of (Side),
                  Merged_Index  => Merged_Index,
                  Conflicts     => Conflicts,
                  Behavior      => Version.Merge.Merge_Behavior'
                    (Base_Label => Ada.Strings.Unbounded.To_Unbounded_String
                       (Version.Merge.Base_Label_For (Repo, Base)),
                     others     => <>));

               if not Conflicts.Is_Empty then
                  Version.Merge_State.Clear_State (Repo);
                  Version.Merge_State.Write_State
                    (Repo          => Repo,
                     Current_Id    => Ours,
                     Target_Id     => Side,
                     Base_Id       => Base,
                     Target_Branch => "rebase",
                     Conflicts     => Conflicts);
                  Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
                  Persist (Paused => True, Cur => To_String (Original));
                  Write_Resume_For (Repo, Original);
                  raise Ada.IO_Exceptions.Data_Error with
                    "rebase paused: conflicts recorded";
               end if;

               Parent_Ids.Append (Side);

               declare
                  Cache : Version.Tree_Cache.Tree_Cache;
                  Tree  : constant Version.Objects.Hex_Object_Id :=
                    Version.Write.Write_Tree_From_Index (Repo, Merged_Index);
               begin
                  Acc := Version.Tree_Cache.Flatten_Tree (Repo, Cache, Tree);
               end;
            end;
         end loop;

         Version.Staging.Write (Repo => Repo, Entries => Merged_Index);

         declare
            Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo, Merged_Index);
            New_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit_With_Author
                (Repo, Tree, Parent_Ids,
                 IR_Author_Line (Repo, Original),
                 IR_Full_Message (Repo, Original));
         begin
            Move_Detached_Head
              (Repo, New_Commit,
               "rebase (merge): " & Replay_Subject (Repo, New_Commit));
            Version.Restore.Restore_Working_Tree_For_Commit (Repo, New_Commit);
            Version.Restore.Write_Index_For_Commit (Repo, New_Commit);
         end;
      end Do_Merge;
   begin
      --  Detach at the base before the first command, exactly as linear mode
      --  does; on resume HEAD is already where the todo left it.
      if not Version.Refs.Is_Detached (Repo) then
         Move_Detached_Head
           (Repo, Upstream_Head,
            "rebase (start): checkout " & To_String (Upstream_Head));
      end if;

      while Index < Natural (Todo.Length) loop
         declare
            C : constant Todo_Command := Todo.Element (Index);
         begin
            case C.Kind is
               when Cmd_Label =>
                  Put_Label (To_String (C.Label), Head_Id);

               when Cmd_Reset =>
                  declare
                     Target : constant Version.Objects.Hex_Object_Id :=
                       Get_Label (To_String (C.Label));
                  begin
                     Move_Detached_Head
                       (Repo, Target,
                        "rebase (reset): " & To_String (C.Label));
                     Version.Restore.Restore_Working_Tree_For_Commit
                       (Repo, Target);
                     Version.Restore.Write_Index_For_Commit (Repo, Target);
                  end;

               when Cmd_Pick =>
                  declare
                     R : constant Replay_Result :=
                       Replay_Commit (Repo, Head_Id, C.Id, Allow_Root => True);
                  begin
                     if R.Kind = Replay_Conflict then
                        Persist (Paused => True, Cur => To_String (C.Id));
                        Write_Resume_For (Repo, C.Id);
                        raise Ada.IO_Exceptions.Data_Error with
                          "rebase paused: conflicts recorded";
                     end if;
                     Move_Detached_Head
                       (Repo, R.Commit_Id,
                        "rebase (pick): "
                        & Replay_Subject (Repo, R.Commit_Id));
                  end;

               when Cmd_Merge =>
                  declare
                     Text  : constant String := To_String (C.Label);
                     Sides : Version.Rebase_State.Commit_Vectors.Vector;
                     First : Natural := Text'First;
                  begin
                     --  The label field holds every side, space separated.
                     while First <= Text'Last loop
                        declare
                           Last : Natural := First;
                        begin
                           while Last <= Text'Last
                             and then Text (Last) /= ' '
                           loop
                              Last := Last + 1;
                           end loop;
                           if Last > First then
                              Sides.Append
                                (Get_Label (Text (First .. Last - 1)));
                           end if;
                           First := Last + 1;
                        end;
                     end loop;
                     Do_Merge (C.Id, Sides);
                  end;
            end case;
         end;

         Index := Index + 1;
         Persist (Paused => False, Cur => "");
      end loop;

      Finish_Rebase
        (Repo          => Repo,
         Branch_Ref    => Branch_Ref,
         Original_Head => Original_Head,
         Target_Head   => Upstream_Head,
         Final_Head    => Head_Id);
   end Replay_Merges_Remaining;

   procedure Start_Rebase_Merges (Upstream : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      --  The same set type the todo builder takes, so the topology can be
      --  handed straight to it.
      package Id_Sets renames Merges_Id_Sets;
   begin
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot rebase detached HEAD";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "rebase already in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: cherry-pick in progress";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: revert in progress";
      end if;
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot rebase: merge state already exists";
      end if;

      Require_Clean_Working_Tree;

      declare
         Branch_Name : constant String :=
           Version.Refs.Current_Branch_Name (Repo);
         Branch_Ref  : constant String := "refs/heads/" & Branch_Name;
         Original_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Upstream_Head : constant Version.Objects.Hex_Object_Id :=
           Version.Revisions.Resolve_Commit (Repo, Upstream);

         In_Set  : Id_Sets.Set;
         Up_Anc  : Id_Sets.Set;
         Visited : Id_Sets.Set;
         Topo    : Version.Rebase_State.Commit_Vectors.Vector;

         --  Collect the ancestor set of Tip (inclusive).
         procedure Collect (Tip : Version.Objects.Hex_Object_Id;
                            Into : in out Id_Sets.Set) is
         begin
            if Into.Contains (Tip) then
               return;
            end if;
            Into.Insert (Tip);
            for P of Version.History.Parent_Commits (Repo, Tip) loop
               Collect (P, Into);
            end loop;
         end Collect;

         --  Post-order DFS over In_Set: parents before children.
         procedure Topo_Sort (C : Version.Objects.Hex_Object_Id) is
         begin
            if Visited.Contains (C) or else not In_Set.Contains (C) then
               return;
            end if;
            Visited.Insert (C);
            for P of Version.History.Parent_Commits (Repo, C) loop
               Topo_Sort (P);
            end loop;
            Topo.Append (C);
         end Topo_Sort;
      begin
         Version.Ref_Names.Require_Ref_Name (Branch_Ref);

         --  S = ancestors(HEAD) \ (ancestors(Upstream) inclusive).
         Collect (Upstream_Head, Up_Anc);
         declare
            Head_Anc : Id_Sets.Set;
         begin
            Collect (Original_Head, Head_Anc);
            for C of Head_Anc loop
               if not Up_Anc.Contains (C) then
                  In_Set.Insert (C);
               end if;
            end loop;
         end;

         Topo_Sort (Original_Head);

         --  Persist the initial (unpaused) merges state, then replay. On any
         --  paused-conflict raise the state is preserved for --continue; a
         --  hard error clears it (mirrors Start_Root's wrapper).
         declare
            Merges_Todo : constant
              Version.Rebase_State.Todo_Command_Vectors.Vector :=
                Build_Merges_Todo (Repo, Topo, In_Set);
         begin
            Version.Rebase_State.Write_Merges_State
              (Repo          => Repo,
               Branch_Ref    => Branch_Ref,
               Original_Head => Original_Head,
               Target_Head   => Upstream_Head,
               Todo          => Merges_Todo,
               Done_Count    => 0);

            Replay_Merges_Remaining
              (Repo          => Repo,
               Branch_Ref    => Branch_Ref,
               Original_Head => Original_Head,
               Upstream_Head => Upstream_Head,
               Todo          => Merges_Todo,
               Start_At      => 0);
         exception
            when others =>
               declare
                  Preserve_State : Boolean := False;
               begin
                  if Version.Rebase_State.State_Exists (Repo) then
                     begin
                        Preserve_State :=
                          Version.Rebase_State.Paused
                            (Version.Rebase_State.Read_State (Repo));
                     exception
                        when others =>
                           Preserve_State := False;
                     end;
                  end if;
                  if not Preserve_State then
                     Version.Rebase_State.Clear_State (Repo);
                     Version.Merge_State.Clear_State (Repo);
                  end if;
               end;
               raise;
         end;
      end;
   end Start_Rebase_Merges;

   procedure Continue_Rebase is
      use type Version.Rebase_State.Rebase_Action;
      use type Version.Rebase_State.Pause_Kind;
      use type Version.Rebase_State.Rebase_Mode;
      Repo  : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      State : constant Version.Rebase_State.Rebase_State := Version.Rebase_State.Read_State (Repo);
      Index_Items : Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts   : Version.Merge.Conflict_Vectors.Vector;
      Paused_Action : constant Version.Rebase_State.Rebase_Action :=
        (if Version.Rebase_State.Actions (State).Is_Empty
            or else not Version.Rebase_State.Paused (State)
         then Version.Rebase_State.Pick
         else Version.Rebase_State.Actions (State).Element
                (Version.Rebase_State.Actions (State).First_Index
                 + Version.Rebase_State.Next_Index (State)));
   begin
      Require_Current_Rebase_Branch
        (Repo       => Repo,
         Branch_Ref => Version.Rebase_State.Branch_Ref (State));

      if not Version.Rebase_State.Paused (State) then
         raise Ada.IO_Exceptions.Data_Error with "continue without paused conflict";
      end if;

      if Version.Rebase_State.Pause_Reason (State)
           = Version.Rebase_State.Pause_Exec
      then
         --  Exec-failure continue: skip the failed exec (git does not re-run it)
         --  and resume the todo from where it stopped, on the same replay head.
         Replay_Remaining
           (Repo                => Repo,
            Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
            Original_Head       => Version.Rebase_State.Original_Head (State),
            Target_Head         => Version.Rebase_State.Target_Head (State),
            Current_Replay_Head => Version.Rebase_State.Current_Replay_Head (State),
            Next_Index          => Version.Rebase_State.Next_Index (State),
            Commits             => Version.Rebase_State.Commits (State),
            Allow_Root          => True,
            Actions             => Version.Rebase_State.Actions (State),
            Execs               => Version.Rebase_State.Execs (State),
            Next_Exec           => Version.Rebase_State.Next_Exec (State) + 1);
         return;
      end if;

      if Version.Rebase_State.Mode (State) = Version.Rebase_State.Mode_Merges then
         --  Resume a --rebase-merges stop. The user resolved the index, so
         --  commit it as the command that stopped -- a pick keeps one parent,
         --  a merge both -- and hand the rest of the todo back to the driver.
         --
         --  The same preconditions as a linear continue: markers gone, index
         --  fully merged, and the resolution taken from what was staged.
         Require_Paused_Merge_State
           (Repo      => Repo,
            State     => State,
            Conflicts => Conflicts);

         if Conflict_Paths_Have_Markers (Repo => Repo, Conflicts => Conflicts)
         then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot continue rebase: conflict markers remain";
         end if;

         Require_Index_Fully_Merged (Repo);
         Version.Merge.Record_Rerere_Resolutions
           (Repo => Repo, Conflicts => Conflicts);
         Load_Staged_Index (Repo => Repo, Result => Index_Items);

         declare
            Todo : constant Version.Rebase_State.Todo_Command_Vectors.Vector :=
              Version.Rebase_State.Todo (State);
            At_Cmd : constant Natural := Version.Rebase_State.Done_Count (State);
            Stopped : constant Version.Objects.Hex_Object_Id :=
              Version.Rebase_State.Current_Commit (State);
            Upstream_Head : constant Version.Objects.Hex_Object_Id :=
              Version.Rebase_State.Target_Head (State);
            Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index
                (Repo => Repo, Entries => Index_Items);
            Parent_Ids : Version.Objects.Object_Id_Vectors.Vector;
            New_Commit : Version.Objects.Hex_Object_Id;
         begin
            Parent_Ids.Append
              (Version.Objects.To_Object_Id
                 (Version.Refs.Current_Commit_Id (Repo)));

            --  A merge command's second parent is the side it was merging;
            --  the resolved commit has to keep both or the topology is lost.
            if At_Cmd < Natural (Todo.Length)
              and then Version.Rebase_State."="
                         (Todo.Element (At_Cmd).Kind,
                          Version.Rebase_State.Cmd_Merge)
            then
               declare
                  Label : constant String :=
                    To_String (Todo.Element (At_Cmd).Label);
                  Path : constant String :=
                    Join (Join (Join (Version.Repository.Git_Dir (Repo),
                                      "rebase-merge"),
                                "refs/rewritten"),
                          Label);
               begin
                  if Version.Files.Is_Ordinary_File (Path) then
                     declare
                        Raw  : constant String :=
                          Version.Files.Read_Binary_File (Path);
                        Last : Natural := Raw'Last;
                     begin
                        while Last >= Raw'First
                          and then (Raw (Last) = Character'Val (10)
                                    or else Raw (Last) = Character'Val (13))
                        loop
                           Last := Last - 1;
                        end loop;
                        Parent_Ids.Append
                          (Version.Objects.To_Object_Id
                             (Raw (Raw'First .. Last)));
                     end;
                  elsif Version.Objects.Is_Valid_Hex_Object_Id (Label) then
                     Parent_Ids.Append
                       (Version.Objects.To_Object_Id (Label));
                  end if;
               end;
            end if;

            New_Commit :=
              Version.Write.Write_Commit_With_Author
                (Repo, Tree_Id, Parent_Ids,
                 IR_Author_Line (Repo, Stopped),
                 IR_Full_Message (Repo, Stopped));

            Version.Merge_State.Clear_State (Repo);
            Move_Detached_Head
              (Repo, New_Commit,
               "rebase (continue): " & Replay_Subject (Repo, New_Commit));
            Version.Restore.Restore_Working_Tree_For_Commit
              (Repo => Repo, Commit_Id => New_Commit);
            Version.Restore.Write_Index_For_Commit
              (Repo => Repo, Commit_Id => New_Commit);

            Replay_Merges_Remaining
              (Repo          => Repo,
               Branch_Ref    => Version.Rebase_State.Branch_Ref (State),
               Original_Head => Version.Rebase_State.Original_Head (State),
               Upstream_Head => Upstream_Head,
               Todo          => Todo,
               Start_At      => At_Cmd + 1);
         end;
         return;
      end if;

      if Paused_Action = Version.Rebase_State.Edit
        and then not Version.Merge_State.State_Exists (Repo)
      then
         --  Edit-stop continue (paused for edit, not conflict).
         --  The edit commit is already applied and the branch is at it (possibly
         --  amended by the user); resume the rest of the todo on top of the
         --  current branch tip.
         declare
            Actions : constant Version.Rebase_State.Action_Vectors.Vector :=
              Version.Rebase_State.Actions (State);
            Commits : constant Version.Rebase_State.Commit_Vectors.Vector :=
              Version.Rebase_State.Commits (State);
            Head : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
            Next : constant Natural := Version.Rebase_State.Next_Index (State) + 1;
         begin
            Version.Rebase_State.Write_State
              (Repo                => Repo,
               Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
               Original_Head       => Version.Rebase_State.Original_Head (State),
               Target_Head         => Version.Rebase_State.Target_Head (State),
               Current_Replay_Head => Head,
               Next_Index          => Next,
               Commits             => Commits,
               Actions             => Actions,
               Execs               => Version.Rebase_State.Execs (State),
               Next_Exec           => Version.Rebase_State.Next_Exec (State));
            Replay_Remaining
              (Repo                => Repo,
               Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
               Original_Head       => Version.Rebase_State.Original_Head (State),
               Target_Head         => Version.Rebase_State.Target_Head (State),
               Current_Replay_Head => Head,
               Next_Index          => Next,
               Commits             => Commits,
               Allow_Root          => True,
               Actions             => Actions,
               Execs               => Version.Rebase_State.Execs (State),
               Next_Exec           => Version.Rebase_State.Next_Exec (State));
            return;
         end;
      end if;

      Require_Paused_Merge_State
        (Repo      => Repo,
         State     => State,
         Conflicts => Conflicts);

      if Conflict_Paths_Have_Markers (Repo => Repo, Conflicts => Conflicts) then
         raise Ada.IO_Exceptions.Data_Error with "cannot continue rebase: conflict markers remain";
      end if;

      Require_Index_Fully_Merged (Repo);

      Version.Merge.Record_Rerere_Resolutions
        (Repo => Repo, Conflicts => Conflicts);

      Require_No_Untracked_During_Continue;
      Load_Staged_Index (Repo => Repo, Result => Index_Items);
      Version.Staging.Write (Repo => Repo, Entries => Index_Items);

      declare
         Actions : constant Version.Rebase_State.Action_Vectors.Vector :=
           Version.Rebase_State.Actions (State);
         Paused_Index : constant Natural := Version.Rebase_State.Next_Index (State);
         Current_Is_Reword : constant Boolean :=
           not Actions.Is_Empty
             and then Actions.Element (Actions.First_Index + Paused_Index)
                        = Version.Rebase_State.Reword;
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Index_Items);
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Write_Replayed_Commit
             (Repo             => Repo,
              Tree_Id          => Tree_Id,
              Parent_Id        => Version.Rebase_State.Current_Replay_Head (State),
              Original         => Version.Rebase_State.Current_Commit (State),
              Message_Override =>
                (if Current_Is_Reword
                 then Reword_Message
                        (Repo, Version.Rebase_State.Current_Commit (State))
                 else ""));
         Commits : constant Version.Rebase_State.Commit_Vectors.Vector :=
           Version.Rebase_State.Commits (State);
         Next_Index : constant Natural := Version.Rebase_State.Next_Index (State) + 1;
      begin
         Version.Merge_State.Clear_State (Repo);
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo => Repo, Commit_Id => New_Commit);
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => New_Commit);

         --  Note: a conflicting `edit` does not stop a second time -- the
         --  conflict stop already gave the amend opportunity, so continue
         --  proceeds (matches git, verified differentially).

         Version.Rebase_State.Write_State
           (Repo                => Repo,
            Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
            Original_Head       => Version.Rebase_State.Original_Head (State),
            Target_Head         => Version.Rebase_State.Target_Head (State),
            Current_Replay_Head => New_Commit,
            Next_Index          => Next_Index,
            Commits             => Commits,
            Actions             => Actions,
            Execs               => Version.Rebase_State.Execs (State),
            Next_Exec           => Version.Rebase_State.Next_Exec (State));
         Replay_Remaining
           (Repo                => Repo,
            Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
            Original_Head       => Version.Rebase_State.Original_Head (State),
            Target_Head         => Version.Rebase_State.Target_Head (State),
            Current_Replay_Head => New_Commit,
            Next_Index          => Next_Index,
            Commits             => Commits,
            Allow_Root          => True,
            Actions             => Actions,
            Execs               => Version.Rebase_State.Execs (State),
            Next_Exec           => Version.Rebase_State.Next_Exec (State));
      end;
   end Continue_Rebase;

   --  git's `--skip`: give up on the commit we stopped at and carry on with
   --  the rest. The conflicted worktree and index are thrown away in favour of
   --  the replay head, which is where the next commit is applied.
   procedure Skip_Rebase is
      Repo  : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      State : constant Version.Rebase_State.Rebase_State :=
        Version.Rebase_State.Read_State (Repo);
      Replay_Head : constant Version.Objects.Hex_Object_Id :=
        Version.Rebase_State.Current_Replay_Head (State);
   begin
      Require_Current_Rebase_Branch
        (Repo       => Repo,
         Branch_Ref => Version.Rebase_State.Branch_Ref (State));

      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Replay_Head);
      Version.Restore.Write_Index_For_Commit
        (Repo => Repo, Commit_Id => Replay_Head);
      Version.Merge_State.Clear_State (Repo);

      Replay_Remaining
        (Repo                => Repo,
         Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
         Original_Head       => Version.Rebase_State.Original_Head (State),
         Target_Head         => Version.Rebase_State.Target_Head (State),
         Current_Replay_Head => Replay_Head,
         Next_Index          => Version.Rebase_State.Next_Index (State) + 1,
         Commits             => Version.Rebase_State.Commits (State),
         Allow_Root          => True,
         Actions             => Version.Rebase_State.Actions (State),
         Execs               => Version.Rebase_State.Execs (State),
         Next_Exec           => Version.Rebase_State.Next_Exec (State));
   end Skip_Rebase;

   --  git's `--quit`: forget the rebase without undoing it. HEAD stays
   --  detached wherever the replay reached and the branch keeps its original
   --  tip -- the point being to keep the commits made so far, not to restore.
   procedure Quit_Rebase is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if not Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "no rebase in progress";
      end if;

      Version.Rebase_State.Clear_State (Repo);
      Version.Merge_State.Clear_State (Repo);
   end Quit_Rebase;

   procedure Abort_Rebase is
      Repo  : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      State : constant Version.Rebase_State.Rebase_State := Version.Rebase_State.Read_State (Repo);
      Old_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      Require_Current_Rebase_Branch
        (Repo       => Repo,
         Branch_Ref => Version.Rebase_State.Branch_Ref (State));

      Write_Branch_Ref
        (Repo       => Repo,
         Branch_Ref => Version.Rebase_State.Branch_Ref (State),
         Commit_Id  => Version.Rebase_State.Original_Head (State));
      --  Abort puts the user back where they started, which means back on the
      --  branch: HEAD has been detached for the whole rebase.
      Version.Refs.Write_Symbolic_HEAD
        (Repo   => Repo,
         Target => Version.Rebase_State.Branch_Ref (State));
      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo      => Repo,
         Commit_Id => Version.Rebase_State.Original_Head (State));
      Version.Restore.Write_Index_For_Commit
        (Repo      => Repo,
         Commit_Id => Version.Rebase_State.Original_Head (State));
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => (if Old_Id'Length = 0 then To_String (Zero_Id) else Old_Id),
         New_Id  => To_String (Version.Rebase_State.Original_Head (State)),
         Message => "rebase: abort");
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => Version.Rebase_State.Branch_Ref (State),
         Old_Id  => (if Old_Id'Length = 0 then To_String (Zero_Id) else Old_Id),
         New_Id  => To_String (Version.Rebase_State.Original_Head (State)),
         Message => "rebase: abort");
      Version.Rebase_State.Clear_State (Repo);
      Version.Merge_State.Clear_State (Repo);
   end Abort_Rebase;

   function In_Progress return Boolean is
   begin
      return Version.Rebase_State.State_Exists (Version.Repository.Open);
   end In_Progress;

end Version.Rebase;
