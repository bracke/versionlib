with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers;        use Ada.Containers;
with Ada.Containers.Indefinite_Ordered_Maps;
with Version.Objects;
with Version.Refs;
with Version.Repository;
with Version.Staging;
with Version.Working_Tree;
with Version.Ignore;
with Version.Files;
with Version.Tracking;
with Version.Object_Cache;
with Version.Ref_Cache;
with Version.Tree_Cache;
with Version.Sparse;
with Version.Merge;
with Version.Merge_State;

package body Version.Status is
   use Version.Objects;

   use type Ada.Directories.File_Kind;

   function Kind_Image (Kind : Change_Kind) return String is
   begin
      case Kind is
         when New_File      =>
            return "added";

         when Modified_File =>
            return "modified";

         when Deleted_File  =>
            return "deleted";

         when Ignored_File  =>
            return "ignored";

         when Unmerged_File =>
            return "unmerged";

         when Both_Added_File =>
            return "both added";

         when Deleted_Modified_File =>
            return "deleted/modified";

         when Directory_File_Conflict_File =>
            return "directory/file conflict";

         when Binary_Conflict_File =>
            return "binary conflict";
      end case;
   end Kind_Image;

   function Clean_Status_Line return String is
   begin
      return "nothing to save, working tree clean";
   end Clean_Status_Line;

   function Change_Kind_Text (Kind : Change_Kind) return String is
   begin
      return Kind_Image (Kind);
   end Change_Kind_Text;

   function Change_Output_Line
     (Kind : Change_Kind; Path : String) return String is
   begin
      return "  " & Change_Kind_Text (Kind) & ": " & Path;
   end Change_Output_Line;

   function Porcelain_Kind_Code (Kind : Change_Kind) return String is
   begin
      case Kind is
         when New_File      =>
            return "A";

         when Modified_File =>
            return "M";

         when Deleted_File  =>
            return "D";

         when Ignored_File  =>
            return "!";

         when Unmerged_File | Binary_Conflict_File =>
            return "UU";

         when Both_Added_File =>
            return "AA";

         when Deleted_Modified_File =>
            return "DU";

         when Directory_File_Conflict_File =>
            return "DF";
      end case;
   end Porcelain_Kind_Code;

   procedure Append_Porcelain_List
     (Text   : in out Unbounded_String;
      Prefix : String;
      List   : File_Change_Vectors.Vector) is
   begin
      if List.Is_Empty then
         return;
      end if;

      for I in List.First_Index .. List.Last_Index loop
         Append
           (Text,
            Prefix
            & " "
            & Porcelain_Kind_Code (List.Element (I).Kind)
            & " "
            & To_String (List.Element (I).Path)
            & Ada.Characters.Latin_1.LF);
      end loop;
   end Append_Porcelain_List;

   function Porcelain_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String
   is
      Text : Unbounded_String;
   begin
      --  Project-specific stable porcelain subset.  Prefixes identify the
      --  source of each change instead of promising full Git porcelain parity:
      --    U <UU|AA|DU|DF> path  unmerged/conflicted path
      --    S <A|M|D> path        staged/index change
      --    W <A|M|D> path        working-tree change
      --    ? A path              untracked file
      --    ! ! path              ignored untracked path, when requested
      --  Clean status intentionally prints no output.
      Append_Porcelain_List (Text, "U", Result.Conflicted);
      Append_Porcelain_List (Text, "S", Result.Staged);
      Append_Porcelain_List (Text, "W", Result.Changes);
      Append_Porcelain_List (Text, "?", Result.Untracked);
      if Include_Ignored then
         Append_Porcelain_List (Text, "!", Result.Ignored);
      end if;
      return To_String (Text);
   end Porcelain_Status_Text;

   function Short_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String
   is
   begin
      return Porcelain_Status_Text (Result, Include_Ignored);
   end Short_Status_Text;

   function Natural_Image (Value : Natural) return String;
   function Commit_Word (Count : Natural) return String;
   function Short_Id (Id : String) return String;

   function Remote_Branch_Name (Merge_Ref : String) return String is
      Prefix : constant String := "refs/heads/";
   begin
      if Merge_Ref'Length >= Prefix'Length
        and then
          Merge_Ref (Merge_Ref'First .. Merge_Ref'First + Prefix'Length - 1)
          = Prefix
      then
         return Merge_Ref (Merge_Ref'First + Prefix'Length .. Merge_Ref'Last);
      else
         return Merge_Ref;
      end if;
   end Remote_Branch_Name;

   procedure Append_Ahead_Behind_Summary
     (Text : in out Unbounded_String; Counts : Version.Tracking.Ahead_Behind)
   is
      Need_Comma : Boolean := False;
   begin
      if Counts.Ahead = 0 and then Counts.Behind = 0 then
         return;
      end if;

      Append (Text, " [");
      if Counts.Ahead > 0 then
         Append (Text, "ahead " & Natural_Image (Counts.Ahead));
         Need_Comma := True;
      end if;

      if Counts.Behind > 0 then
         if Need_Comma then
            Append (Text, ", ");
         end if;
         Append (Text, "behind " & Natural_Image (Counts.Behind));
      end if;
      Append (Text, "]");
   end Append_Ahead_Behind_Summary;

   function Branch_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
      Text : Unbounded_String;
   begin
      if Version.Refs.Is_Attached (Head) then
         declare
            Branch : constant String := Version.Refs.Branch_Name (Head);
         begin
            Append (Text, "## " & Branch);

            begin
               if Version.Tracking.Has_Upstream (Repo, Branch) then
                  declare
                     Info          : constant Version.Tracking.Upstream_Info :=
                       Version.Tracking.Upstream (Repo, Branch);
                     Counts        : constant Version.Tracking.Ahead_Behind :=
                       Version.Tracking.Count_Ahead_Behind (Repo, Branch);
                     Remote        : constant String :=
                       To_String (Info.Remote);
                     Remote_Branch : constant String :=
                       Remote_Branch_Name (To_String (Info.Merge));
                  begin
                     Append (Text, "..." & Remote & "/" & Remote_Branch);
                     Append_Ahead_Behind_Summary (Text, Counts);
                  end;
               end if;
            exception
               when Ada.Text_IO.Data_Error | Ada.IO_Exceptions.Data_Error =>
                  null;
            end;
         end;
      else
         Append
           (Text,
            "## HEAD (detached at "
            & Short_Id (Version.Refs.Commit_Id (Head))
            & ")");
      end if;

      Append (Text, Ada.Characters.Latin_1.LF);
      Append (Text, Porcelain_Status_Text (Result, Include_Ignored));
      return To_String (Text);
   end Branch_Status_Text;

   package Path_Position_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Natural);

   function Head_Map
     (Entries : Version.Objects.Tree_Entry_Vectors.Vector)
      return Path_Position_Maps.Map
   is
      Result : Path_Position_Maps.Map;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Include (To_String (Entries.Element (I).Path), I);
         end loop;
      end if;

      return Result;
   end Head_Map;

   function Index_Map
     (Entries : Version.Staging.Index_Entry_Vectors.Vector)
      return Path_Position_Maps.Map
   is
      Result : Path_Position_Maps.Map;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            if Entries.Element (I).Stage = 0 then
               Result.Include (To_String (Entries.Element (I).Path), I);
            end if;
         end loop;
      end if;

      return Result;
   end Index_Map;

   function Working_Map
     (Entries : Version.Working_Tree.Working_File_Vectors.Vector)
      return Path_Position_Maps.Map
   is
      Result : Path_Position_Maps.Map;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Result.Include (To_String (Entries.Element (I).Path), I);
         end loop;
      end if;

      return Result;
   end Working_Map;

   procedure Add_Change
     (List : in out File_Change_Vectors.Vector;
      Path : String;
      Kind : Change_Kind) is
   begin
      List.Append
        (File_Change'(Path => To_Unbounded_String (Path), Kind => Kind));
   end Add_Change;

   function Build_Status
     (Head_Entries    : Version.Objects.Tree_Entry_Vectors.Vector;
      Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files   : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector)
      return Status_Result
   is
      Result      : Status_Result;
      Head_Pos    : constant Path_Position_Maps.Map := Head_Map (Head_Entries);
      Index_Pos   : constant Path_Position_Maps.Map :=
        Index_Map (Index_Entries);
      Working_Pos : constant Path_Position_Maps.Map :=
        Working_Map (Working_Files);
   begin
      if not Head_Entries.Is_Empty then
         for I in Head_Entries.First_Index .. Head_Entries.Last_Index loop
            declare
               Path : constant String :=
                 To_String (Head_Entries.Element (I).Path);
               Pos  : constant Path_Position_Maps.Cursor :=
                 Index_Pos.Find (Path);
            begin
               if not Path_Position_Maps.Has_Element (Pos) then
                  Add_Change (Result.Staged, Path, Deleted_File);
               elsif Index_Entries.Element (Path_Position_Maps.Element (Pos))
                       .Id
                 /= Head_Entries.Element (I).Id
               then
                  Add_Change (Result.Staged, Path, Modified_File);
               end if;
            end;
         end loop;
      end if;

      if not Index_Entries.Is_Empty then
         for I in Index_Entries.First_Index .. Index_Entries.Last_Index loop
            if Index_Entries.Element (I).Stage = 0 then
               declare
                  Path : constant String :=
                    To_String (Index_Entries.Element (I).Path);
                  Pos  : constant Path_Position_Maps.Cursor :=
                    Head_Pos.Find (Path);
               begin
                  if not Path_Position_Maps.Has_Element (Pos) then
                     Add_Change (Result.Staged, Path, New_File);
                  end if;
               end;
            end if;
         end loop;
      end if;

      if not Index_Entries.Is_Empty then
         for I in Index_Entries.First_Index .. Index_Entries.Last_Index loop
            if Index_Entries.Element (I).Stage = 0 then
               declare
                  Path : constant String :=
                    To_String (Index_Entries.Element (I).Path);
                  Pos  : constant Path_Position_Maps.Cursor :=
                    Working_Pos.Find (Path);
               begin
                  if not Path_Position_Maps.Has_Element (Pos) then
                     if (not Sparse_Enabled)
                       or else
                         Version.Pathspec.Matches_Any (Sparse_Patterns, Path)
                     then
                        Add_Change (Result.Changes, Path, Deleted_File);
                     end if;
                  elsif Working_Files.Element (Path_Position_Maps.Element (Pos))
                          .Id
                    /= Index_Entries.Element (I).Id
                  then
                     Add_Change (Result.Changes, Path, Modified_File);
                  end if;
               end;
            end if;
         end loop;
      end if;

      if not Working_Files.Is_Empty then
         for I in Working_Files.First_Index .. Working_Files.Last_Index loop
            declare
               Path : constant String :=
                 To_String (Working_Files.Element (I).Path);
               Pos  : constant Path_Position_Maps.Cursor :=
                 Index_Pos.Find (Path);
            begin
               if not Path_Position_Maps.Has_Element (Pos)
                 and then
                   ((not Sparse_Enabled)
                    or else
                      Version.Pathspec.Matches_Any (Sparse_Patterns, Path))
                 and then
                   not Version.Ignore.Is_Ignored
                         (Rules         => Ignore_Rules,
                          Relative_Path => Path,
                          Is_Directory  => False)
               then
                  Add_Change (Result.Untracked, Path, New_File);
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Build_Status;

   function Build_Ignored
     (Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files   : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector)
      return File_Change_Vectors.Vector
   is
      Result    : File_Change_Vectors.Vector;
      Index_Pos : constant Path_Position_Maps.Map := Index_Map (Index_Entries);
   begin
      if not Working_Files.Is_Empty then
         for I in Working_Files.First_Index .. Working_Files.Last_Index loop
            declare
               Path : constant String :=
                 To_String (Working_Files.Element (I).Path);
               Pos  : constant Path_Position_Maps.Cursor :=
                 Index_Pos.Find (Path);
            begin
               if not Path_Position_Maps.Has_Element (Pos)
                 and then
                   ((not Sparse_Enabled)
                    or else Version.Pathspec.Matches_Any (Sparse_Patterns, Path))
                 and then
                   (Pathspecs.Is_Empty
                    or else Version.Pathspec.Matches_Any (Pathspecs, Path))
                 and then
                   Version.Ignore.Is_Ignored
                     (Rules         => Ignore_Rules,
                      Relative_Path => Path,
                      Is_Directory  => False)
               then
                  Add_Change (Result, Path, Ignored_File);
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Build_Ignored;

   function Conflict_Change_Kind
     (Kind : Version.Merge.Conflict_Kind) return Change_Kind is
   begin
      case Kind is
         when Version.Merge.Content_Conflict =>
            return Unmerged_File;
         when Version.Merge.Add_Add_Conflict =>
            return Both_Added_File;
         when Version.Merge.Delete_Modify_Conflict =>
            return Deleted_Modified_File;
         when Version.Merge.Directory_File_Conflict =>
            return Directory_File_Conflict_File;
         when Version.Merge.Binary_Conflict =>
            return Binary_Conflict_File;
      end case;
   end Conflict_Change_Kind;

   procedure Append_Merge_Conflicts
     (Repo   : Version.Repository.Repository_Handle;
      Result : in out Status_Result)
   is
      Current_Id    : Version.Objects.Object_Id_Storage;
      Target_Id     : Version.Objects.Object_Id_Storage;
      Base_Id       : Version.Objects.Object_Id_Storage;
      Target_Branch : Ada.Strings.Unbounded.Unbounded_String;
      Conflicts     : Version.Merge.Conflict_Vectors.Vector;
   begin
      if not Version.Merge_State.State_Exists (Repo) then
         return;
      end if;

      Version.Merge_State.Read_State
        (Repo          => Repo,
         Current_Id    => Current_Id,
         Target_Id     => Target_Id,
         Base_Id       => Base_Id,
         Target_Branch => Target_Branch,
         Conflicts     => Conflicts);

      if not Conflicts.Is_Empty then
         for I in Conflicts.First_Index .. Conflicts.Last_Index loop
            declare
               C : constant Version.Merge.Conflict := Conflicts.Element (I);
            begin
               Add_Change
                 (Result.Conflicted,
                  To_String (C.Path),
                  Conflict_Change_Kind (C.Kind));
            end;
         end loop;
      end if;
   end Append_Merge_Conflicts;

   function Status_Path_Text (Path : String) return String is
   begin
      return Version.Files.Normalize_Separators (Path);
   end Status_Path_Text;

   function Status_Relative_Path (Root : String; Full : String) return String is
      Normal_Root : constant String := Status_Path_Text (Root);
      Normal_Full : constant String := Status_Path_Text (Full);
      Root_Last   : Natural := Normal_Root'Last;
   begin
      while Root_Last >= Normal_Root'First
        and then Normal_Root (Root_Last) = '/'
      loop
         if Root_Last = Normal_Root'First then
            exit;
         end if;
         Root_Last := Root_Last - 1;
      end loop;

      if Normal_Full'Length <= Root_Last - Normal_Root'First + 1 then
         return "";
      elsif Normal_Full
              (Normal_Full'First
               .. Normal_Full'First + Root_Last - Normal_Root'First)
        /= Normal_Root (Normal_Root'First .. Root_Last)
      then
         return Normal_Full;
      elsif Normal_Full (Normal_Full'First + Root_Last - Normal_Root'First + 1)
        = '/'
      then
         return
           Normal_Full
             (Normal_Full'First
              + Root_Last
              - Normal_Root'First
              + 2
              .. Normal_Full'Last);
      else
         return
           Normal_Full
             (Normal_Full'First
              + Root_Last
              - Normal_Root'First
              + 1
              .. Normal_Full'Last);
      end if;
   end Status_Relative_Path;

   function Has_Tracked_Path_Under
     (Index_Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Dir_Path      : String) return Boolean
   is
   begin
      if Index_Entries.Is_Empty then
         return False;
      end if;

      for I in Index_Entries.First_Index .. Index_Entries.Last_Index loop
         declare
            Path : constant String := To_String (Index_Entries.Element (I).Path);
         begin
            if Index_Entries.Element (I).Stage = 0
              and then Path'Length > Dir_Path'Length
              and then Path (Path'First .. Path'First + Dir_Path'Length - 1)
                       = Dir_Path
              and then Path (Path'First + Dir_Path'Length) = '/'
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Tracked_Path_Under;

   function Is_Sparse_Included
     (Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      Path            : String;
      Is_Directory    : Boolean) return Boolean is
   begin
      return
        (not Sparse_Enabled)
        or else
          Version.Pathspec.Matches_Any
            (Sparse_Patterns, Path, Is_Directory => Is_Directory);
   end Is_Sparse_Included;

   function Pathspec_Selects
     (Pathspecs    : Version.Pathspec.Pathspec_Vectors.Vector;
      Path         : String;
      Is_Directory : Boolean) return Boolean is
   begin
      return
        Pathspecs.Is_Empty
        or else
          Version.Pathspec.Matches_Any
            (Pathspecs, Path, Is_Directory => Is_Directory);
   end Pathspec_Selects;

   procedure Scan_Ignored_Matching_Directory
     (Root            : String;
      Dir             : String;
      Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Result          : in out File_Change_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Dir,
         Pattern   => "",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Name : constant String := Ada.Directories.Simple_Name (E);
            Full : constant String := Ada.Directories.Full_Name (E);
         begin
            if Name /= "." and then Name /= ".." then
               if Ada.Directories.Kind (E) = Ada.Directories.Directory then
                  if Name /= ".git" then
                     declare
                        Rel_Dir : constant String :=
                          Status_Relative_Path (Root, Full);
                        Tracked_Under : constant Boolean :=
                          Has_Tracked_Path_Under (Index_Entries, Rel_Dir);
                        Ignored : constant Boolean :=
                          (not Tracked_Under)
                          and then
                            Version.Ignore.Is_Ignored
                              (Rules         => Ignore_Rules,
                               Relative_Path => Rel_Dir,
                               Is_Directory  => True);
                     begin
                        if Ignored then
                           if Is_Sparse_Included
                                (Sparse_Enabled,
                                 Sparse_Patterns,
                                 Rel_Dir,
                                 Is_Directory => True)
                             and then Pathspec_Selects
                               (Pathspecs, Rel_Dir, Is_Directory => True)
                           then
                              Add_Change
                                (Result, Rel_Dir & "/", Ignored_File);
                           end if;
                        else
                           Scan_Ignored_Matching_Directory
                             (Root            => Root,
                              Dir             => Full,
                              Index_Entries   => Index_Entries,
                              Ignore_Rules    => Ignore_Rules,
                              Sparse_Enabled  => Sparse_Enabled,
                              Sparse_Patterns => Sparse_Patterns,
                              Pathspecs       => Pathspecs,
                              Result          => Result);
                        end if;
                     end;
                  end if;
               elsif Ada.Directories.Kind (E) = Ada.Directories.Ordinary_File then
                  declare
                     Rel_File : constant String :=
                       Status_Relative_Path (Root, Full);
                     Pos      : constant Path_Position_Maps.Cursor :=
                       Index_Map (Index_Entries).Find (Rel_File);
                  begin
                     if not Path_Position_Maps.Has_Element (Pos)
                       and then Is_Sparse_Included
                         (Sparse_Enabled,
                          Sparse_Patterns,
                          Rel_File,
                          Is_Directory => False)
                       and then Pathspec_Selects
                         (Pathspecs, Rel_File, Is_Directory => False)
                       and then Version.Ignore.Is_Ignored
                         (Rules         => Ignore_Rules,
                          Relative_Path => Rel_File,
                          Is_Directory  => False)
                     then
                        Add_Change (Result, Rel_File, Ignored_File);
                     end if;
                  end;
               end if;
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
   end Scan_Ignored_Matching_Directory;

   function Build_Ignored_Matching
     (Repo            : Version.Repository.Repository_Handle;
      Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector)
      return File_Change_Vectors.Vector
   is
      Result : File_Change_Vectors.Vector;
   begin
      Scan_Ignored_Matching_Directory
        (Root            => Version.Repository.Root_Path (Repo),
         Dir             => Version.Repository.Root_Path (Repo),
         Index_Entries   => Index_Entries,
         Ignore_Rules    => Ignore_Rules,
         Sparse_Enabled  => Sparse_Enabled,
         Sparse_Patterns => Sparse_Patterns,
         Pathspecs       => Pathspecs,
         Result          => Result);
      return Result;
   end Build_Ignored_Matching;

   function Less_Change
     (Left : File_Change; Right : File_Change) return Boolean
   is
      Left_Path  : constant String := To_String (Left.Path);
      Right_Path : constant String := To_String (Right.Path);
   begin
      if Left_Path = Right_Path then
         return Change_Kind'Pos (Left.Kind) < Change_Kind'Pos (Right.Kind);
      end if;

      return Left_Path < Right_Path;
   end Less_Change;

   procedure Sort_Changes (List : in out File_Change_Vectors.Vector) is
      package Change_Sorting is new
        File_Change_Vectors.Generic_Sorting ("<" => Less_Change);
   begin
      if List.Length < 2 then
         return;
      end if;

      Change_Sorting.Sort (List);
   end Sort_Changes;

   procedure Print_Change_List
     (Title : String; List : File_Change_Vectors.Vector) is
   begin
      if List.Is_Empty then
         return;
      end if;

      Ada.Text_IO.Put_Line (Title & ":");

      for I in List.First_Index .. List.Last_Index loop
         Ada.Text_IO.Put_Line
           (Change_Output_Line
              (List.Element (I).Kind, To_String (List.Element (I).Path)));
      end loop;

      Ada.Text_IO.New_Line;
   end Print_Change_List;

   function Load_Head_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : String;
      Objects : in out Version.Object_Cache.Object_Cache;
      Trees   : in out Version.Tree_Cache.Tree_Cache)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Empty : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      if Commit'Length = 0 then
         return Empty;
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Commit) then
         raise Ada.Text_IO.Data_Error
           with "corrupt repository: invalid HEAD commit id";
      end if;

      declare
         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Commit);

         Commit_Obj : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object
             (Repo => Repo, Cache => Objects, Id => Commit_Id);

         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Commit_Obj);
      begin
         return
           Version.Tree_Cache.Flatten_Tree
             (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      end;
   end Load_Head_Tree;

   function Current_Status return Status_Result is
      Repo          : Version.Repository.Repository_Handle;
      Commit        : Unbounded_String;
      Head_Entries  : Version.Objects.Tree_Entry_Vectors.Vector;
      Index_Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Result        : Status_Result;
      Object_Cache  : Version.Object_Cache.Object_Cache;
      Ref_Cache     : Version.Ref_Cache.Ref_Cache;
      Tree_Cache    : Version.Tree_Cache.Tree_Cache;
   begin
      Repo := Version.Repository.Open;
      Commit :=
        To_Unbounded_String
          (Version.Ref_Cache.Current_Commit_Id
             (Repo => Repo, Cache => Ref_Cache));

      Head_Entries :=
        Load_Head_Tree
          (Repo    => Repo,
           Commit  => To_String (Commit),
           Objects => Object_Cache,
           Trees   => Tree_Cache);

      Index_Entries := Version.Staging.Load (Repo);
      Ignore_Rules := Version.Ignore.Load (Repo);
      Working_Files :=
        Version.Working_Tree.Scan
          (Repo          => Repo,
           Ignore_Rules  => Ignore_Rules,
           Tracked_Paths => Index_Entries);

      declare
         Sparse_Enabled  : constant Boolean := Version.Sparse.Enabled (Repo);
         Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      begin
         if Sparse_Enabled then
            Sparse_Patterns := Version.Sparse.Patterns (Repo);
         end if;

         Result :=
           Build_Status
             (Head_Entries    => Head_Entries,
              Index_Entries   => Index_Entries,
              Working_Files   => Working_Files,
              Ignore_Rules    => Ignore_Rules,
              Sparse_Enabled  => Sparse_Enabled,
              Sparse_Patterns => Sparse_Patterns);
      end;

      Append_Merge_Conflicts (Repo, Result);

      Sort_Changes (Result.Changes);
      Sort_Changes (Result.Staged);
      Sort_Changes (Result.Untracked);
      Sort_Changes (Result.Ignored);
      Sort_Changes (Result.Conflicted);

      return Result;
   end Current_Status;

   function Filter_Result
     (Result    : Status_Result;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Status_Result
   is
      Filtered : Status_Result;

      procedure Copy_Selected
        (Source : File_Change_Vectors.Vector;
         Target : in out File_Change_Vectors.Vector) is
      begin
         if not Source.Is_Empty then
            for I in Source.First_Index .. Source.Last_Index loop
               declare
                  Path : constant String :=
                    To_String (Source.Element (I).Path);
               begin
                  if Version.Pathspec.Matches_Any (Pathspecs, Path) then
                     Target.Append (Source.Element (I));
                  end if;
               end;
            end loop;
         end if;
      end Copy_Selected;
   begin
      Copy_Selected (Result.Changes, Filtered.Changes);
      Copy_Selected (Result.Staged, Filtered.Staged);
      Copy_Selected (Result.Untracked, Filtered.Untracked);
      Copy_Selected (Result.Ignored, Filtered.Ignored);
      Copy_Selected (Result.Conflicted, Filtered.Conflicted);
      return Filtered;
   end Filter_Result;

   function Current_Status
     (Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Status_Result
   is
      Repo          : Version.Repository.Repository_Handle;
      Commit        : Unbounded_String;
      Head_Entries  : Version.Objects.Tree_Entry_Vectors.Vector;
      Index_Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules  : Version.Ignore.Ignore_Rules;
      Result        : Status_Result;
      Object_Cache  : Version.Object_Cache.Object_Cache;
      Ref_Cache     : Version.Ref_Cache.Ref_Cache;
      Tree_Cache    : Version.Tree_Cache.Tree_Cache;
   begin
      if Pathspecs.Is_Empty then
         return Current_Status;
      end if;

      Repo := Version.Repository.Open;
      Commit :=
        To_Unbounded_String
          (Version.Ref_Cache.Current_Commit_Id
             (Repo => Repo, Cache => Ref_Cache));

      Head_Entries :=
        Load_Head_Tree
          (Repo    => Repo,
           Commit  => To_String (Commit),
           Objects => Object_Cache,
           Trees   => Tree_Cache);

      Index_Entries := Version.Staging.Load (Repo);
      Ignore_Rules := Version.Ignore.Load (Repo);
      Working_Files :=
        Version.Working_Tree.Scan
          (Repo          => Repo,
           Ignore_Rules  => Ignore_Rules,
           Tracked_Paths => Index_Entries,
           Pathspecs     => Pathspecs);

      declare
         Sparse_Enabled  : constant Boolean := Version.Sparse.Enabled (Repo);
         Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
      begin
         if Sparse_Enabled then
            Sparse_Patterns := Version.Sparse.Patterns (Repo);
         end if;

         Result :=
           Build_Status
             (Head_Entries    => Head_Entries,
              Index_Entries   => Index_Entries,
              Working_Files   => Working_Files,
              Ignore_Rules    => Ignore_Rules,
              Sparse_Enabled  => Sparse_Enabled,
              Sparse_Patterns => Sparse_Patterns);
      end;

      Append_Merge_Conflicts (Repo, Result);
      Result := Filter_Result (Result, Pathspecs);

      Sort_Changes (Result.Changes);
      Sort_Changes (Result.Staged);
      Sort_Changes (Result.Untracked);
      Sort_Changes (Result.Ignored);
      Sort_Changes (Result.Conflicted);

      return Result;
   end Current_Status;

   function Current_Status_With_Ignored
     (Mode : Ignored_Display_Mode := Ignored_Traditional)
      return Status_Result
   is
      Empty_Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      return Current_Status_With_Ignored (Empty_Pathspecs, Mode);
   end Current_Status_With_Ignored;

   function Current_Status_With_Ignored
     (Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Mode      : Ignored_Display_Mode := Ignored_Traditional)
      return Status_Result
   is
      Repo          : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Ignore_Rules  : constant Version.Ignore.Ignore_Rules :=
        Version.Ignore.Load (Repo);
      Working_Files : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);
      Result        : Status_Result := Current_Status (Pathspecs);
      Sparse_Enabled  : constant Boolean := Version.Sparse.Enabled (Repo);
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      if Sparse_Enabled then
         Sparse_Patterns := Version.Sparse.Patterns (Repo);
      end if;

      if Mode = Ignored_Matching then
         Result.Ignored :=
           Build_Ignored_Matching
             (Repo            => Repo,
              Index_Entries   => Index_Entries,
              Ignore_Rules    => Ignore_Rules,
              Sparse_Enabled  => Sparse_Enabled,
              Sparse_Patterns => Sparse_Patterns,
              Pathspecs       => Pathspecs);
      else
         Result.Ignored :=
           Build_Ignored
             (Index_Entries   => Index_Entries,
              Working_Files   => Working_Files,
              Ignore_Rules    => Ignore_Rules,
              Sparse_Enabled  => Sparse_Enabled,
              Sparse_Patterns => Sparse_Patterns,
              Pathspecs       => Pathspecs);
      end if;
      Sort_Changes (Result.Ignored);
      Sort_Changes (Result.Conflicted);
      return Result;
   end Current_Status_With_Ignored;

   function Natural_Image (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Natural_Image;

   function Commit_Word (Count : Natural) return String is
   begin
      if Count = 1 then
         return "commit";
      else
         return "commits";
      end if;
   end Commit_Word;

   function Short_Id (Id : String) return String is
   begin
      if Id'Length <= 12 then
         return Id;
      else
         return Id (Id'First .. Id'First + 11);
      end if;
   end Short_Id;

   procedure Print_Head_Line (Repo : Version.Repository.Repository_Handle) is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if Version.Refs.Is_Attached (Head) then
         Ada.Text_IO.Put_Line ("On branch " & Version.Refs.Branch_Name (Head));
      else
         Ada.Text_IO.Put_Line
           ("HEAD detached at " & Short_Id (Version.Refs.Commit_Id (Head)));
      end if;
   end Print_Head_Line;

   procedure Print_Upstream_Line (Repo : Version.Repository.Repository_Handle)
   is
      Head : constant Version.Refs.Head_Info := Version.Refs.Read_Head (Repo);
   begin
      if not Version.Refs.Is_Attached (Head) then
         return;
      end if;

      declare
         Branch : constant String := Version.Refs.Branch_Name (Head);
      begin
         if not Version.Tracking.Has_Upstream (Repo, Branch) then
            return;
         end if;

         declare
            Info          : constant Version.Tracking.Upstream_Info :=
              Version.Tracking.Upstream (Repo, Branch);
            Counts        : constant Version.Tracking.Ahead_Behind :=
              Version.Tracking.Count_Ahead_Behind (Repo, Branch);
            Remote        : constant String := To_String (Info.Remote);
            Merge         : constant String := To_String (Info.Merge);
            Prefix        : constant String := "refs/heads/";
            Remote_Branch : constant String :=
              (if Merge'Length >= Prefix'Length
                 and then
                   Merge (Merge'First .. Merge'First + Prefix'Length - 1)
                   = Prefix
               then Merge (Merge'First + Prefix'Length .. Merge'Last)
               else Merge);
         begin
            if Counts.Ahead > 0 and then Counts.Behind > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch and "
                  & Remote
                  & "/"
                  & Remote_Branch
                  & " have diverged; ahead by "
                  & Natural_Image (Counts.Ahead)
                  & " "
                  & Commit_Word (Counts.Ahead)
                  & ", behind by "
                  & Natural_Image (Counts.Behind)
                  & " "
                  & Commit_Word (Counts.Behind)
                  & ".");
            elsif Counts.Ahead > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch is ahead of "
                  & Remote
                  & "/"
                  & Remote_Branch
                  & " by "
                  & Natural_Image (Counts.Ahead)
                  & " "
                  & Commit_Word (Counts.Ahead)
                  & ".");
            elsif Counts.Behind > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch is behind "
                  & Remote
                  & "/"
                  & Remote_Branch
                  & " by "
                  & Natural_Image (Counts.Behind)
                  & " "
                  & Commit_Word (Counts.Behind)
                  & ".");
            end if;
         end;
      exception
         when Ada.Text_IO.Data_Error | Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Print_Upstream_Line;

   procedure Print_Status_Result
     (Result : Status_Result; Include_Ignored : Boolean := False) is
      Repo : Version.Repository.Repository_Handle;
   begin
      Repo := Version.Repository.Open;

      Print_Head_Line (Repo);
      Print_Upstream_Line (Repo);

      if Result.Changes.Is_Empty
        and then Result.Staged.Is_Empty
        and then Result.Untracked.Is_Empty
        and then Result.Conflicted.Is_Empty
        and then ((not Include_Ignored) or else Result.Ignored.Is_Empty)
      then
         Ada.Text_IO.Put_Line (Clean_Status_Line);
         return;
      end if;

      Ada.Text_IO.New_Line;
      Print_Change_List ("Unmerged", Result.Conflicted);
      Print_Change_List ("Staged", Result.Staged);
      Print_Change_List ("Unstaged", Result.Changes);
      Print_Change_List ("Untracked", Result.Untracked);
      if Include_Ignored then
         Print_Change_List ("Ignored", Result.Ignored);
      end if;

   end Print_Status_Result;

   procedure Print_Status is
   begin
      Print_Status_Result (Current_Status);
   end Print_Status;

   procedure Print_Status
     (Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector) is
   begin
      Print_Status_Result (Current_Status (Pathspecs));
   end Print_Status;

   procedure Print_Porcelain_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Porcelain_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode)
             else Current_Status),
            Include_Ignored));
   end Print_Porcelain_Status;

   procedure Print_Porcelain_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Porcelain_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Pathspecs, Ignored_Mode)
             else Current_Status (Pathspecs)),
            Include_Ignored));
   end Print_Porcelain_Status;

   procedure Print_Short_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Short_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode)
             else Current_Status),
            Include_Ignored));
   end Print_Short_Status;

   procedure Print_Short_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Short_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Pathspecs, Ignored_Mode)
             else Current_Status (Pathspecs)),
            Include_Ignored));
   end Print_Short_Status;

   procedure Print_Branch_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Branch_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode)
             else Current_Status),
            Include_Ignored));
   end Print_Branch_Status;

   procedure Print_Branch_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Ada.Text_IO.Put
        (Branch_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Pathspecs, Ignored_Mode)
             else Current_Status (Pathspecs)),
            Include_Ignored));
   end Print_Branch_Status;

   procedure Print_Ignored_Status
     (Mode : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Print_Status_Result
        (Current_Status_With_Ignored (Mode), Include_Ignored => True);
   end Print_Ignored_Status;

   procedure Print_Ignored_Status
     (Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Mode      : Ignored_Display_Mode := Ignored_Traditional) is
   begin
      Print_Status_Result
        (Current_Status_With_Ignored (Pathspecs, Mode), Include_Ignored => True);
   end Print_Ignored_Status;

end Version.Status;
