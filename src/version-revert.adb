with Ada.Containers; use Ada.Containers;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Compression;
with Version.Cherry_Pick_State;
with Version.Config;
with Version.Files;
with Version.Hooks;
with Version.Merge;
with Version.Merge_State;
with Version.Object_Cache;
with Version.Objects; use Version.Objects;
with Version.Rebase_State;
with Version.Replay_Finalization;
with Version.Refs;
with Version.Repository;
with Version.Restore;
with Version.Revisions;
with Version.Staging;
with Version.Status;
with Version.Tree_Cache;
with Version.Working_Tree;
with Version.Write;
with Version.Timestamps;

package body Version.Revert is

   Zero_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.Zero_Object_Id;

   type Replay_Result_Kind is (Replay_Clean, Replay_Conflict);
   type Replay_Result is record
      Kind      : Replay_Result_Kind;
      Commit_Id : Version.Objects.Object_Id_Storage := Zero_Id;
   end record;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Natural_Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Natural_Image;

   function Branch_Name_From_Ref (Branch_Ref : String) return String is
      Prefix : constant String := "refs/heads/";
   begin
      if Branch_Ref'Length <= Prefix'Length
        or else Branch_Ref (Branch_Ref'First .. Branch_Ref'First + Prefix'Length - 1) /= Prefix
      then
         raise Ada.IO_Exceptions.Data_Error with
           "malformed revert state: head ref";
      end if;
      return Branch_Ref (Branch_Ref'First + Prefix'Length .. Branch_Ref'Last);
   end Branch_Name_From_Ref;

   procedure Require_Current_Head
     (Repo  : Version.Repository.Repository_Handle;
      State : Version.Revert_State.State)
   is
      Actual_Head : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
   begin
      case Version.Revert_State.Kind (State) is
         when Version.Revert_State.Symbolic_Head =>
            if Version.Refs.Is_Detached (Repo)
              or else Version.Refs.Current_Branch_Name (Repo)
                /= Branch_Name_From_Ref (Version.Revert_State.Head_Ref (State))
            then
               raise Ada.IO_Exceptions.Data_Error with
                 "cannot continue or abort revert from a different HEAD";
            end if;
         when Version.Revert_State.Detached_Head =>
            if not Version.Refs.Is_Detached (Repo) then
               raise Ada.IO_Exceptions.Data_Error with
                 "cannot continue or abort revert from a different HEAD";
            end if;
      end case;

      if Actual_Head /= Version.Revert_State.Current_Head (State) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue or abort revert after HEAD moved";
      end if;
   end Require_Current_Head;

   procedure Require_Clean_Working_Tree is
      Result : constant Version.Status.Status_Result := Version.Status.Current_Status;
   begin
      if not Result.Changes.Is_Empty
        or else not Result.Staged.Is_Empty
        or else not Result.Untracked.Is_Empty
        or else not Result.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           "revert requires clean working tree";
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

   function Parent_For_Revert
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Mainline  : Natural)
      return Version.Objects.Hex_Object_Id
   is
      Obj     : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      elsif Parents.Is_Empty then
         if Mainline /= 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot use --mainline with non-merge commit";
         end if;
         return Zero_Id;
      elsif Parents.Length > 1 then
         if Mainline = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot revert merge commit without --mainline";
         elsif Mainline > Natural (Parents.Length) then
            raise Ada.IO_Exceptions.Data_Error with
              "revert mainline parent out of range";
         end if;
         return Parents.Element (Parents.First_Index + Mainline - 1);
      elsif Mainline /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot use --mainline with non-merge commit";
      end if;
      return Parents.First_Element;
   end Parent_For_Revert;

   function Parent_For_Revert
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Mainline  : Natural)
      return Version.Objects.Hex_Object_Id
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      elsif Parents.Is_Empty then
         if Mainline /= 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot use --mainline with non-merge commit";
         end if;
         return Zero_Id;
      elsif Parents.Length > 1 then
         if Mainline = 0 then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot revert merge commit without --mainline";
         elsif Mainline > Natural (Parents.Length) then
            raise Ada.IO_Exceptions.Data_Error with
              "revert mainline parent out of range";
         end if;
         return Parents.Element (Parents.First_Index + Mainline - 1);
      elsif Mainline /= 0 then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot use --mainline with non-merge commit";
      end if;
      return Parents.First_Element;
   end Parent_For_Revert;

   procedure Require_Ordinary_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Mainline  : Natural)
   is
      Ignore : constant Version.Objects.Hex_Object_Id :=
        Parent_For_Revert (Repo, Commit_Id, Mainline);
      pragma Unreferenced (Ignore);
   begin
      null;
   end Require_Ordinary_Commit;

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

   function Commit_Subject
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Msg : constant String := Commit_Message (Version.Objects.Read_Object (Repo, Commit_Id));
      Stop : Natural := Msg'First;
   begin
      if Msg'Length = 0 then
         return To_String (Commit_Id);
      end if;
      while Stop <= Msg'Last and then Msg (Stop) /= Character'Val (10) loop
         Stop := Stop + 1;
      end loop;
      if Stop = Msg'First then
         return To_String (Commit_Id);
      else
         return Msg (Msg'First .. Stop - 1);
      end if;
   end Commit_Subject;

   function Unix_Time_Image return String is
   begin
      return Natural_Image (Natural (Version.Timestamps.Unix_Now));
   end Unix_Time_Image;

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

   function Revert_Message
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String
   is
   begin
      return "Revert """ & Commit_Subject (Repo, Commit_Id) & """"
        & Character'Val (10) & Character'Val (10)
        & "This reverts commit " & To_String (Commit_Id) & "."
        & Character'Val (10);
   end Revert_Message;

   function Write_Revert_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Parent_Id : Version.Objects.Hex_Object_Id;
      Original  : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Content : Unbounded_String;
      Message : constant String :=
        Version.Hooks.Prepare_Commit_Message
          (Repo      => Repo,
           Message   => Revert_Message (Repo, Original),
           Run_Hooks => True);
   begin
      Append (Content, "tree " & To_String (Tree_Id) & Character'Val (10));
      Append (Content, "parent " & To_String (Parent_Id) & Character'Val (10));
      Append
        (Content,
         "author " & Version.Config.Author_Signature (Repo)
         & Character'Val (10));
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
   end Write_Revert_Commit;

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

   procedure Require_Paused_Merge_State
     (Repo      : Version.Repository.Repository_Handle;
      State     : Version.Revert_State.State;
      Conflicts : in out Version.Merge.Conflict_Vectors.Vector)
   is
      Current_Id    : Version.Objects.Object_Id_Storage;
      Target_Id     : Version.Objects.Object_Id_Storage;
      Base_Id       : Version.Objects.Object_Id_Storage;
      Target_Branch : Unbounded_String;
   begin
      if not Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue revert: merge state missing";
      end if;
      Conflicts.Clear;
      Version.Merge_State.Read_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Base_Id,
         Target_Branch => Target_Branch,
         Conflicts     => Conflicts);
      if To_String (Target_Branch) /= "revert"
        or else Current_Id /= Version.Revert_State.Current_Head (State)
        or else Target_Id /= Version.Revert_State.Current_Commit (State)
        or else Conflicts.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue revert: merge state does not match revert state";
      end if;
   end Require_Paused_Merge_State;

   procedure Require_No_Untracked_During_Continue is
      Result : constant Version.Status.Status_Result := Version.Status.Current_Status;
   begin
      if not Result.Untracked.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with
           "cannot continue revert: untracked files present";
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
                     Stage => 0, Skip_Worktree => False));
            end;
         end loop;
      end if;
   end Build_Index_From_Working_Tree;

   function Empty_Tree_Items return Version.Objects.Tree_Entry_Vectors.Vector is
      Result : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      return Result;
   end Empty_Tree_Items;

   function Replay_Commit
     (Repo          : Version.Repository.Repository_Handle;
      Replay_Parent : Version.Objects.Hex_Object_Id;
      Commit_Id     : Version.Objects.Hex_Object_Id;
      Mainline      : Natural)
      return Replay_Result
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Parent_Id : constant Version.Objects.Hex_Object_Id :=
        Parent_For_Revert (Repo, Objects, Commit_Id, Mainline);
      Base_Id : constant Version.Objects.Hex_Object_Id := Commit_Id;
      Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit (Repo, Objects, Replay_Parent);
      Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo    => Repo,
           Cache   => Trees,
           Tree_Id => Tree_Id_For_Commit (Repo, Objects, Commit_Id));
      Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Current_Tree_Id);
      Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        (if Parent_Id = Zero_Id then
           Empty_Tree_Items
         else
           Version.Tree_Cache.Flatten_Tree
             (Repo    => Repo,
              Cache   => Trees,
              Tree_Id => Tree_Id_For_Commit (Repo, Objects, Parent_Id)));
      Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts : Version.Merge.Conflict_Vectors.Vector;
   begin
      Version.Restore.Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Replay_Parent, Objects => Objects, Trees => Trees);
      Version.Restore.Write_Index_For_Commit
        (Repo => Repo, Commit_Id => Replay_Parent, Objects => Objects, Trees => Trees);

      Version.Merge.Merge_Trees
        (Repo          => Repo,
         Current_Name  => "HEAD",
         Target_Name   =>
           "parent of " & Version.Merge.Commit_Label_For (Repo, Commit_Id),
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
            Target_Branch => "revert",
            Conflicts     => Conflicts);
         return Replay_Result'(Kind => Replay_Conflict, Commit_Id => Zero_Id);
      end if;

      Version.Staging.Write (Repo => Repo, Entries => Merged_Index);
      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Merged_Index);
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Write_Revert_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => Replay_Parent,
              Original  => Commit_Id);
      begin
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo => Repo, Commit_Id => New_Commit, Objects => Objects, Trees => Trees);
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => New_Commit, Objects => Objects, Trees => Trees);
         return Replay_Result'(Kind => Replay_Clean, Commit_Id => New_Commit);
      end;
   end Replay_Commit;

   procedure Move_Head
     (Repo      : Version.Repository.Repository_Handle;
      Kind      : Version.Revert_State.Head_Kind;
      Head_Ref  : String;
      Old_Head  : Version.Objects.Hex_Object_Id;
      New_Head  : Version.Objects.Hex_Object_Id;
      Message   : String)
   is
      Final_Kind : Version.Replay_Finalization.Head_Kind;
   begin
      case Kind is
         when Version.Revert_State.Symbolic_Head =>
            Final_Kind := Version.Replay_Finalization.Symbolic_Head;
         when Version.Revert_State.Detached_Head =>
            Final_Kind := Version.Replay_Finalization.Detached_Head;
      end case;

      Version.Replay_Finalization.Advance_Head
        (Repo     => Repo,
         Kind     => Final_Kind,
         Head_Ref => Head_Ref,
         Old_Head => Old_Head,
         New_Head => New_Head,
         Message  => Message);
   end Move_Head;

   procedure Replay_Remaining
     (Repo          : Version.Repository.Repository_Handle;
      Kind          : Version.Revert_State.Head_Kind;
      Head_Ref      : String;
      Original_Head : Version.Objects.Hex_Object_Id;
      Current_Head  : Version.Objects.Hex_Object_Id;
      Next_Index    : Natural;
      Commits       : Version.Revert_State.Commit_Vectors.Vector;
      Mainline      : Natural)
   is
      Replay_Head : Version.Objects.Hex_Object_Id := Current_Head;
      Index       : Natural := Next_Index;
   begin
      while Index < Natural (Commits.Length) loop
         declare
            Commit_Id : constant Version.Objects.Hex_Object_Id :=
              Commits.Element (Commits.First_Index + Index);
            Result : constant Replay_Result :=
              Replay_Commit (Repo => Repo, Replay_Parent => Replay_Head, Commit_Id => Commit_Id, Mainline => Mainline);
         begin
            if Result.Kind = Replay_Conflict then
               Version.Revert_State.Write_State
                 (Repo           => Repo,
                  Kind           => Kind,
                  Head_Ref       => Head_Ref,
                  Original_Head  => Original_Head,
                  Current_Head   => Replay_Head,
                  Next_Index     => Index,
                  Commits        => Commits,
                  Mainline       => Mainline,
                  Paused         => True,
                  Current_Commit => To_String (Commit_Id));
               raise Ada.IO_Exceptions.Data_Error with "revert paused: conflicts recorded";
            end if;

            declare
               Old_Head : constant Version.Objects.Hex_Object_Id := Replay_Head;
               Message : constant String := "revert: " & Commit_Subject (Repo, Commit_Id);
            begin
               Replay_Head := Result.Commit_Id;
               Move_Head
                 (Repo     => Repo,
                  Kind     => Kind,
                  Head_Ref => Head_Ref,
                  Old_Head => Old_Head,
                  New_Head => Replay_Head,
                  Message  => Message);
            end;

            Index := Index + 1;
            Version.Revert_State.Write_State
              (Repo          => Repo,
               Kind          => Kind,
               Head_Ref      => Head_Ref,
               Original_Head => Original_Head,
               Current_Head  => Replay_Head,
               Next_Index    => Index,
               Commits       => Commits,
               Mainline      => Mainline);
         end;
      end loop;

      Version.Revert_State.Clear_State (Repo);
      Version.Merge_State.Clear_State (Repo);
   end Replay_Remaining;

   procedure Start
     (Revisions : Version.Revert_State.Commit_Vectors.Vector;
      Mainline  : Natural := 0)
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Kind : Version.Revert_State.Head_Kind;
      Head_Ref : Unbounded_String;
      Original_Head : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
   begin
      if Revisions.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with "revert requires a revision";
      end if;
      if Version.Revert_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "revert already in progress";
      end if;
      if Version.Rebase_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot revert: rebase in progress";
      end if;
      if Version.Cherry_Pick_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot revert: cherry-pick in progress";
      end if;
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with "cannot revert: merge state already exists";
      end if;
      Require_Clean_Working_Tree;

      if Version.Refs.Is_Detached (Repo) then
         Kind := Version.Revert_State.Detached_Head;
         Head_Ref := To_Unbounded_String ("");
      else
         Kind := Version.Revert_State.Symbolic_Head;
         Head_Ref := To_Unbounded_String ("refs/heads/" & Version.Refs.Current_Branch_Name (Repo));
      end if;

      for I in Revisions.First_Index .. Revisions.Last_Index loop
         Require_Ordinary_Commit (Repo, Revisions.Element (I), Mainline);
      end loop;

      Version.Revert_State.Write_State
        (Repo          => Repo,
         Kind          => Kind,
         Head_Ref      => To_String (Head_Ref),
         Original_Head => Original_Head,
         Current_Head  => Original_Head,
         Next_Index    => 0,
         Commits       => Revisions,
         Mainline      => Mainline);

      begin
         Replay_Remaining
           (Repo          => Repo,
            Kind          => Kind,
            Head_Ref      => To_String (Head_Ref),
            Original_Head => Original_Head,
            Current_Head  => Original_Head,
            Next_Index    => 0,
            Commits       => Revisions,
            Mainline      => Mainline);
      exception
         when others =>
            declare
               Preserve_State : Boolean := False;
            begin
               if Version.Revert_State.State_Exists (Repo) then
                  begin
                     Preserve_State := Version.Revert_State.Paused
                       (Version.Revert_State.Read_State (Repo));
                  exception
                     when others => Preserve_State := False;
                  end;
               end if;
               if not Preserve_State then
                  Version.Revert_State.Clear_State (Repo);
                  Version.Merge_State.Clear_State (Repo);
               end if;
            end;
            raise;
      end;
   end Start;

   procedure Start (Revision : String) is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Commits.Append (Version.Revisions.Resolve_Commit (Repo => Repo, Text => Revision));
      Start (Commits);
   end Start;

   procedure Start (Revision : String; Mainline : Natural) is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Commits : Version.Revert_State.Commit_Vectors.Vector;
   begin
      Commits.Append (Version.Revisions.Resolve_Commit (Repo => Repo, Text => Revision));
      Start (Commits, Mainline);
   end Start;

   procedure Continue_Revert is
      Repo  : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      State : constant Version.Revert_State.State := Version.Revert_State.Read_State (Repo);
      Index_Items : Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts   : Version.Merge.Conflict_Vectors.Vector;
   begin
      Require_Current_Head (Repo, State);
      if not Version.Revert_State.Paused (State) then
         raise Ada.IO_Exceptions.Data_Error with "continue without paused conflict";
      end if;
      Require_Paused_Merge_State (Repo => Repo, State => State, Conflicts => Conflicts);
      if Conflict_Paths_Have_Markers (Repo => Repo, Conflicts => Conflicts) then
         raise Ada.IO_Exceptions.Data_Error with "cannot continue revert: conflict markers remain";
      end if;

      Version.Merge.Record_Rerere_Resolutions
        (Repo => Repo, Conflicts => Conflicts);

      Require_No_Untracked_During_Continue;
      Build_Index_From_Working_Tree (Repo => Repo, Result => Index_Items);
      Version.Staging.Write (Repo => Repo, Entries => Index_Items);

      declare
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Index_Items);
         New_Commit : constant Version.Objects.Hex_Object_Id :=
           Write_Revert_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => Version.Revert_State.Current_Head (State),
              Original  => Version.Revert_State.Current_Commit (State));
         Commits : constant Version.Revert_State.Commit_Vectors.Vector :=
           Version.Revert_State.Commits (State);
         Next_Index : constant Natural := Version.Revert_State.Next_Index (State) + 1;
      begin
         Version.Merge_State.Clear_State (Repo);
         Move_Head
           (Repo     => Repo,
            Kind     => Version.Revert_State.Kind (State),
            Head_Ref => Version.Revert_State.Head_Ref (State),
            Old_Head => Version.Revert_State.Current_Head (State),
            New_Head => New_Commit,
            Message  => "revert: " &
              Commit_Subject (Repo, Version.Revert_State.Current_Commit (State)));
         Version.Revert_State.Write_State
           (Repo          => Repo,
            Kind          => Version.Revert_State.Kind (State),
            Head_Ref      => Version.Revert_State.Head_Ref (State),
            Original_Head => Version.Revert_State.Original_Head (State),
            Current_Head  => New_Commit,
            Next_Index    => Next_Index,
            Commits       => Commits,
            Mainline      => Version.Revert_State.Mainline (State));
         Replay_Remaining
           (Repo          => Repo,
            Kind          => Version.Revert_State.Kind (State),
            Head_Ref      => Version.Revert_State.Head_Ref (State),
            Original_Head => Version.Revert_State.Original_Head (State),
            Current_Head  => New_Commit,
            Next_Index    => Next_Index,
            Commits       => Commits,
            Mainline      => Version.Revert_State.Mainline (State));
      end;
   end Continue_Revert;

   procedure Abort_Revert is
      Repo  : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      State : constant Version.Revert_State.State := Version.Revert_State.Read_State (Repo);
      Old_Head : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
   begin
      Require_Current_Head (Repo, State);
      Move_Head
        (Repo     => Repo,
         Kind     => Version.Revert_State.Kind (State),
         Head_Ref => Version.Revert_State.Head_Ref (State),
         Old_Head => Old_Head,
         New_Head => Version.Revert_State.Original_Head (State),
         Message  => "revert: abort");
      Version.Revert_State.Clear_State (Repo);
      Version.Merge_State.Clear_State (Repo);
   end Abort_Revert;

end Version.Revert;
