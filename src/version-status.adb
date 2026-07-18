with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Containers;        use Ada.Containers;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Ordered_Sets;
with Ada.Characters.Handling;
with Version.Config;
with Version.Console;
with Version.Objects;
with Version.Refs;
with Version.Revisions;
with Version.Repository;
with Version.Staging;
with Version.Working_Tree;
with Version.Ignore;
with GNAT.OS_Lib;
with Version.Files;
with Version.Platform;
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

         when Renamed_File  =>
            return "renamed";

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
      return "nothing to commit, working tree clean";
   end Clean_Status_Line;

   --  The mode git would record for a path as it is on disk right now.  A
   --  mode-only change (chmod +x) is a change to git, even when the content is
   --  untouched -- status compared blob ids only and missed it entirely.
   function Working_Index_Mode
     (Repo : Version.Repository.Repository_Handle;
      Path : String) return String
   is
      Full : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Version.Files.To_Native_Path (Full)) then
         return "120000";
      elsif Version.Platform.Supports_Executable_Bit
        and then GNAT.OS_Lib.Is_Executable_File
                   (Version.Files.To_Native_Path (Full))
      then
         return "100755";
      else
         return "100644";
      end if;
   exception
      when others =>
         return "100644";
   end Working_Index_Mode;

   function Change_Kind_Text (Kind : Change_Kind) return String is
   begin
      return Kind_Image (Kind);
   end Change_Kind_Text;

   function Porcelain_Kind_Code (Kind : Change_Kind) return String is
   begin
      case Kind is
         when New_File      =>
            return "A";

         when Renamed_File  =>
            return "R";

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

   --  git status --porcelain (v1): one "XY path" line per change, where X is
   --  the index/staged state and Y the working-tree state; untracked files are
   --  "?? path" and ignored files "!! path". Tracked changes are sorted by
   --  path, then untracked, then ignored. Clean status prints nothing.
   function Porcelain_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String
   is
      LF : constant Character := Ada.Characters.Latin_1.LF;

      type XY is record
         X : Character := ' ';
         Y : Character := ' ';
         --  A rename is keyed on its *old* path (that is what git sorts by)
         --  and displayed as `old -> new`.
         Display : Unbounded_String;
      end record;

      package XY_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => XY);
      package Str_Sets is new Ada.Containers.Indefinite_Ordered_Sets
        (Element_Type => String);

      Tracked : XY_Maps.Map;
      Text    : Unbounded_String;

      function Reg_Code (K : Change_Kind) return Character is
        (case K is
            when New_File      => 'A',
            when Modified_File => 'M',
            when Deleted_File  => 'D',
            when others        => 'M');

      procedure Set_X (Path : String; C : Character) is
         Pair : XY :=
           (if Tracked.Contains (Path) then Tracked.Element (Path)
            else (others => <>));
      begin
         Pair.X := C;
         Tracked.Include (Path, Pair);
      end Set_X;

      procedure Set_Y (Path : String; C : Character) is
         Pair : XY :=
           (if Tracked.Contains (Path) then Tracked.Element (Path)
            else (others => <>));
      begin
         Pair.Y := C;
         Tracked.Include (Path, Pair);
      end Set_Y;

      procedure Emit_Sorted (List : File_Change_Vectors.Vector; Code : String) is
         S : Str_Sets.Set;
      begin
         for I in List.First_Index .. List.Last_Index loop
            S.Include (To_String (List.Element (I).Path));
         end loop;
         for P of S loop
            Append (Text, Code & " " & P & LF);
         end loop;
      end Emit_Sorted;
   begin
      for I in Result.Conflicted.First_Index .. Result.Conflicted.Last_Index loop
         declare
            Path : constant String :=
              To_String (Result.Conflicted.Element (I).Path);
         begin
            case Result.Conflicted.Element (I).Kind is
               when Both_Added_File       =>
                  Tracked.Include (Path, ('A', 'A', Null_Unbounded_String));
               when Deleted_Modified_File =>
                  Tracked.Include (Path, ('D', 'U', Null_Unbounded_String));
               when others                =>
                  Tracked.Include (Path, ('U', 'U', Null_Unbounded_String));
            end case;
         end;
      end loop;
      --  A rename is keyed on its *destination* -- that is what git sorts the
      --  entries by -- and displayed as `old -> new`.  Keying on the
      --  destination also means a worktree change to it lands on the same line
      --  by itself (git prints `RM old -> new`).
      for I in Result.Staged.First_Index .. Result.Staged.Last_Index loop
         declare
            E : constant File_Change := Result.Staged.Element (I);
         begin
            if E.Kind = Renamed_File then
               declare
                  New_P : constant String := To_String (E.Path);
                  Pair  : XY;
               begin
                  Pair.X := 'R';
                  Pair.Display :=
                    To_Unbounded_String
                      (To_String (E.Old_Path) & " -> " & New_P);
                  Tracked.Include (New_P, Pair);
               end;
            else
               Set_X (To_String (E.Path), Reg_Code (E.Kind));
            end if;
         end;
      end loop;

      for I in Result.Changes.First_Index .. Result.Changes.Last_Index loop
         Set_Y (To_String (Result.Changes.Element (I).Path),
                Reg_Code (Result.Changes.Element (I).Kind));
      end loop;

      for C in Tracked.Iterate loop
         declare
            Shown : constant String :=
              (if Length (XY_Maps.Element (C).Display) > 0
               then To_String (XY_Maps.Element (C).Display)
               else XY_Maps.Key (C));
         begin
            Append
              (Text,
               XY_Maps.Element (C).X & XY_Maps.Element (C).Y & " "
               & Shown & LF);
         end;
      end loop;
      Emit_Sorted (Result.Untracked, "??");
      if Include_Ignored then
         Emit_Sorted (Result.Ignored, "!!");
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
        (File_Change'(Path     => To_Unbounded_String (Path),
                      Kind     => Kind,
                      Old_Path => Null_Unbounded_String));
   end Add_Change;

   --  status.renames (git default: true).
   function Renames_Enabled
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is
      Text : constant String :=
        (if Version.Config.Has_Key (Repo, "status.renames")
         then Version.Config.Get_Value (Repo, "status.renames") else "");
      Lower : String := Text;
   begin
      for I in Lower'Range loop
         Lower (I) := Ada.Characters.Handling.To_Lower (Lower (I));
      end loop;
      return not (Lower = "false" or else Lower = "0" or else Lower = "no");
   end Renames_Enabled;

   --  git's rename detection for the staged side: a deleted path and an added
   --  path whose contents are similar enough (50%, git's default) are one
   --  rename.  Reported as `R  old -> new`.
   function Blob_Text
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return String is
   begin
      return Version.Objects.Content (Version.Objects.Read_Object (Repo, Id));
   exception
      when others =>
         return "";
   end Blob_Text;

   function Similarity (Old_Text, New_Text : String) return Natural is
      package Count_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Natural);

      procedure Tally (Text : String; Into : in out Count_Maps.Map;
                       Lines : out Natural)
      is
         Start : Natural := Text'First;
      begin
         Lines := 0;
         for I in Text'Range loop
            if Text (I) = Ada.Characters.Latin_1.LF then
               declare
                  L : constant String := Text (Start .. I);
               begin
                  Into.Include
                    (L, (if Into.Contains (L) then Into.Element (L) + 1
                         else 1));
                  Lines := Lines + 1;
               end;
               Start := I + 1;
            end if;
         end loop;
         if Start <= Text'Last then
            declare
               L : constant String := Text (Start .. Text'Last);
            begin
               Into.Include
                 (L, (if Into.Contains (L) then Into.Element (L) + 1 else 1));
               Lines := Lines + 1;
            end;
         end if;
      end Tally;

      Old_Counts, New_Counts : Count_Maps.Map;
      Old_Lines, New_Lines   : Natural := 0;
      Common                 : Natural := 0;
   begin
      if Old_Text = New_Text then
         return 100;
      end if;

      Tally (Old_Text, Old_Counts, Old_Lines);
      Tally (New_Text, New_Counts, New_Lines);

      if Old_Lines = 0 or else New_Lines = 0 then
         return 0;
      end if;

      for C in Old_Counts.Iterate loop
         if New_Counts.Contains (Count_Maps.Key (C)) then
            Common := Common
              + Natural'Min (Count_Maps.Element (C),
                             New_Counts.Element (Count_Maps.Key (C)));
         end if;
      end loop;

      return (Common * 100) / Natural'Max (Old_Lines, New_Lines);
   end Similarity;

   function Build_Status
     (Head_Entries    : Version.Objects.Tree_Entry_Vectors.Vector;
      Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files   : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Repo            : Version.Repository.Repository_Handle;
      All_Untracked   : Boolean := False;
      Detect_Renames  : Boolean := True)
      return Status_Result
   is
      Result      : Status_Result;
      Head_Pos    : constant Path_Position_Maps.Map := Head_Map (Head_Entries);
      Index_Pos   : constant Path_Position_Maps.Map :=
        Index_Map (Index_Entries);
      Working_Pos : constant Path_Position_Maps.Map :=
        Working_Map (Working_Files);

      package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
        (Element_Type => String);
      package Mask_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Natural);
      Conflicted : Path_Sets.Set;   --  paths with any index stage > 0
   begin
      --  Unmerged (conflicted) paths come from the index stages (1=base,
      --  2=ours, 3=theirs), exactly as git reports them, independent of how
      --  the conflict was created (a git merge leaves no Merge_State).
      declare
         Masks : Mask_Maps.Map;
      begin
         for I in Index_Entries.First_Index .. Index_Entries.Last_Index loop
            declare
               St : constant Natural := Index_Entries.Element (I).Stage;
            begin
               if St in 1 .. 3 then
                  declare
                     Path : constant String :=
                       To_String (Index_Entries.Element (I).Path);
                     Cur  : constant Natural :=
                       (if Masks.Contains (Path) then Masks.Element (Path)
                        else 0);
                  begin
                     --  Set the stage's bit (each index stage is unique per
                     --  path, so a sum is equivalent to a bitwise or here).
                     Masks.Include
                       (Path,
                        (if (Cur / (2 ** (St - 1))) mod 2 = 1 then Cur
                         else Cur + 2 ** (St - 1)));
                  end;
               end if;
            end;
         end loop;
         for C in Masks.Iterate loop
            declare
               M : constant Natural := Mask_Maps.Element (C);
               K : constant Change_Kind :=
                 (if M = 6 then Both_Added_File        --  ours+theirs, no base
                  elsif M = 5 then Deleted_Modified_File  --  base+theirs (ours del)
                  else Unmerged_File);                 --  both modified / other
            begin
               Add_Change (Result.Conflicted, Mask_Maps.Key (C), K);
               Conflicted.Include (Mask_Maps.Key (C));
            end;
         end loop;
      end;

      if not Head_Entries.Is_Empty then
         for I in Head_Entries.First_Index .. Head_Entries.Last_Index loop
            declare
               Path : constant String :=
                 To_String (Head_Entries.Element (I).Path);
               Pos  : constant Path_Position_Maps.Cursor :=
                 Index_Pos.Find (Path);
            begin
               if Conflicted.Contains (Path) then
                  null;   --  reported as unmerged, not deleted
               elsif not Path_Position_Maps.Has_Element (Pos) then
                  Add_Change (Result.Staged, Path, Deleted_File);
               elsif Index_Entries.Element (Path_Position_Maps.Element (Pos))
                       .Id
                 /= Head_Entries.Element (I).Id
                 or else Index_Entries.Element
                           (Path_Position_Maps.Element (Pos)).Mode
                         /= Head_Entries.Element (I).Mode
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
                     if Version.Sparse.Included (Repo, Path) then
                        Add_Change (Result.Changes, Path, Deleted_File);
                     end if;
                  elsif Working_Files.Element (Path_Position_Maps.Element (Pos))
                          .Id
                    /= Index_Entries.Element (I).Id
                    --  A gitlink is a submodule directory, not a file: its
                    --  worktree "mode" is meaningless here, and comparing it
                    --  would report every submodule as permanently modified.
                    or else (To_String (Index_Entries.Element (I).Mode)
                             /= "160000"
                             and then Working_Index_Mode (Repo, Path)
                                      /= To_String
                                           (Index_Entries.Element (I).Mode))
                  then
                     Add_Change (Result.Changes, Path, Modified_File);
                  end if;
               end;
            end if;
         end loop;
      end if;

      --  Pair staged deletes with staged adds of similar content: that is a
      --  rename, and git reports it as one (status.renames, on by default).
      if Detect_Renames then
         declare
            package Nat_Sets is new Ada.Containers.Ordered_Sets (Natural);
            Used   : Nat_Sets.Set;
            Paired : File_Change_Vectors.Vector;

            function Head_Blob (Path : String) return String is
               Pos : constant Path_Position_Maps.Cursor := Head_Pos.Find (Path);
            begin
               if not Path_Position_Maps.Has_Element (Pos) then
                  return "";
               end if;
               return Blob_Text
                 (Repo,
                  Head_Entries.Element (Path_Position_Maps.Element (Pos)).Id);
            end Head_Blob;

            function Index_Blob (Path : String) return String is
               Pos : constant Path_Position_Maps.Cursor := Index_Pos.Find (Path);
            begin
               if not Path_Position_Maps.Has_Element (Pos) then
                  return "";
               end if;
               return Blob_Text
                 (Repo,
                  Index_Entries.Element (Path_Position_Maps.Element (Pos)).Id);
            end Index_Blob;
         begin
            --  Pass 1, as git does: pair identical blobs first.  Only then
            --  fall back to similarity -- otherwise a merely *similar* add can
            --  steal the delete that an identical one should have claimed.
            for D in Result.Staged.First_Index .. Result.Staged.Last_Index loop
               if Result.Staged.Element (D).Kind = Deleted_File
                 and then not Used.Contains (D)
               then
                  declare
                     Old_Path : constant String :=
                       To_String (Result.Staged.Element (D).Path);
                     Old_Id   : constant Version.Objects.Hex_Object_Id :=
                       Head_Entries.Element
                         (Path_Position_Maps.Element
                            (Head_Pos.Find (Old_Path))).Id;
                  begin
                     for A in Result.Staged.First_Index
                                .. Result.Staged.Last_Index
                     loop
                        if Result.Staged.Element (A).Kind = New_File
                          and then not Used.Contains (A)
                        then
                           declare
                              New_Path : constant String :=
                                To_String (Result.Staged.Element (A).Path);
                           begin
                              if Index_Entries.Element
                                   (Path_Position_Maps.Element
                                      (Index_Pos.Find (New_Path))).Id = Old_Id
                              then
                                 Used.Include (D);
                                 Used.Include (A);
                                 Paired.Append
                                   (File_Change'
                                      (Path     =>
                                         Result.Staged.Element (A).Path,
                                       Kind     => Renamed_File,
                                       Old_Path =>
                                         To_Unbounded_String (Old_Path)));
                                 exit;
                              end if;
                           end;
                        end if;
                     end loop;
                  end;
               end if;
            end loop;

            --  Pass 2: similarity.  Destination-major, like git's
            --  diffcore-rename -- for each added path pick the *best* deleted
            --  source.  Doing it source-major lets an early, poorer source
            --  claim a destination that a later, better one should have won.
            for A in Result.Staged.First_Index .. Result.Staged.Last_Index loop
               if Result.Staged.Element (A).Kind = New_File
                 and then not Used.Contains (A)
               then
                  declare
                     New_Path : constant String :=
                       To_String (Result.Staged.Element (A).Path);
                     New_Text : constant String := Index_Blob (New_Path);
                     Best     : Natural := 0;
                     Best_Idx : Integer := -1;
                  begin
                     for D in Result.Staged.First_Index
                                .. Result.Staged.Last_Index
                     loop
                        if Result.Staged.Element (D).Kind = Deleted_File
                          and then not Used.Contains (D)
                        then
                           declare
                              Score : constant Natural :=
                                Similarity
                                  (Head_Blob
                                     (To_String
                                        (Result.Staged.Element (D).Path)),
                                   New_Text);
                           begin
                              if Score > Best then
                                 Best := Score;
                                 Best_Idx := D;
                              end if;
                           end;
                        end if;
                     end loop;

                     --  git's default similarity threshold is 50%.
                     if Best_Idx >= 0 and then Best >= 50 then
                        Used.Include (A);
                        Used.Include (Best_Idx);
                        Paired.Append
                          (File_Change'
                             (Path     => Result.Staged.Element (A).Path,
                              Kind     => Renamed_File,
                              Old_Path =>
                                Result.Staged.Element (Best_Idx).Path));
                     end if;
                  end;
               end if;
            end loop;

            if not Used.Is_Empty then
               declare
                  Rebuilt : File_Change_Vectors.Vector;
               begin
                  for I in Result.Staged.First_Index
                             .. Result.Staged.Last_Index
                  loop
                     if not Used.Contains (I) then
                        Rebuilt.Append (Result.Staged.Element (I));
                     end if;
                  end loop;
                  for R of Paired loop
                     Rebuilt.Append (R);
                  end loop;
                  Result.Staged := Rebuilt;
               end;
            end if;
         end;
      end if;

      if not Working_Files.Is_Empty then
         declare
            --  git collapses a directory holding nothing but untracked files
            --  to `dir/` and does not look inside; a directory that also holds
            --  a tracked file is descended into.  (`-uall` lists every file.)
            Tracked_Dirs : Path_Sets.Set;
            Reported     : Path_Sets.Set;

            function Collapsed (Path : String) return String is
            begin
               for K in Path'Range loop
                  if Path (K) = '/' then
                     declare
                        Dir : constant String := Path (Path'First .. K - 1);
                     begin
                        if not Tracked_Dirs.Contains (Dir) then
                           return Dir & "/";
                        end if;
                     end;
                  end if;
               end loop;
               return Path;
            end Collapsed;
         begin
            --  Every ancestor directory of a tracked path holds something
            --  tracked.
            for I in Index_Entries.First_Index .. Index_Entries.Last_Index loop
               declare
                  P : constant String :=
                    To_String (Index_Entries.Element (I).Path);
               begin
                  for K in P'Range loop
                     if P (K) = '/' then
                        Tracked_Dirs.Include (P (P'First .. K - 1));
                     end if;
                  end loop;
               end;
            end loop;

            for I in Working_Files.First_Index .. Working_Files.Last_Index loop
               declare
                  Path : constant String :=
                    To_String (Working_Files.Element (I).Path);
                  Pos  : constant Path_Position_Maps.Cursor :=
                    Index_Pos.Find (Path);
               begin
                  if not Path_Position_Maps.Has_Element (Pos)
                    and then not Conflicted.Contains (Path)
                    and then Version.Sparse.Included (Repo, Path)
                    and then
                      not Version.Ignore.Is_Ignored
                            (Rules         => Ignore_Rules,
                             Relative_Path => Path,
                             Is_Directory  => False)
                  then
                     declare
                        Shown : constant String :=
                          (if All_Untracked then Path else Collapsed (Path));
                     begin
                        if not Reported.Contains (Shown) then
                           Reported.Include (Shown);
                           Add_Change (Result.Untracked, Shown, New_File);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end;
      end if;

      return Result;
   end Build_Status;

   function Build_Ignored
     (Index_Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Working_Files   : Version.Working_Tree.Working_File_Vectors.Vector;
      Ignore_Rules    : Version.Ignore.Ignore_Rules;
      Repo            : Version.Repository.Repository_Handle;
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
                 and then Version.Sparse.Included (Repo, Path)
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
               C     : constant Version.Merge.Conflict := Conflicts.Element (I);
               Path  : constant String := To_String (C.Path);
               Dup   : Boolean := False;
            begin
               --  Do not double-report a path already found via index stages.
               for J in Result.Conflicted.First_Index ..
                        Result.Conflicted.Last_Index
               loop
                  if To_String (Result.Conflicted.Element (J).Path) = Path then
                     Dup := True;
                  end if;
               end loop;
               if not Dup then
                  Add_Change
                    (Result.Conflicted, Path, Conflict_Change_Kind (C.Kind));
               end if;
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
     (Repo         : Version.Repository.Repository_Handle;
      Path         : String;
      Is_Directory : Boolean) return Boolean is
   begin
      return Version.Sparse.Included (Repo, Path, Is_Directory);
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
      Repo            : Version.Repository.Repository_Handle;
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
                                (Repo, Rel_Dir, Is_Directory => True)
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
                              Repo            => Repo,
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
                         (Repo, Rel_File, Is_Directory => False)
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
         Repo            => Repo,
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

   function Current_Status
     (All_Untracked : Boolean := False) return Status_Result is
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

      Result :=
        Build_Status
          (Head_Entries    => Head_Entries,
           Index_Entries   => Index_Entries,
           Working_Files   => Working_Files,
           Ignore_Rules    => Ignore_Rules,
           Repo            => Repo,
           All_Untracked   => All_Untracked,
           Detect_Renames  => Renames_Enabled (Repo));

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
     (Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector;
      All_Untracked : Boolean := False)
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

      Result :=
        Build_Status
          (Head_Entries    => Head_Entries,
           Index_Entries   => Index_Entries,
           Working_Files   => Working_Files,
           Ignore_Rules    => Ignore_Rules,
           Repo            => Repo,
           All_Untracked   => All_Untracked,
           Detect_Renames  => Renames_Enabled (Repo));

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
     (Mode          : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked : Boolean := False)
      return Status_Result
   is
      Empty_Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      return Current_Status_With_Ignored
        (Empty_Pathspecs, Mode, All_Untracked);
   end Current_Status_With_Ignored;

   function Current_Status_With_Ignored
     (Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector;
      Mode          : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked : Boolean := False)
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
      Result        : Status_Result :=
        Current_Status (Pathspecs, All_Untracked);
   begin
      if Mode = Ignored_Matching then
         Result.Ignored :=
           Build_Ignored_Matching
             (Repo            => Repo,
              Index_Entries   => Index_Entries,
              Ignore_Rules    => Ignore_Rules,
              Pathspecs       => Pathspecs);
      else
         Result.Ignored :=
           Build_Ignored
             (Index_Entries   => Index_Entries,
              Working_Files   => Working_Files,
              Ignore_Rules    => Ignore_Rules,
              Repo            => Repo,
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
         declare
            Full : constant String := Version.Refs.Commit_Id (Head);
            Id   : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Full);
         begin
            --  git names the commit with find_unique_abbrev, not a fixed
            --  width.
            Ada.Text_IO.Put_Line
              ("HEAD detached at "
               & Full (Full'First .. Full'First
                       + Version.Revisions.Unique_Abbrev_Length (Repo, Id, 7)
                       - 1));
         exception
            when others =>
               Ada.Text_IO.Put_Line ("HEAD detached at " & Short_Id (Full));
         end;
      end if;
   end Print_Head_Line;

   --  Prints git's tracking block: the relation to the upstream branch and,
   --  when it is not up to date, the hint telling the user what to do about
   --  it. The block is followed by a blank line, exactly as git's
   --  wt_status_print_tracking does. Prints nothing at all when the branch
   --  has no upstream.
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
            Upstream      : constant String :=
              "'" & Remote & "/" & Remote_Branch & "'";
         begin
            if Counts.Ahead > 0 and then Counts.Behind > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch and " & Upstream & " have diverged,");
               Ada.Text_IO.Put_Line
                 ("and have "
                  & Natural_Image (Counts.Ahead)
                  & " and "
                  & Natural_Image (Counts.Behind)
                  & " different commits each, respectively.");
               Ada.Text_IO.Put_Line
                 ("  (use ""git pull"" if you want to integrate the remote "
                  & "branch with yours)");
            elsif Counts.Ahead > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch is ahead of "
                  & Upstream
                  & " by "
                  & Natural_Image (Counts.Ahead)
                  & " "
                  & Commit_Word (Counts.Ahead)
                  & ".");
               Ada.Text_IO.Put_Line
                 ("  (use ""git push"" to publish your local commits)");
            elsif Counts.Behind > 0 then
               Ada.Text_IO.Put_Line
                 ("Your branch is behind "
                  & Upstream
                  & " by "
                  & Natural_Image (Counts.Behind)
                  & " "
                  & Commit_Word (Counts.Behind)
                  & ", and can be fast-forwarded.");
               Ada.Text_IO.Put_Line
                 ("  (use ""git pull"" to update your local branch)");
            else
               Ada.Text_IO.Put_Line
                 ("Your branch is up to date with " & Upstream & ".");
            end if;

            Ada.Text_IO.New_Line;
         end;
      exception
         when Ada.Text_IO.Data_Error | Ada.IO_Exceptions.Data_Error =>
            null;
      end;
   end Print_Upstream_Line;

   --  git aligns the change label in a fixed column: 12 for the staged and
   --  unstaged sections, 17 for unmerged paths.
   Change_Label_Width   : constant := 12;
   Unmerged_Label_Width : constant := 17;

   function Pad_Label (Label : String; Width : Positive) return String is
      Fill : constant Positive := Positive'Max (1, Width - Label'Length);
   begin
      return Label & String'(1 .. Fill => ' ');
   end Pad_Label;

   function Long_Change_Label (Kind : Change_Kind) return String is
     (case Kind is
         when New_File      => "new file:",
         when Deleted_File  => "deleted:",
         when Renamed_File  => "renamed:",
         when others        => "modified:");

   function Long_Unmerged_Label (Kind : Change_Kind) return String is
     (case Kind is
         when Both_Added_File       => "both added:",
         when Deleted_Modified_File => "deleted by us:",
         when others                => "both modified:");

   function Long_Entry_Path (Change : File_Change) return String is
     (if Change.Kind = Renamed_File
      then To_String (Change.Old_Path) & " -> " & To_String (Change.Path)
      else To_String (Change.Path));

   function Long_Status_Line
     (Kind     : Change_Kind;
      Path     : String;
      Unmerged : Boolean := False)
      return String is
   begin
      return Ada.Characters.Latin_1.HT
        & Pad_Label
            ((if Unmerged then Long_Unmerged_Label (Kind)
              else Long_Change_Label (Kind)),
             (if Unmerged then Unmerged_Label_Width else Change_Label_Width))
        & Path;
   end Long_Status_Line;

   procedure Print_Long_Entries
     (List     : File_Change_Vectors.Vector;
      Unmerged : Boolean) is
   begin
      for Change of List loop
         Ada.Text_IO.Put_Line
           (Long_Status_Line
              (Change.Kind, Long_Entry_Path (Change), Unmerged));
      end loop;
   end Print_Long_Entries;

   procedure Print_Long_Paths (List : File_Change_Vectors.Vector) is
      Tab : constant Character := Ada.Characters.Latin_1.HT;
   begin
      --  Untracked and ignored entries carry no label, only the path.
      for Change of List loop
         Ada.Text_IO.Put_Line (Tab & To_String (Change.Path));
      end loop;
   end Print_Long_Paths;

   procedure Print_Status_Result
     (Result          : Status_Result;
      Include_Ignored : Boolean := False;
      Show_Untracked  : Boolean := True)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      --  Before the first commit git swaps in a different set of hints and
      --  closing lines, so the two cases have to be told apart.
      Is_Initial : constant Boolean :=
        Version.Refs.Current_Commit_Id (Repo) = "";

      Merging : constant Boolean :=
        Ada.Directories.Exists
          (Version.Files.Join
             (Version.Repository.Git_Dir (Repo), "MERGE_HEAD"));

      --  git's own bookkeeping: `committable` suppresses the closing summary,
      --  `workdir_dirty` selects which summary is printed.
      Committable   : constant Boolean := not Result.Staged.Is_Empty;
      Workdir_Dirty : constant Boolean :=
        not Result.Changes.Is_Empty or else not Result.Conflicted.Is_Empty;

      --  A deletion among the unstaged changes switches the first hint to
      --  the add/rm spelling.
      Has_Deleted : constant Boolean :=
        (for some Change of Result.Changes => Change.Kind = Deleted_File);
   begin
      Print_Head_Line (Repo);

      if Is_Initial then
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put_Line ("No commits yet");
         Ada.Text_IO.New_Line;
      else
         Print_Upstream_Line (Repo);
      end if;

      if Merging then
         if Result.Conflicted.Is_Empty then
            Ada.Text_IO.Put_Line
              ("All conflicts fixed but you are still merging.");
            Ada.Text_IO.Put_Line ("  (use ""git commit"" to conclude merge)");
         else
            Ada.Text_IO.Put_Line ("You have unmerged paths.");
            Ada.Text_IO.Put_Line ("  (fix conflicts and run ""git commit"")");
            Ada.Text_IO.Put_Line
              ("  (use ""git merge --abort"" to abort the merge)");
         end if;

         Ada.Text_IO.New_Line;
      end if;

      if not Result.Staged.Is_Empty then
         Ada.Text_IO.Put_Line ("Changes to be committed:");

         if Is_Initial then
            Ada.Text_IO.Put_Line
              ("  (use ""git rm --cached <file>..."" to unstage)");
         else
            Ada.Text_IO.Put_Line
              ("  (use ""git restore --staged <file>..."" to unstage)");
         end if;

         Print_Long_Entries (Result.Staged, Unmerged => False);
         Ada.Text_IO.New_Line;
      end if;

      if not Result.Conflicted.Is_Empty then
         Ada.Text_IO.Put_Line ("Unmerged paths:");
         Ada.Text_IO.Put_Line
           ("  (use ""git add <file>..."" to mark resolution)");
         Print_Long_Entries (Result.Conflicted, Unmerged => True);
         Ada.Text_IO.New_Line;
      end if;

      if not Result.Changes.Is_Empty then
         Ada.Text_IO.Put_Line ("Changes not staged for commit:");

         if Has_Deleted then
            Ada.Text_IO.Put_Line
              ("  (use ""git add/rm <file>..."" to update what will be "
               & "committed)");
         else
            Ada.Text_IO.Put_Line
              ("  (use ""git add <file>..."" to update what will be "
               & "committed)");
         end if;

         Ada.Text_IO.Put_Line
           ("  (use ""git restore <file>..."" to discard changes in working "
            & "directory)");
         Print_Long_Entries (Result.Changes, Unmerged => False);
         Ada.Text_IO.New_Line;
      end if;

      if Show_Untracked and then not Result.Untracked.Is_Empty then
         Ada.Text_IO.Put_Line ("Untracked files:");
         Ada.Text_IO.Put_Line
           ("  (use ""git add <file>..."" to include in what will be "
            & "committed)");
         Print_Long_Paths (Result.Untracked);
         Ada.Text_IO.New_Line;
      end if;

      if Include_Ignored and then not Result.Ignored.Is_Empty then
         Ada.Text_IO.Put_Line ("Ignored files:");
         Ada.Text_IO.Put_Line
           ("  (use ""git add -f <file>..."" to include in what will be "
            & "committed)");
         Print_Long_Paths (Result.Ignored);
         Ada.Text_IO.New_Line;
      end if;

      --  git mentions the suppressed untracked files only when there is
      --  something staged to commit.
      if not Show_Untracked and then Committable then
         Ada.Text_IO.Put_Line
           ("Untracked files not listed (use -u option to show untracked "
            & "files)");
      end if;

      --  The closing summary. Anything staged means git says nothing here.
      if Committable then
         null;
      elsif Workdir_Dirty then
         Ada.Text_IO.Put_Line
           ("no changes added to commit (use ""git add"" and/or "
            & """git commit -a"")");
      elsif Show_Untracked and then not Result.Untracked.Is_Empty then
         Ada.Text_IO.Put_Line
           ("nothing added to commit but untracked files present "
            & "(use ""git add"" to track)");
      elsif Is_Initial then
         Ada.Text_IO.Put_Line
           ("nothing to commit (create/copy files and use ""git add"" to "
            & "track)");
      elsif not Show_Untracked then
         Ada.Text_IO.Put_Line
           ("nothing to commit (use -u to show untracked files)");
      else
         Ada.Text_IO.Put_Line (Clean_Status_Line);
      end if;
   end Print_Status_Result;

   procedure Print_Status
     (All_Untracked  : Boolean := False;
      Show_Untracked : Boolean := True) is
   begin
      Print_Status_Result
        (Current_Status (All_Untracked), Show_Untracked => Show_Untracked);
   end Print_Status;

   procedure Print_Status
     (Pathspecs      : Version.Pathspec.Pathspec_Vectors.Vector;
      All_Untracked  : Boolean := False;
      Show_Untracked : Boolean := True) is
   begin
      Print_Status_Result
        (Current_Status (Pathspecs, All_Untracked),
         Show_Untracked => Show_Untracked);
   end Print_Status;

   procedure Print_Porcelain_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Porcelain_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode, All_Untracked)
             else Current_Status (All_Untracked)),
            Include_Ignored));
   end Print_Porcelain_Status;

   procedure Print_Porcelain_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Porcelain_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored
                    (Pathspecs, Ignored_Mode, All_Untracked)
             else Current_Status (Pathspecs, All_Untracked)),
            Include_Ignored));
   end Print_Porcelain_Status;

   procedure Print_Short_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Short_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode, All_Untracked)
             else Current_Status (All_Untracked)),
            Include_Ignored));
   end Print_Short_Status;

   procedure Print_Short_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Short_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored
                    (Pathspecs, Ignored_Mode, All_Untracked)
             else Current_Status (Pathspecs, All_Untracked)),
            Include_Ignored));
   end Print_Short_Status;

   procedure Print_Branch_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Branch_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored (Ignored_Mode, All_Untracked)
             else Current_Status (All_Untracked)),
            Include_Ignored));
   end Print_Branch_Status;

   procedure Print_Branch_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False) is
   begin
      Version.Console.Put
        (Branch_Status_Text
           ((if Include_Ignored
             then Current_Status_With_Ignored
                    (Pathspecs, Ignored_Mode, All_Untracked)
             else Current_Status (Pathspecs, All_Untracked)),
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
