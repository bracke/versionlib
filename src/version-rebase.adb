with Ada.Calendar;
with Ada.Containers; use Ada.Containers;
with Ada.Containers.Ordered_Maps;
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
with Version.Staging;
with Version.Status;
with Version.Tree_Cache;
with Version.Working_Tree;
with Version.Write;

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
      if Version.Refs.Is_Detached (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue or abort rebase from detached HEAD";
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
      Epoch : constant Ada.Calendar.Time :=
        Ada.Calendar.Time_Of (Year => 1970, Month => 1, Day => 1);
      Now : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Seconds : constant Natural := Natural (Ada.Calendar."-" (Now, Epoch));
   begin
      return Natural_Image (Seconds);
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
      Append (Content, "parent " & To_String (Parent_Id) & Character'Val (10));
      Append (Content, Author_Line (Original_Obj) & Character'Val (10));
      Append
        (Content,
         "committer " & To_String (User.Name) & " <" & To_String (User.Email)
         & "> " & Timestamp_Line & Character'Val (10));
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
      if not Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue rebase: merge state missing";
      end if;

      Conflicts.Clear;
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

   procedure Build_Index_From_Working_Tree
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Version.Staging.Index_Entry_Vectors.Vector)
   is
      Files : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);
   begin
      Result.Clear;
      if not Files.Is_Empty then
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               File_Item : constant Version.Working_Tree.Working_File := Files.Element (I);
               Relative_Path : constant String := To_String (File_Item.Path);
               Absolute_Path : constant String := Join (Version.Repository.Root_Path (Repo), Relative_Path);
               Content : constant String := Version.Files.Read_Binary_File (Absolute_Path);
               Blob_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Blob (Repo => Repo, Content => Content);
            begin
               Result.Append
                 (Version.Staging.Index_Entry'
                    (Path => File_Item.Path,
                     Id   => Blob_Id,
                     Mode => To_Unbounded_String ("100644"),
                     Stage => 0));
            end;
         end loop;
      end if;
   end Build_Index_From_Working_Tree;

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
         Current_Name  => "rebase-current",
         Target_Name   => "rebase-commit",
         Base_Items    => Base_Items,
         Current_Items => Current_Items,
         Target_Items  => Target_Items,
         Merged_Index  => Merged_Index,
         Conflicts     => Conflicts);

      if not Conflicts.Is_Empty then
         Version.Merge_State.Clear_State (Repo);
         Version.Merge_State.Write_State
           (Repo          => Repo,
            Current_Id    => Replay_Parent,
            Target_Id     => Commit_Id,
            Base_Id       => Base_Id,
            Target_Branch => "rebase",
            Conflicts     => Conflicts);
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

   procedure Finish_Rebase
     (Repo          : Version.Repository.Repository_Handle;
      Branch_Ref    : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Target_Head   : Version.Objects.Hex_Object_Id;
      Final_Head    : Version.Objects.Hex_Object_Id) is
   begin
      Write_Branch_Ref (Repo => Repo, Branch_Ref => Branch_Ref, Commit_Id => Final_Head);
      Version.Restore.Restore_Working_Tree_For_Commit (Repo => Repo, Commit_Id => Final_Head);
      Version.Restore.Write_Index_For_Commit (Repo => Repo, Commit_Id => Final_Head);
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => "HEAD",
         Old_Id  => To_String (Original_Head),
         New_Id  => To_String (Final_Head),
         Message => "rebase: onto " & To_String (Target_Head));
      Version.Reflog.Append
        (Repo    => Repo,
         Ref     => Branch_Ref,
         Old_Id  => To_String (Original_Head),
         New_Id  => To_String (Final_Head),
         Message => "rebase: onto " & To_String (Target_Head));
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
        Version.Rebase_State.Action_Vectors.Empty_Vector)
   is
      use type Version.Rebase_State.Rebase_Action;
      Replay_Head : Version.Objects.Hex_Object_Id := Current_Replay_Head;
      Index       : Natural := Next_Index;

      function Is_Reword (I : Natural) return Boolean is
        (not Actions.Is_Empty
         and then Actions.Element (Actions.First_Index + I)
                    = Version.Rebase_State.Reword);

      function Is_Edit (I : Natural) return Boolean is
        (not Actions.Is_Empty
         and then Actions.Element (Actions.First_Index + I)
                    = Version.Rebase_State.Edit);
   begin
      while Index < Natural (Commits.Length) loop
         declare
            Commit_Id : constant Version.Objects.Hex_Object_Id := Commits.Element (Commits.First_Index + Index);
            Result : constant Replay_Result :=
              Replay_Commit (Repo => Repo, Replay_Parent => Replay_Head,
                             Commit_Id => Commit_Id, Allow_Root => Allow_Root,
                             Reword => Is_Reword (Index));
         begin
            if Result.Kind = Replay_Conflict then
               Version.Rebase_State.Write_State
                 (Repo                => Repo,
                  Branch_Ref          => Branch_Ref,
                  Original_Head       => Original_Head,
                  Target_Head         => Target_Head,
                  Current_Replay_Head => Replay_Head,
                  Next_Index          => Index,
                  Commits             => Commits,
                  Paused              => True,
                  Current_Commit      => To_String (Commit_Id),
                  Actions             => Actions);
               raise Ada.IO_Exceptions.Data_Error with "rebase paused: conflicts recorded";
            end if;

            Replay_Head := Result.Commit_Id;

            if Is_Edit (Index) then
               --  Stop for edit: move the branch onto the applied commit so the
               --  user can amend or add commits, leave a clean working tree, and
               --  pause with no merge state (which is how Continue_Rebase tells
               --  an edit-stop from a conflict-stop). Return cleanly -- an
               --  edit-stop is an intentional stop, not an error (git exits 0).
               Write_Branch_Ref
                 (Repo => Repo, Branch_Ref => Branch_Ref, Commit_Id => Replay_Head);
               Version.Restore.Restore_Working_Tree_For_Commit
                 (Repo => Repo, Commit_Id => Replay_Head);
               Version.Restore.Write_Index_For_Commit
                 (Repo => Repo, Commit_Id => Replay_Head);
               Version.Rebase_State.Write_State
                 (Repo                => Repo,
                  Branch_Ref          => Branch_Ref,
                  Original_Head       => Original_Head,
                  Target_Head         => Target_Head,
                  Current_Replay_Head => Replay_Head,
                  Next_Index          => Index,
                  Commits             => Commits,
                  Paused              => True,
                  Current_Commit      => To_String (Commit_Id),
                  Actions             => Actions);
               return;
            end if;

            Index := Index + 1;
            Version.Rebase_State.Write_State
              (Repo                => Repo,
               Branch_Ref          => Branch_Ref,
               Original_Head       => Original_Head,
               Target_Head         => Target_Head,
               Current_Replay_Head => Replay_Head,
               Next_Index          => Index,
               Commits             => Commits,
               Actions             => Actions);
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
               Commits             => Commits);
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
         Picked      : Version.Rebase_State.Commit_Vectors.Vector;
         Pick_Actions : Version.Rebase_State.Action_Vectors.Vector;
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

         if (Has_Reword or else Has_Edit) and then Has_Squash then
            raise Ada.IO_Exceptions.Data_Error with
              "interactive rebase: reword/edit combined with squash/fixup is "
              & "not supported";
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
               Actions             => Pick_Actions);

            begin
               Replay_Remaining
                 (Repo                => Repo,
                  Branch_Ref          => Branch_Ref,
                  Original_Head       => Original_Head,
                  Target_Head         => Target_Head,
                  Current_Replay_Head => Target_Head,
                  Next_Index          => 0,
                  Commits             => Picked,
                  Actions             => Pick_Actions);
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

   procedure Start_Rebase_Merges (Upstream : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      package Id_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Version.Objects.Object_Id_Storage);
      package Id_Maps is new Ada.Containers.Ordered_Maps
        (Key_Type     => Version.Objects.Object_Id_Storage,
         Element_Type => Version.Objects.Object_Id_Storage);

      function Tree_Of (C : Version.Objects.Hex_Object_Id)
         return Version.Objects.Hex_Object_Id is
        (Version.Objects.Commit_Tree_Id
           (Version.Objects.Read_Object (Repo, C)));

      function Items_Of (C : Version.Objects.Hex_Object_Id)
         return Version.Objects.Tree_Entry_Vectors.Vector
      is
         Cache : Version.Tree_Cache.Tree_Cache;
      begin
         return Version.Tree_Cache.Flatten_Tree (Repo, Cache, Tree_Of (C));
      end Items_Of;
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
         Map     : Id_Maps.Map;
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

         procedure Abort_Rebase_Merges is
         begin
            Version.Restore.Restore_Working_Tree_For_Commit
              (Repo, Original_Head);
            Version.Restore.Write_Index_For_Commit (Repo, Original_Head);
            Version.Merge_State.Clear_State (Repo);
            raise Ada.IO_Exceptions.Data_Error with
              "rebase --rebase-merges aborted: conflict "
              & "(resolution not supported)";
         end Abort_Rebase_Merges;
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

         for C of Topo loop
            declare
               Parents : constant Version.History.Commit_Id_Vectors.Vector :=
                 Version.History.Parent_Commits (Repo, C);
               Rebased : Version.Rebase_State.Commit_Vectors.Vector;
            begin
               for P of Parents loop
                  declare
                     RP : constant Version.Objects.Hex_Object_Id :=
                       (if In_Set.Contains (P) then Map.Element (P)
                        else Upstream_Head);
                     Dup : Boolean := False;
                  begin
                     for E of Rebased loop
                        if E = RP then
                           Dup := True;
                        end if;
                     end loop;
                     if not Dup then
                        Rebased.Append (RP);
                     end if;
                  end;
               end loop;

               if Natural (Rebased.Length) <= 1 then
                  --  Linear (or root): replay onto the single rebased parent
                  --  (Upstream_Head when the original parent is outside S).
                  declare
                     Onto : constant Version.Objects.Hex_Object_Id :=
                       (if Rebased.Is_Empty then Upstream_Head
                        else Rebased.First_Element);
                     R : constant Replay_Result :=
                       Replay_Commit (Repo, Onto, C, Allow_Root => True);
                  begin
                     if R.Kind = Replay_Conflict then
                        Abort_Rebase_Merges;
                     end if;
                     Map.Insert (C, R.Commit_Id);
                  end;

               elsif Natural (Rebased.Length) = 2 then
                  --  Recreate the merge of the two rebased parents.
                  declare
                     Base : constant Version.Objects.Hex_Object_Id :=
                       Version.History.Merge_Base
                         (Repo, Rebased.Element (0), Rebased.Element (1));
                     Merged_Index :
                       Version.Staging.Index_Entry_Vectors.Vector;
                     Conflicts : Version.Merge.Conflict_Vectors.Vector;
                  begin
                     Version.Merge.Merge_Trees
                       (Repo          => Repo,
                        Current_Name  => "rebase-merges-current",
                        Target_Name   => "rebase-merges-target",
                        Base_Items    => Items_Of (Base),
                        Current_Items => Items_Of (Rebased.Element (0)),
                        Target_Items  => Items_Of (Rebased.Element (1)),
                        Merged_Index  => Merged_Index,
                        Conflicts     => Conflicts);
                     if not Conflicts.Is_Empty then
                        Abort_Rebase_Merges;
                     end if;

                     declare
                        Tree : constant Version.Objects.Hex_Object_Id :=
                          Version.Write.Write_Tree_From_Index
                            (Repo, Merged_Index);
                        Parent_Ids :
                          Version.Objects.Object_Id_Vectors.Vector;
                     begin
                        Parent_Ids.Append (Rebased.Element (0));
                        Parent_Ids.Append (Rebased.Element (1));
                        Map.Insert
                          (C,
                           Version.Write.Write_Commit_With_Author
                             (Repo, Tree, Parent_Ids,
                              IR_Author_Line (Repo, C),
                              IR_Full_Message (Repo, C)));
                     end;
                  end;

               else
                  raise Ada.IO_Exceptions.Data_Error with
                    "rebase --rebase-merges: octopus merges not supported";
               end if;
            end;
         end loop;

         Finish_Rebase
           (Repo          => Repo,
            Branch_Ref    => Branch_Ref,
            Original_Head => Original_Head,
            Target_Head   => Upstream_Head,
            Final_Head    => Map.Element (Original_Head));
      end;
   end Start_Rebase_Merges;

   procedure Continue_Rebase is
      use type Version.Rebase_State.Rebase_Action;
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
               Actions             => Actions);
            Replay_Remaining
              (Repo                => Repo,
               Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
               Original_Head       => Version.Rebase_State.Original_Head (State),
               Target_Head         => Version.Rebase_State.Target_Head (State),
               Current_Replay_Head => Head,
               Next_Index          => Next,
               Commits             => Commits,
               Allow_Root          => True,
               Actions             => Actions);
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

      Version.Merge.Record_Rerere_Resolutions
        (Repo => Repo, Conflicts => Conflicts);

      Require_No_Untracked_During_Continue;
      Build_Index_From_Working_Tree (Repo => Repo, Result => Index_Items);
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
            Actions             => Actions);
         Replay_Remaining
           (Repo                => Repo,
            Branch_Ref          => Version.Rebase_State.Branch_Ref (State),
            Original_Head       => Version.Rebase_State.Original_Head (State),
            Target_Head         => Version.Rebase_State.Target_Head (State),
            Current_Replay_Head => New_Commit,
            Next_Index          => Next_Index,
            Commits             => Commits,
            Allow_Root          => True,
            Actions             => Actions);
      end;
   end Continue_Rebase;

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
