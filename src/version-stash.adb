with Ada.Containers; use Ada.Containers;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Branch;
with Version.Diff;
with Version.Files;
with Version.Filesystem_Guard;
with Version.Ignore;
with Version.Merge;
with Version.Merge_State;
with Version.Object_Cache;
with Version.Objects; use Version.Objects;
with Version.Hash;
with Version.Path_Safety;
with Version.Ref_Transaction;
with Version.Reflog;
with Version.Refs;
with Version.Restore;
with Version.Staging;
with Version.Status;
with Version.Tree_Cache;
with Version.Working_Tree;
with Version.Write;

package body Version.Stash is

   use type Version.Hash.Hash_Algorithm;

   --  The all-zero object id (the "no prior stash" reflog sentinel) at the
   --  repository's hash width. The reflog on disk stores a 64-zero null in a
   --  sha256 repo (Version.Reflog widens it), so the stash consistency checks
   --  must compare against the same width.
   function Null_Id
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id is
     (Version.Objects.To_Object_Id
        (if Version.Repository.Algorithm (Repo) = Version.Hash.Sha256
         then [1 .. 64 => '0']
         else [1 .. 40 => '0']));

   Stash_Ref : constant String := "refs/stash";

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Invalid_Stash_Spec_Diagnostic (Spec : String) return String is
   begin
      return "invalid stash spec: " & Spec;
   end Invalid_Stash_Spec_Diagnostic;

   function Stash_Spec_Out_Of_Range_Diagnostic (Spec : String) return String is
   begin
      return "stash spec out of range: " & Spec;
   end Stash_Spec_Out_Of_Range_Diagnostic;

   function No_Stash_Entries_Diagnostic return String is
   begin
      return "no stash entries";
   end No_Stash_Entries_Diagnostic;

   function Malformed_Stash_Reflog_Diagnostic return String is
   begin
      return "malformed stash reflog";
   end Malformed_Stash_Reflog_Diagnostic;

   function Inconsistent_Stash_Storage_Diagnostic return String is
   begin
      return "inconsistent stash storage";
   end Inconsistent_Stash_Storage_Diagnostic;

   function Apply_In_Progress_State_Diagnostic return String is
   begin
      return "stash apply requires no in-progress merge or replay state";
   end Apply_In_Progress_State_Diagnostic;

   function Apply_Dirty_Working_Tree_Diagnostic return String is
   begin
      return "stash apply requires clean working tree and index";
   end Apply_Dirty_Working_Tree_Diagnostic;

   function Apply_Conflicts_Diagnostic return String is
   begin
      return "stash apply has conflicts";
   end Apply_Conflicts_Diagnostic;

   function Current_Ref_Id_Or_Zero
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String) return String
   is
   begin
      if Version.Refs.Ref_Exists (Repo, Ref) then
         return To_String (Version.Refs.Resolve_Ref (Repo, Ref));
      end if;

      return To_String (Null_Id (Repo));
   end Current_Ref_Id_Or_Zero;

   function Stash_Reflog_Path
     (Repo : Version.Repository.Repository_Handle) return String
   is
   begin
      return Version.Reflog.Path (Repo, Stash_Ref);
   end Stash_Reflog_Path;

   procedure Update_Stash_Ref
     (Repo         : Version.Repository.Repository_Handle;
      New_Id       : Version.Objects.Hex_Object_Id;
      Expected_Old : String)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => Stash_Ref,
         New_Id       => New_Id,
         Expected_Old => Expected_Old);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Update_Stash_Ref;

   procedure Delete_Stash_Ref
     (Repo         : Version.Repository.Repository_Handle;
      Expected_Old : String)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Tx, Repo);
      Version.Ref_Transaction.Add_Delete
        (Item         => Tx,
         Ref_Name     => Stash_Ref,
         Expected_Old => Expected_Old);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Delete_Stash_Ref;

   function Parse_Stash_Index (Spec : String) return Natural is
      Prefix : constant String := "stash@{";
   begin
      if Spec'Length < Prefix'Length + 2
        or else Spec (Spec'First .. Spec'First + Prefix'Length - 1) /= Prefix
        or else Spec (Spec'Last) /= '}'
      then
         raise Ada.IO_Exceptions.Data_Error with Invalid_Stash_Spec_Diagnostic (Spec);
      end if;

      declare
         Number_Text : constant String :=
           Spec (Spec'First + Prefix'Length .. Spec'Last - 1);
      begin
         if Number_Text'Length = 0 then
            raise Ada.IO_Exceptions.Data_Error with Invalid_Stash_Spec_Diagnostic (Spec);
         end if;

         return Natural'Value (Number_Text);
      exception
         when Constraint_Error =>
            raise Ada.IO_Exceptions.Data_Error with Invalid_Stash_Spec_Diagnostic (Spec);
      end;
   end Parse_Stash_Index;

   function Tree_Id_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;
      return Version.Objects.Commit_Tree_Id (Obj);
   end Tree_Id_For_Commit;

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

   function Commit_Subject
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return String
   is
      Obj : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Commit_Id);
   begin
      return Version.Objects.Commit_Message_First_Line (Obj);
   end Commit_Subject;

   function Short_Id (Id : String) return String is
   begin
      if Id'Length >= 7 then
         return Id (Id'First .. Id'First + 6);
      else
         return Id;
      end if;
   end Short_Id;

   function Head_Name
     (Repo : Version.Repository.Repository_Handle)
      return String
   is
   begin
      if Version.Refs.Is_Detached (Repo) then
         return "detached HEAD";
      else
         return Version.Refs.Current_Branch_Name (Repo);
      end if;
   end Head_Name;

   function Stash_Message
     (Repo      : Version.Repository.Repository_Handle;
      Head_Id   : Version.Objects.Hex_Object_Id;
      Prefix    : String)
      return String
   is
      Subject : constant String := Commit_Subject (Repo, Head_Id);
   begin
      if Subject'Length = 0 then
         return Prefix & " on " & Head_Name (Repo) & ": " & Short_Id (To_String (Head_Id));
      else
         return Prefix & " on " & Head_Name (Repo) & ": "
           & Short_Id (To_String (Head_Id)) & " " & Subject;
      end if;
   end Stash_Message;

   procedure Require_Head
     (Repo    : Version.Repository.Repository_Handle;
      Head_Id : out Version.Objects.Hex_Object_Id)
   is
      Text : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "cannot stash on unborn branch";
      elsif not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
         raise Ada.IO_Exceptions.Data_Error with "invalid HEAD commit id";
      end if;
      Head_Id := Version.Objects.To_Object_Id (Text);
   end Require_Head;

   function Status_Is_Clean
     (Status              : Version.Status.Status_Result;
      Include_Untracked   : Boolean;
      Include_Ignored     : Boolean;
      Ignored_File_Count  : Natural)
      return Boolean
   is
   begin
      return Status.Changes.Is_Empty
        and then Status.Staged.Is_Empty
        and then Status.Conflicted.Is_Empty
        and then (Status.Untracked.Is_Empty or else not Include_Untracked)
        and then (Ignored_File_Count = 0 or else not Include_Ignored);
   end Status_Is_Clean;

   function Tree_As_Index_Entries
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Items  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Version.Objects.Tree_Entry := Items.Element (I);
            begin
               Result.Append
                 (Version.Staging.Index_Entry'
                    (Path => Item.Path,
                     Id   => Item.Id,
                     Mode => Item.Mode,
                     Stage => 0));
            end;
         end loop;
      end if;

      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Tree_As_Index_Entries;

   function Path_Matches
     (Path      : String;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
   begin
      return Version.Pathspec.Matches_Any
        (Items => Pathspecs, Path => Path, Is_Directory => False);
   end Path_Matches;

   function Overlay_Selected_Entries
     (Base      : Version.Staging.Index_Entry_Vectors.Vector;
      Overlay   : Version.Staging.Index_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if Pathspecs.Is_Empty then
         return Overlay;
      end if;

      if not Base.Is_Empty then
         for I in Base.First_Index .. Base.Last_Index loop
            declare
               Path : constant String := To_String (Base.Element (I).Path);
            begin
               if not Path_Matches (Path, Pathspecs) then
                  Result.Append (Base.Element (I));
               end if;
            end;
         end loop;
      end if;

      if not Overlay.Is_Empty then
         for I in Overlay.First_Index .. Overlay.Last_Index loop
            declare
               Path : constant String := To_String (Overlay.Element (I).Path);
            begin
               if Path_Matches (Path, Pathspecs) then
                  Version.Staging.Replace_Entry (Result, Overlay.Element (I));
               end if;
            end;
         end loop;
      end if;

      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Overlay_Selected_Entries;

   procedure Append_Unique_Path
     (Paths : in out Version.Status.File_Change_Vectors.Vector;
      Path  : String)
   is
   begin
      if not Paths.Is_Empty then
         for I in Paths.First_Index .. Paths.Last_Index loop
            if To_String (Paths.Element (I).Path) = Path then
               return;
            end if;
         end loop;
      end if;

      Paths.Append
        (Version.Status.File_Change'
           (Path => To_Unbounded_String (Path),
            Kind => Version.Status.Modified_File));
   end Append_Unique_Path;

   function Selected_Tracked_Paths
     (Status : Version.Status.Status_Result)
      return Version.Status.File_Change_Vectors.Vector
   is
      Result : Version.Status.File_Change_Vectors.Vector;
   begin
      if not Status.Changes.Is_Empty then
         for I in Status.Changes.First_Index .. Status.Changes.Last_Index loop
            Append_Unique_Path (Result, To_String (Status.Changes.Element (I).Path));
         end loop;
      end if;

      if not Status.Staged.Is_Empty then
         for I in Status.Staged.First_Index .. Status.Staged.Last_Index loop
            Append_Unique_Path (Result, To_String (Status.Staged.Element (I).Path));
         end loop;
      end if;

      return Result;
   end Selected_Tracked_Paths;

   function Untracked_Entries
     (Repo   : Version.Repository.Repository_Handle;
      Status : Version.Status.Status_Result)
      return Version.Staging.Index_Entry_Vectors.Vector;

   function Filter_Untracked_Entries
     (Entries   : Version.Staging.Index_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if Pathspecs.Is_Empty then
         return Entries;
      end if;

      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Path : constant String := To_String (Entries.Element (I).Path);
            begin
               if Path_Matches (Path, Pathspecs) then
                  Result.Append (Entries.Element (I));
               end if;
            end;
         end loop;
      end if;

      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Filter_Untracked_Entries;

   function Ignored_Untracked_Entries
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Index   : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Rules   : constant Version.Ignore.Ignore_Rules := Version.Ignore.Load (Repo);
      Working : constant Version.Working_Tree.Working_File_Vectors.Vector :=
        Version.Working_Tree.Scan (Repo);
      Result  : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if not Working.Is_Empty then
         for I in Working.First_Index .. Working.Last_Index loop
            declare
               Path : constant String := To_String (Working.Element (I).Path);
               Full : constant String := Join (Version.Repository.Root_Path (Repo), Path);
            begin
               if Version.Staging.Find_Path (Index, Path) = Natural'Last
                 and then Version.Ignore.Is_Ignored
                            (Rules         => Rules,
                             Relative_Path => Path,
                             Is_Directory  => False)
                 and then Path_Matches (Path, Pathspecs)
               then
                  Version.Path_Safety.Require_Safe_Relative_Path
                    (Path, "ignored stash path");
                  if Ada.Directories.Exists (Full)
                    and then Ada.Directories.Kind (Full) = Ada.Directories.Ordinary_File
                  then
                     Result.Append
                       (Version.Staging.Index_Entry'
                          (Path => To_Unbounded_String (Path),
                           Id   => Version.Write.Write_Blob
                                     (Repo    => Repo,
                                      Content => Version.Files.Read_Binary_File (Full)),
                           Mode => To_Unbounded_String ("100644"),
                           Stage => 0));
                  end if;
               end if;
            end;
         end loop;
      end if;

      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Ignored_Untracked_Entries;

   function Combined_Untracked_Entries
     (Repo              : Version.Repository.Repository_Handle;
      Status            : Version.Status.Status_Result;
      Include_Untracked : Boolean;
      Include_Ignored   : Boolean;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if Include_Untracked then
         Result := Filter_Untracked_Entries
           (Untracked_Entries (Repo, Status), Pathspecs);
      end if;

      if Include_Ignored then
         declare
            Ignored : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Ignored_Untracked_Entries (Repo, Pathspecs);
         begin
            if not Ignored.Is_Empty then
               for I in Ignored.First_Index .. Ignored.Last_Index loop
                  Version.Staging.Replace_Entry (Result, Ignored.Element (I));
               end loop;
            end if;
         end;
      end if;

      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Combined_Untracked_Entries;

   procedure Require_Clean_For_Apply
     (Repo : Version.Repository.Repository_Handle)
   is
      Status : constant Version.Status.Status_Result := Version.Status.Current_Status;
   begin
      if Version.Merge_State.State_Exists (Repo) then
         raise Ada.IO_Exceptions.Data_Error with
           Apply_In_Progress_State_Diagnostic;
      end if;
      if not Status.Changes.Is_Empty
        or else not Status.Staged.Is_Empty
        or else not Status.Untracked.Is_Empty
        or else not Status.Conflicted.Is_Empty
      then
         raise Ada.IO_Exceptions.Data_Error with
           Apply_Dirty_Working_Tree_Diagnostic;
      end if;
   end Require_Clean_For_Apply;

   function Index_Entries_With_Working_Tree
     (Repo : Version.Repository.Repository_Handle)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector := Version.Staging.Load (Repo);
   begin
      if not Result.Is_Empty then
         declare
            I : Natural := Result.First_Index;
         begin
            while I <= Result.Last_Index loop
               declare
                  Path : constant String := To_String (Result.Element (I).Path);
                  Full : constant String := Join (Version.Repository.Root_Path (Repo), Path);
               begin
                  Version.Path_Safety.Require_Safe_Relative_Path (Path, "stash path");
                  if not Ada.Directories.Exists (Full) then
                     Result.Delete (I);
                  elsif Ada.Directories.Kind (Full) /= Ada.Directories.Ordinary_File then
                     raise Ada.IO_Exceptions.Data_Error with
                       "cannot stash non-file path: " & Path;
                  else
                     declare
                        Blob_Id : constant Version.Objects.Hex_Object_Id :=
                          Version.Write.Write_Blob
                            (Repo    => Repo,
                             Content => Version.Files.Read_Binary_File (Full));
                        Current_Entry : Version.Staging.Index_Entry := Result.Element (I);
                     begin
                        Current_Entry.Id := Blob_Id;
                        Result.Replace_Element (I, Current_Entry);
                        I := I + 1;
                     end;
                  end if;
               end;
            end loop;
         end;
      end if;
      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Index_Entries_With_Working_Tree;

   function Untracked_Entries
     (Repo   : Version.Repository.Repository_Handle;
      Status : Version.Status.Status_Result)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
      Result : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if not Status.Untracked.Is_Empty then
         for I in Status.Untracked.First_Index .. Status.Untracked.Last_Index loop
            declare
               Path : constant String := To_String (Status.Untracked.Element (I).Path);
               Full : constant String := Join (Version.Repository.Root_Path (Repo), Path);
               Blob_Id : Version.Objects.Object_Id_Storage;
            begin
               Version.Path_Safety.Require_Safe_Relative_Path (Path, "untracked stash path");
               if Ada.Directories.Exists (Full)
                 and then Ada.Directories.Kind (Full) = Ada.Directories.Ordinary_File
               then
                  Blob_Id := Version.Write.Write_Blob
                    (Repo    => Repo,
                     Content => Version.Files.Read_Binary_File (Full));
                  Result.Append
                    (Version.Staging.Index_Entry'
                       (Path => To_Unbounded_String (Path),
                        Id   => Blob_Id,
                        Mode => To_Unbounded_String ("100644"),
                        Stage => 0));
               end if;
            end;
         end loop;
      end if;
      Version.Staging.Sort_By_Path (Result);
      return Result;
   end Untracked_Entries;

   procedure Preflight_Delete_Working_File
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
   is
      Normalized : constant String := Version.Path_Safety.Normalize_Relative_Path (Path);
      Full       : constant String := Join (Version.Repository.Root_Path (Repo), Normalized);
   begin
      Version.Path_Safety.Require_Safe_Relative_Path (Normalized, "stash path");
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Full)) then
         if Ada.Directories.Kind (Version.Files.To_Native_Path (Full)) = Ada.Directories.Ordinary_File then
            Version.Filesystem_Guard.Require_Safe_Delete_Target
              (Repo_Root     => Version.Repository.Root_Path (Repo),
               Relative_Path => Normalized);
         else
            raise Ada.IO_Exceptions.Data_Error with
              "cannot remove stashed non-file path: " & Normalized;
         end if;
      end if;
   end Preflight_Delete_Working_File;

   procedure Delete_Working_File
     (Repo : Version.Repository.Repository_Handle;
      Path : String)
   is
      Normalized : constant String := Version.Path_Safety.Normalize_Relative_Path (Path);
   begin
      Preflight_Delete_Working_File (Repo, Normalized);
      Version.Files.Remove_File_If_Safe
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Normalized);
   end Delete_Working_File;

   procedure Remove_Untracked_Files
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Version.Staging.Index_Entry_Vectors.Vector)
   is
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Preflight_Delete_Working_File
              (Repo, To_String (Entries.Element (I).Path));
         end loop;

         for I in Entries.First_Index .. Entries.Last_Index loop
            Delete_Working_File (Repo, To_String (Entries.Element (I).Path));
         end loop;
      end if;
   end Remove_Untracked_Files;

   procedure Restore_Selected_Tracked_Paths
     (Repo      : Version.Repository.Repository_Handle;
      Head_Id   : Version.Objects.Hex_Object_Id;
      Status    : Version.Status.Status_Result;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Paths   : constant Version.Status.File_Change_Vectors.Vector :=
        Selected_Tracked_Paths (Status);
   begin
      if Pathspecs.Is_Empty then
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo => Repo, Commit_Id => Head_Id);
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => Head_Id);
         return;
      end if;

      if not Paths.Is_Empty then
         for I in Paths.First_Index .. Paths.Last_Index loop
            declare
               Path : constant String := To_String (Paths.Element (I).Path);
            begin
               Version.Restore.Restore_Path_From_Commit
                 (Repo      => Repo,
                  Commit_Id => Head_Id,
                  Path      => Path,
                  Objects   => Objects,
                  Trees     => Trees);
               Version.Restore.Restore_Index_Path_From_Commit
                 (Repo      => Repo,
                  Commit_Id => Head_Id,
                  Path      => Path,
                  Objects   => Objects,
                  Trees     => Trees);
            end;
         end loop;
      end if;
   end Restore_Selected_Tracked_Paths;

   package Tree_Entry_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => Version.Objects.Tree_Entry);

   package Path_Flags is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,
      Element_Type => Boolean);

   procedure Append_Line (Text : in out Unbounded_String; Line : String) is
   begin
      Append (Text, Line);
      Append (Text, Character'Val (10));
   end Append_Line;

   function Tree_Map
     (Items : Version.Objects.Tree_Entry_Vectors.Vector)
      return Tree_Entry_Maps.Map
   is
      Result : Tree_Entry_Maps.Map;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Result.Include (To_String (Items.Element (I).Path), Items.Element (I));
         end loop;
      end if;
      return Result;
   end Tree_Map;

   function Commit_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit: " & To_String (Commit_Id);
      end if;

      return
        Version.Objects.Flatten_Tree
          (Repo => Repo, Tree_Id => Version.Objects.Commit_Tree_Id (Obj));
   end Commit_Tree;

   procedure Append_Tree_Summary
     (Result : in out Unbounded_String;
      Olds   : Version.Objects.Tree_Entry_Vectors.Vector;
      News   : Version.Objects.Tree_Entry_Vectors.Vector;
      Seen   : in out Path_Flags.Map)
   is
      Old_Map : constant Tree_Entry_Maps.Map := Tree_Map (Olds);
      New_Map : constant Tree_Entry_Maps.Map := Tree_Map (News);
      Paths   : Path_Flags.Map;
   begin
      if not Olds.Is_Empty then
         for I in Olds.First_Index .. Olds.Last_Index loop
            Paths.Include (To_String (Olds.Element (I).Path), True);
         end loop;
      end if;

      if not News.Is_Empty then
         for I in News.First_Index .. News.Last_Index loop
            Paths.Include (To_String (News.Element (I).Path), True);
         end loop;
      end if;

      declare
         Cursor : Path_Flags.Cursor := Paths.First;
      begin
         while Path_Flags.Has_Element (Cursor) loop
            declare
               Path       : constant String := Path_Flags.Key (Cursor);
               Old_Cursor : constant Tree_Entry_Maps.Cursor := Old_Map.Find (Path);
               New_Cursor : constant Tree_Entry_Maps.Cursor := New_Map.Find (Path);
               Old_Has    : constant Boolean := Tree_Entry_Maps.Has_Element (Old_Cursor);
               New_Has    : constant Boolean := Tree_Entry_Maps.Has_Element (New_Cursor);
            begin
               if not Seen.Contains (Path) then
                  if not Old_Has and then New_Has then
                     Append_Line (Result, "A " & Path);
                     Seen.Include (Path, True);
                  elsif Old_Has and then not New_Has then
                     Append_Line (Result, "D " & Path);
                     Seen.Include (Path, True);
                  elsif Old_Has and then New_Has
                    and then (Tree_Entry_Maps.Element (Old_Cursor).Id
                              /= Tree_Entry_Maps.Element (New_Cursor).Id
                              or else Tree_Entry_Maps.Element (Old_Cursor).Mode
                                      /= Tree_Entry_Maps.Element (New_Cursor).Mode)
                  then
                     Append_Line (Result, "M " & Path);
                     Seen.Include (Path, True);
                  end if;
               end if;
            end;
            Path_Flags.Next (Cursor);
         end loop;
      end;
   end Append_Tree_Summary;

   procedure Require_Malformed_Stash_Reflog (Condition : Boolean) is
   begin
      if not Condition then
         raise Ada.IO_Exceptions.Data_Error with Malformed_Stash_Reflog_Diagnostic;
      end if;
   end Require_Malformed_Stash_Reflog;

   function Reflog_Tab_Index (Line : String) return Natural is
      Tab : constant Natural :=
        Ada.Strings.Fixed.Index (Line, String'(1 => Character'Val (9)));
   begin
      Require_Malformed_Stash_Reflog (Tab /= 0 and then Tab < Line'Last);
      return Tab;
   end Reflog_Tab_Index;

   function Read_Reflog_Message (Line : String) return String is
      Tab : constant Natural := Reflog_Tab_Index (Line);
   begin
      return Line (Tab + 1 .. Line'Last);
   end Read_Reflog_Message;

   type Raw_Stash_Reflog_Entry is record
      Index   : Natural;
      Old_Id  : Version.Objects.Object_Id_Storage;
      New_Id  : Version.Objects.Object_Id_Storage;
      Message : Unbounded_String;
   end record;

   package Raw_Stash_Reflog_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Raw_Stash_Reflog_Entry);

   function Read_Reflog_Entry (Line : String) return Raw_Stash_Reflog_Entry is
      --  "<old> <new> <who>\t<msg>": old/new are the first two space-separated
      --  hex ids (40 or 64), so split on spaces rather than assuming a width.
      First_Space  : Natural := 0;
      Second_Space : Natural := 0;
   begin
      for I in Line'Range loop
         if Line (I) = ' ' then
            if First_Space = 0 then
               First_Space := I;
            else
               Second_Space := I;
               exit;
            end if;
         end if;
      end loop;

      Require_Malformed_Stash_Reflog
        (First_Space /= 0 and then Second_Space /= 0);
      declare
         Old_Text : constant String := Line (Line'First .. First_Space - 1);
         New_Text : constant String := Line (First_Space + 1 .. Second_Space - 1);
         Message  : constant String := Read_Reflog_Message (Line);
      begin
         Require_Malformed_Stash_Reflog
           (Version.Objects.Is_Valid_Hex_Object_Id (Old_Text));
         Require_Malformed_Stash_Reflog
           (Version.Objects.Is_Valid_Hex_Object_Id (New_Text));
         return
           Raw_Stash_Reflog_Entry'
             (Index   => 0,
              Old_Id  => Version.Objects.To_Object_Id (Old_Text),
              New_Id  => Version.Objects.To_Object_Id (New_Text),
              Message => To_Unbounded_String (Message));
      end;
   end Read_Reflog_Entry;

   procedure Read_Reflog_Lines
     (Repo   : Version.Repository.Repository_Handle;
      Lines  : in out Raw_Stash_Reflog_Entry_Vectors.Vector)
   is
      Path : constant String := Stash_Reflog_Path (Repo);
      File : Ada.Text_IO.File_Type;
      Raw_Index : Natural := 0;
   begin
      Lines.Clear;
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            declare
               Parsed : Raw_Stash_Reflog_Entry := Read_Reflog_Entry (Line);
            begin
               Parsed.Index := Raw_Index;
               Lines.Append (Parsed);
               Raw_Index := Raw_Index + 1;
            end;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_Reflog_Lines;

   procedure Validate_Stash_Storage_Consistency
     (Repo : Version.Repository.Repository_Handle;
      Raw  : Raw_Stash_Reflog_Entry_Vectors.Vector)
   is
   begin
      if Raw.Is_Empty then
         return;
      end if;

      if not Version.Refs.Ref_Exists (Repo, Stash_Ref) then
         raise Ada.IO_Exceptions.Data_Error with Inconsistent_Stash_Storage_Diagnostic;
      end if;

      declare
         Ref_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Refs.Resolve_Ref (Repo, Stash_Ref);
         Newest_Reflog_Id : constant Version.Objects.Hex_Object_Id :=
           Raw.Element (Raw.Last_Index).New_Id;
      begin
         if Ref_Id /= Newest_Reflog_Id then
            raise Ada.IO_Exceptions.Data_Error with Inconsistent_Stash_Storage_Diagnostic;
         end if;
      end;

      declare
         Expected_Old : Version.Objects.Hex_Object_Id := Null_Id (Repo);
      begin
         for I in Raw.First_Index .. Raw.Last_Index loop
            if Raw.Element (I).Old_Id /= Expected_Old then
               raise Ada.IO_Exceptions.Data_Error with Inconsistent_Stash_Storage_Diagnostic;
            end if;
            Expected_Old := Raw.Element (I).New_Id;
         end loop;
      end;
   end Validate_Stash_Storage_Consistency;

   function List_Entries
     (Repo : Version.Repository.Repository_Handle)
      return Stash_Entry_Vectors.Vector
   is
      Raw : Raw_Stash_Reflog_Entry_Vectors.Vector;
      Result : Stash_Entry_Vectors.Vector;
      N : Natural := 0;
   begin
      Read_Reflog_Lines (Repo, Raw);
      Validate_Stash_Storage_Consistency (Repo, Raw);
      if not Raw.Is_Empty then
         for I in reverse Raw.First_Index .. Raw.Last_Index loop
            declare
               Current_Entry : constant Raw_Stash_Reflog_Entry := Raw.Element (I);
            begin
               Result.Append
                 (Stash_Entry'
                    (Index   => N,
                     Id      => Current_Entry.New_Id,
                     Message => Current_Entry.Message));
               N := N + 1;
            end;
         end loop;
      end if;
      return Result;
   end List_Entries;

   function Resolve_Stash
     (Repo : Version.Repository.Repository_Handle;
      Spec : String := "stash@{0}")
      return Version.Objects.Hex_Object_Id
   is
      Entries : constant Stash_Entry_Vectors.Vector := List_Entries (Repo);
      N       : Natural;
   begin
      if Entries.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with No_Stash_Entries_Diagnostic;
      end if;

      N := Parse_Stash_Index (Spec);
      if N >= Natural (Entries.Length) then
         raise Ada.IO_Exceptions.Data_Error with Stash_Spec_Out_Of_Range_Diagnostic (Spec);
      end if;
      return Entries.Element (Entries.First_Index + N).Id;
   end Resolve_Stash;

   function Filter_Tree
     (Items     : Version.Objects.Tree_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Result : Version.Objects.Tree_Entry_Vectors.Vector;
   begin
      if Pathspecs.Is_Empty then
         return Items;
      end if;

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  Result.Append (Items.Element (I));
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Filter_Tree;

   function Show
     (Spec      : String := "stash@{0}";
      Patch     : Boolean := False;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String
   is
      Repo      : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Stash_Id  : constant Version.Objects.Hex_Object_Id := Resolve_Stash (Repo, Spec);
      Stash_Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Stash_Id);
      Parents   : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Stash_Obj);
   begin
      if Version.Objects.Kind (Stash_Obj) /= Version.Objects.Commit_Object
        or else Parents.Length < 2
        or else Parents.Length > 3
      then
         raise Ada.IO_Exceptions.Data_Error with "malformed stash commit";
      end if;

      declare
         Base_Id : constant Version.Objects.Hex_Object_Id :=
           Parents.Element (Parents.First_Index);
      begin
         if Patch then
            declare
               Result : Unbounded_String;
            begin
               Append
                 (Result,
                  Version.Diff.Diff_Commits
                    (Repo      => Repo,
                     Old_Id    => Base_Id,
                     New_Id    => Stash_Id,
                     Pathspecs => Pathspecs));
               if Parents.Length = 3 then
                  Append
                    (Result,
                     Version.Diff.Diff_Root_Commit
                       (Repo      => Repo,
                        Commit_Id => Parents.Element (Parents.First_Index + 2),
                        Pathspecs => Pathspecs));
               end if;
               return To_String (Result);
            end;
         else
            declare
               Result : Unbounded_String;
               Seen   : Path_Flags.Map;
            begin
               Append_Tree_Summary
                 (Result => Result,
                  Olds   => Filter_Tree (Commit_Tree (Repo, Base_Id), Pathspecs),
                  News   => Filter_Tree (Commit_Tree (Repo, Stash_Id), Pathspecs),
                  Seen   => Seen);
               if Parents.Length = 3 then
                  declare
                     Empty : Version.Objects.Tree_Entry_Vectors.Vector;
                  begin
                     Append_Tree_Summary
                       (Result => Result,
                        Olds   => Empty,
                        News   =>
                          Filter_Tree
                            (Commit_Tree
                               (Repo, Parents.Element (Parents.First_Index + 2)),
                             Pathspecs),
                        Seen   => Seen);
                  end;
               end if;
               return To_String (Result);
            end;
         end if;
      end;
   end Show;

   function Stash_Base_Commit
     (Repo : Version.Repository.Repository_Handle;
      Spec : String)
      return Version.Objects.Hex_Object_Id
   is
      Stash_Id  : constant Version.Objects.Hex_Object_Id :=
        Resolve_Stash (Repo, Spec);
      Stash_Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Stash_Id);
      Parents   : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Stash_Obj);
   begin
      if Version.Objects.Kind (Stash_Obj) /= Version.Objects.Commit_Object
        or else Parents.Length < 2
        or else Parents.Length > 3
      then
         raise Ada.IO_Exceptions.Data_Error with "malformed stash commit";
      end if;

      return Parents.Element (Parents.First_Index);
   end Stash_Base_Commit;

   function Selected_Untracked_For_Stash
     (Repo              : Version.Repository.Repository_Handle;
      Status            : Version.Status.Status_Result;
      Include_Untracked : Boolean;
      Include_Ignored   : Boolean;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector)
      return Version.Staging.Index_Entry_Vectors.Vector
   is
   begin
      return
        Combined_Untracked_Entries
          (Repo              => Repo,
           Status            => Status,
           Include_Untracked => Include_Untracked,
           Include_Ignored   => Include_Ignored,
           Pathspecs         => Pathspecs);
   end Selected_Untracked_For_Stash;

   function Create
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Head_Id : Version.Objects.Object_Id_Storage;
      Status : constant Version.Status.Status_Result :=
        (if Pathspecs.Is_Empty
         then Version.Status.Current_Status
         else Version.Status.Current_Status (Pathspecs));
   begin
      Require_Head (Repo, Head_Id);
      declare
         Selected_Untracked : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Selected_Untracked_For_Stash
             (Repo              => Repo,
              Status            => Status,
              Include_Untracked => Include_Untracked,
              Include_Ignored   => Include_Ignored,
              Pathspecs         => Pathspecs);
      begin
         if Status_Is_Clean
              (Status, Include_Untracked, Include_Ignored,
               Natural (Selected_Untracked.Length))
         then
            return "";
         end if;

         declare
            Head_Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit (Repo, Head_Id);
            Head_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Tree_As_Index_Entries (Repo, Head_Tree_Id);
            Full_Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Version.Staging.Load (Repo);
            Full_Work_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Index_Entries_With_Working_Tree (Repo);
            Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Overlay_Selected_Entries (Head_Entries, Full_Index_Entries, Pathspecs);
            Work_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Overlay_Selected_Entries (Head_Entries, Full_Work_Entries, Pathspecs);
            Index_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Index_Entries);
            Work_Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Tree_From_Index (Repo => Repo, Entries => Work_Entries);
            Index_Commit : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit
                (Repo      => Repo,
                 Tree_Id   => Index_Tree,
                 Parent_Id => To_String (Head_Id),
                 Message   => Stash_Message (Repo, Head_Id, "index"));
            Parents : Version.Objects.Object_Id_Vectors.Vector;
         begin
            Parents.Append (Head_Id);
            Parents.Append (Index_Commit);
            if not Selected_Untracked.Is_Empty then
               declare
                  UTree : constant Version.Objects.Hex_Object_Id :=
                    Version.Write.Write_Tree_From_Index
                      (Repo => Repo, Entries => Selected_Untracked);
                  UCommit : constant Version.Objects.Hex_Object_Id :=
                    Version.Write.Write_Commit
                      (Repo      => Repo,
                       Tree_Id   => UTree,
                       Parent_Id => To_String (Head_Id),
                       Message   => Stash_Message (Repo, Head_Id, "untracked files"));
               begin
                  Parents.Append (UCommit);
               end;
            end if;

            return
              To_String
                (Version.Write.Write_Commit_With_Parents
                   (Repo    => Repo,
                    Tree_Id => Work_Tree,
                    Parents => Parents,
                    Message => Stash_Message (Repo, Head_Id, "WIP")));
         end;
      end;
   end Create;

   procedure Validate_Stash_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object
        or else Parents.Length < 2
        or else Parents.Length > 3
      then
         raise Ada.IO_Exceptions.Data_Error with "malformed stash commit";
      end if;
   end Validate_Stash_Commit;

   procedure Store
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Message   : String := "")
   is
      Repo   : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Old_Id : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);
   begin
      Validate_Stash_Commit (Repo, Commit_Id);
      declare
         Subject : constant String := Commit_Subject (Repo, Commit_Id);
         Reflog_Message : constant String :=
           (if Message'Length /= 0 then Message
            elsif Subject'Length /= 0 then Subject
            else "store: " & To_String (Commit_Id));
      begin
         Update_Stash_Ref
           (Repo         => Repo,
            New_Id       => Commit_Id,
            Expected_Old => Old_Id);
         Version.Reflog.Append
           (Repo    => Repo,
            Ref     => Stash_Ref,
            Old_Id  => Old_Id,
            New_Id  => To_String (Commit_Id),
            Message => Reflog_Message);
      end;
   end Store;

   procedure Push
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Head_Id : Version.Objects.Object_Id_Storage;
      Status : constant Version.Status.Status_Result :=
        (if Pathspecs.Is_Empty
         then Version.Status.Current_Status
         else Version.Status.Current_Status (Pathspecs));
   begin
      Require_Head (Repo, Head_Id);
      declare
         Selected_Untracked : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Selected_Untracked_For_Stash
             (Repo              => Repo,
              Status            => Status,
              Include_Untracked => Include_Untracked,
              Include_Ignored   => Include_Ignored,
              Pathspecs         => Pathspecs);
      begin
         if Status_Is_Clean
              (Status, Include_Untracked, Include_Ignored,
               Natural (Selected_Untracked.Length))
         then
            return;
         end if;

         declare
            Stash_Text : constant String :=
              Create
                (Include_Untracked => Include_Untracked,
                 Include_Ignored   => Include_Ignored,
                 Pathspecs         => Pathspecs);
            Stash_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Stash_Text);
            Old_Id   : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);
            Message  : constant String := Stash_Message (Repo, Head_Id, "WIP");
         begin
            Update_Stash_Ref
              (Repo         => Repo,
               New_Id       => Stash_Id,
               Expected_Old => Old_Id);
            Version.Reflog.Append
              (Repo    => Repo,
               Ref     => Stash_Ref,
               Old_Id  => Old_Id,
               New_Id  => To_String (Stash_Id),
               Message => Message);
            Restore_Selected_Tracked_Paths
              (Repo      => Repo,
               Head_Id   => Head_Id,
               Status    => Status,
               Pathspecs => Pathspecs);
            if Include_Untracked or else Include_Ignored then
               Remove_Untracked_Files (Repo, Selected_Untracked);
            end if;
         end;
      end;
   end Push;

   function Natural_Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Natural_Image;

   procedure List is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Entries : constant Stash_Entry_Vectors.Vector := List_Entries (Repo);
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            Ada.Text_IO.Put_Line
              ("stash@{" & Natural_Image (Entries.Element (I).Index)
               & "}: " & To_String (Entries.Element (I).Message));
         end loop;
      end if;
   end List;

   function Tree_Has_Pathspec_Match
     (Items     : Version.Objects.Tree_Entry_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
   begin
      if Pathspecs.Is_Empty then
         return not Items.Is_Empty;
      end if;

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Version.Pathspec.Matches_Any
                 (Pathspecs, To_String (Items.Element (I).Path))
            then
               return True;
            end if;
         end loop;
      end if;

      return False;
   end Tree_Has_Pathspec_Match;

   function Stash_Has_Pathspec_Match
     (Repo      : Version.Repository.Repository_Handle;
      Stash_Obj : Version.Objects.Git_Object;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
      Stash_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree
          (Repo => Repo, Tree_Id => Version.Objects.Commit_Tree_Id (Stash_Obj));
   begin
      if Tree_Has_Pathspec_Match (Stash_Items, Pathspecs) then
         return True;
      end if;

      if Parents.Length = 3 then
         declare
            UTree_Id : constant Version.Objects.Hex_Object_Id :=
              Tree_Id_For_Commit (Repo, Parents.Element (Parents.First_Index + 2));
            UItems : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => UTree_Id);
         begin
            return Tree_Has_Pathspec_Match (UItems, Pathspecs);
         end;
      end if;

      return False;
   end Stash_Has_Pathspec_Match;

   procedure Preflight_Selected_Paths_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit (Repo, Objects, Commit_Id);
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               if Version.Pathspec.Matches_Any (Pathspecs, Path) then
                  Version.Path_Safety.Require_Safe_Relative_Path
                    (Path, "stash tracked path");
                  Version.Filesystem_Guard.Require_Safe_Write_Target
                    (Repo_Root     => Version.Repository.Root_Path (Repo),
                     Relative_Path => Path);
               end if;
            end;
         end loop;
      end if;
   end Preflight_Selected_Paths_From_Commit;

   procedure Restore_Selected_Paths_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Tree_Id_For_Commit (Repo, Objects, Commit_Id);
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               if Version.Pathspec.Matches_Any (Pathspecs, Path) then
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
               end if;
            end;
         end loop;
      end if;
   end Restore_Selected_Paths_From_Commit;

   procedure Preflight_Untracked_Parent
     (Repo      : Version.Repository.Repository_Handle;
      Parent_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id := Tree_Id_For_Commit (Repo, Parent_Id);
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  declare
                     Full : constant String := Join (Version.Repository.Root_Path (Repo), Path);
                     Obj : constant Version.Objects.Git_Object :=
                       Version.Objects.Read_Object (Repo, Items.Element (I).Id);
                  begin
                     Version.Path_Safety.Require_Safe_Relative_Path
                       (Path, "stash untracked path");
                     Version.Filesystem_Guard.Require_Safe_Write_Target
                       (Repo_Root     => Version.Repository.Root_Path (Repo),
                        Relative_Path => Path);
                     if Ada.Directories.Exists (Full) then
                        raise Ada.IO_Exceptions.Data_Error with
                          "untracked path already exists: " & Path;
                     end if;
                     if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                        raise Ada.IO_Exceptions.Data_Error with
                          "stash untracked path is not a blob: " & Path;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end if;
   end Preflight_Untracked_Parent;

   procedure Apply_Untracked_Parent
     (Repo      : Version.Repository.Repository_Handle;
      Parent_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id := Tree_Id_For_Commit (Repo, Parent_Id);
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Path : constant String := To_String (Items.Element (I).Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  declare
                     Full : constant String := Join (Version.Repository.Root_Path (Repo), Path);
                     Obj : constant Version.Objects.Git_Object :=
                       Version.Objects.Read_Object (Repo, Items.Element (I).Id);
                  begin
                     Version.Path_Safety.Require_Safe_Relative_Path
                       (Path, "stash untracked path");
                     Version.Filesystem_Guard.Require_Safe_Write_Target
                       (Repo_Root     => Version.Repository.Root_Path (Repo),
                        Relative_Path => Path);
                     if Ada.Directories.Exists (Full) then
                        raise Ada.IO_Exceptions.Data_Error with
                          "untracked path already exists: " & Path;
                     end if;
                     if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
                        raise Ada.IO_Exceptions.Data_Error with
                          "stash untracked path is not a blob: " & Path;
                     end if;
                     Version.Files.Write_Binary_File_Atomic
                       (Path => Full, Content => Version.Objects.Content (Obj));
                  end;
               end if;
            end;
         end loop;
      end if;
   end Apply_Untracked_Parent;

   function Apply_Commit_Internal
     (Stash_Id  : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Boolean
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Head_Id : Version.Objects.Object_Id_Storage;
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Stash_Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Stash_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Stash_Obj);
   begin
      Require_Head (Repo, Head_Id);
      Require_Clean_For_Apply (Repo);
      if Version.Objects.Kind (Stash_Obj) /= Version.Objects.Commit_Object
        or else Parents.Length < 2
        or else Parents.Length > 3
      then
         raise Ada.IO_Exceptions.Data_Error with "malformed stash commit";
      end if;

      if not Pathspecs.Is_Empty then
         if not Stash_Has_Pathspec_Match (Repo, Stash_Obj, Parents, Pathspecs) then
            return False;
         end if;

         Preflight_Selected_Paths_From_Commit
           (Repo      => Repo,
            Commit_Id => Stash_Id,
            Pathspecs => Pathspecs,
            Objects   => Objects,
            Trees     => Trees);
         if Parents.Length = 3 then
            Preflight_Untracked_Parent
              (Repo      => Repo,
               Parent_Id => Parents.Element (Parents.First_Index + 2),
               Pathspecs => Pathspecs);
         end if;

         Restore_Selected_Paths_From_Commit
           (Repo      => Repo,
            Commit_Id => Stash_Id,
            Pathspecs => Pathspecs,
            Objects   => Objects,
            Trees     => Trees);
         if Parents.Length = 3 then
            Apply_Untracked_Parent
              (Repo      => Repo,
               Parent_Id => Parents.Element (Parents.First_Index + 2),
               Pathspecs => Pathspecs);
         end if;
         Version.Merge_State.Clear_State (Repo);
         return True;
      end if;

      declare
         Base_Id : constant Version.Objects.Hex_Object_Id := Parents.Element (Parents.First_Index);
         Base_Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Tree_Id_For_Commit (Repo, Objects, Base_Id);
         Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Tree_Id_For_Commit (Repo, Objects, Head_Id);
         Target_Tree_Id : constant Version.Objects.Hex_Object_Id := Version.Objects.Commit_Tree_Id (Stash_Obj);
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (Repo => Repo, Cache => Trees, Tree_Id => Base_Tree_Id);
         Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (Repo => Repo, Cache => Trees, Tree_Id => Current_Tree_Id);
         Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (Repo => Repo, Cache => Trees, Tree_Id => Target_Tree_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
      begin
         Version.Restore.Restore_Working_Tree_For_Commit
           (Repo => Repo, Commit_Id => Head_Id, Objects => Objects, Trees => Trees);
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => Head_Id, Objects => Objects, Trees => Trees);
         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "stash-current",
            Target_Name   => "stash",
            Base_Items    => Base_Items,
            Current_Items => Current_Items,
            Target_Items  => Target_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts);
         if not Conflicts.Is_Empty then
            Version.Merge_State.Clear_State (Repo);
            Version.Merge_State.Write_State
              (Repo          => Repo,
               Current_Id    => Head_Id,
               Target_Id     => Stash_Id,
               Base_Id       => Base_Id,
               Target_Branch => "stash",
               Conflicts     => Conflicts);
            raise Ada.IO_Exceptions.Data_Error with Apply_Conflicts_Diagnostic;
         end if;
         Version.Restore.Write_Index_For_Commit
           (Repo => Repo, Commit_Id => Head_Id, Objects => Objects, Trees => Trees);
         if Parents.Length = 3 then
            Apply_Untracked_Parent
              (Repo      => Repo,
               Parent_Id => Parents.Element (Parents.First_Index + 2),
               Pathspecs => Version.Pathspec.Pathspec_Vectors.Empty_Vector);
         end if;
         Version.Merge_State.Clear_State (Repo);
         return True;
      end;
   end Apply_Commit_Internal;

   function Apply_Internal
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Boolean
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Stash_Id : constant Version.Objects.Hex_Object_Id := Resolve_Stash (Repo, Spec);
   begin
      return Apply_Commit_Internal (Stash_Id => Stash_Id, Pathspecs => Pathspecs);
   end Apply_Internal;

   procedure Apply_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
   is
      Applied : constant Boolean :=
        Apply_Commit_Internal (Stash_Id => Commit_Id, Pathspecs => Pathspecs);
      pragma Unreferenced (Applied);
   begin
      null;
   end Apply_Commit;

   procedure Apply_Autostash (Stash_Id : Version.Objects.Hex_Object_Id) is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
      Stash_Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Stash_Id);
      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Stash_Obj);
   begin
      if Version.Objects.Kind (Stash_Obj) /= Version.Objects.Commit_Object
        or else Parents.Length < 2 or else Parents.Length > 3
      then
         raise Ada.IO_Exceptions.Data_Error with "malformed stash commit";
      end if;

      declare
         Base_Id : constant Version.Objects.Hex_Object_Id :=
           Parents.Element (Parents.First_Index);
         Base_Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Tree_Id_For_Commit (Repo, Objects, Base_Id);
         --  "current" is the live index, which may carry a staged --no-commit
         --  merge result; using it (instead of HEAD) preserves that result.
         Current_Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Tree_From_Index
             (Repo => Repo, Entries => Version.Staging.Load (Repo));
         Target_Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Stash_Obj);
         Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree
             (Repo => Repo, Cache => Trees, Tree_Id => Base_Tree_Id);
         Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree
             (Repo => Repo, Cache => Trees, Tree_Id => Current_Tree_Id);
         Target_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree
             (Repo => Repo, Cache => Trees, Tree_Id => Target_Tree_Id);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts : Version.Merge.Conflict_Vectors.Vector;
      begin
         --  Merge_Trees materializes the merged result into the working tree
         --  (Update_Worktree defaults True); we deliberately do NOT write the
         --  index, leaving any staged merge result in place.
         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  => "stash-current",
            Target_Name   => "stash",
            Base_Items    => Base_Items,
            Current_Items => Current_Items,
            Target_Items  => Target_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts);

         if not Conflicts.Is_Empty then
            raise Ada.IO_Exceptions.Data_Error with Apply_Conflicts_Diagnostic;
         end if;

         if Parents.Length = 3 then
            Apply_Untracked_Parent
              (Repo      => Repo,
               Parent_Id => Parents.Element (Parents.First_Index + 2),
               Pathspecs => Version.Pathspec.Pathspec_Vectors.Empty_Vector);
         end if;
      end;
   end Apply_Autostash;

   function Apply_Selected
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean
   is
   begin
      return Apply_Internal (Spec, Pathspecs);
   end Apply_Selected;

   procedure Apply
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
   is
      Applied : constant Boolean := Apply_Internal (Spec, Pathspecs);
      pragma Unreferenced (Applied);
   begin
      null;
   end Apply;

   procedure Ensure_Stash_Rewrite_Available
     (Repo : Version.Repository.Repository_Handle)
   is
      Log_Path : constant String :=
        Stash_Reflog_Path (Repo);
      Log_Lock_Path : constant String := Log_Path & ".lock";
      Ref_Lock_Path : constant String :=
        Join (Version.Repository.Common_Git_Dir (Repo), Stash_Ref) & ".lock";
      Native_Log_Path : constant String := Version.Files.To_Native_Path (Log_Path);
   begin
      if Ada.Directories.Exists (Version.Files.To_Native_Path (Ref_Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Ref_Lock_Path;
      end if;

      if Ada.Directories.Exists (Version.Files.To_Native_Path (Log_Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Log_Lock_Path;
      end if;

      if Ada.Directories.Exists (Native_Log_Path)
        and then Ada.Directories.Kind (Native_Log_Path) /= Ada.Directories.Ordinary_File
      then
         raise Ada.IO_Exceptions.Data_Error
           with "stash reflog is not an ordinary file: " & Log_Path;
      end if;
   end Ensure_Stash_Rewrite_Available;

   procedure Rewrite_Stash_Reflog
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Stash_Entry_Vectors.Vector)
   is
      Path : constant String := Stash_Reflog_Path (Repo);
      Lock_Path : constant String := Path & ".lock";
      Old_Id : Version.Objects.Hex_Object_Id := Null_Id (Repo);
   begin
      Ensure_Stash_Rewrite_Available (Repo);

      if Entries.Is_Empty then
         declare
            Expected_Old : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);

            procedure Delete_Stash_Log is
               Native_Path : constant String := Version.Files.To_Native_Path (Path);
            begin
               if not Ada.Directories.Exists (Native_Path) then
                  return;
               elsif Ada.Directories.Kind (Native_Path) /= Ada.Directories.Ordinary_File then
                  raise Ada.IO_Exceptions.Data_Error
                    with "stash reflog is not an ordinary file: " & Path;
               end if;

               Ada.Directories.Delete_File (Native_Path);
            end Delete_Stash_Log;

            procedure Restore_Stash_Ref is
            begin
               if Expected_Old /= To_String (Null_Id (Repo)) then
                  Update_Stash_Ref
                    (Repo         => Repo,
                     New_Id       => Version.Objects.To_Object_Id (Expected_Old),
                     Expected_Old => To_String (Null_Id (Repo)));
               end if;
            end Restore_Stash_Ref;
         begin
            Delete_Stash_Ref
              (Repo         => Repo,
               Expected_Old => Expected_Old);

            begin
               Delete_Stash_Log;
            exception
               when others =>
                  Restore_Stash_Ref;
                  raise;
            end;
         end;

         return;
      end if;

      declare
         Previous_Exists : constant Boolean := Version.Files.Is_Ordinary_File (Path);
         Previous_Log : constant String :=
           (if Previous_Exists then Version.Files.Read_Binary_File (Path) else "");
         Expected_Old : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);
         Content : Unbounded_String;

         procedure Restore_Previous_Log is
         begin
            if Previous_Exists then
               Version.Files.Write_Binary_File_Atomic
                 (Path    => Path,
                  Content => Previous_Log);
            else
               Version.Files.Delete_File_If_Exists (Path);
            end if;
         end Restore_Previous_Log;
      begin
         for I in reverse Entries.First_Index .. Entries.Last_Index loop
            declare
               Current_Entry : constant Stash_Entry := Entries.Element (I);
            begin
               Append
                 (Content,
                  To_String (Old_Id) & " " & To_String (Current_Entry.Id)
                  & " Version <version@example.invalid> 0 +0000"
                  & Character'Val (9) & To_String (Current_Entry.Message)
                  & Character'Val (10));
               Old_Id := Current_Entry.Id;
            end;
         end loop;

         Version.Files.Create_Parent_Directories (Path);

         begin
            Version.Files.Write_Binary_File
              (Path    => Lock_Path,
               Content => To_String (Content));
            Version.Files.Atomic_Replace (Lock_Path, Path);
         exception
            when others =>
               Version.Files.Delete_File_If_Exists (Lock_Path);
               raise;
         end;

         begin
            Update_Stash_Ref
              (Repo         => Repo,
               New_Id       => Entries.First_Element.Id,
               Expected_Old => Expected_Old);
         exception
            when others =>
               Restore_Previous_Log;
               raise;
         end;
      end;
   end Rewrite_Stash_Reflog;

   procedure Drop
     (Spec : String := "stash@{0}")
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Entries : Stash_Entry_Vectors.Vector := List_Entries (Repo);
      Stash_Id : constant Version.Objects.Hex_Object_Id := Resolve_Stash (Repo, Spec);
      N : constant Natural := Parse_Stash_Index (Spec);
   begin
      Validate_Stash_Commit (Repo, Stash_Id);
      Entries.Delete (Entries.First_Index + N);
      Rewrite_Stash_Reflog (Repo, Entries);
   end Drop;

   procedure Clear is
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Entries : Stash_Entry_Vectors.Vector;
   begin
      Rewrite_Stash_Reflog (Repo, Entries);
   end Clear;

   procedure Pop
     (Spec      : String := "stash@{0}";
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   begin
      Ensure_Stash_Rewrite_Available (Repo);

      if Apply_Internal (Spec, Pathspecs) then
         Drop (Spec);
      end if;
   end Pop;

   procedure Branch
     (Name : String;
      Spec : String := "stash@{0}")
   is
      Repo    : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Base_Id : Version.Objects.Object_Id_Storage;
   begin
      Ensure_Stash_Rewrite_Available (Repo);
      Require_Clean_For_Apply (Repo);
      Base_Id := Stash_Base_Commit (Repo, Spec);

      Version.Branch.Create_Branch (Name, To_String (Base_Id));

      begin
         Version.Branch.Switch_Branch (Name);
         Apply (Spec);
         Drop (Spec);
      exception
         when others =>
            if Version.Branch.Current_Branch_Name /= Name
              and then Version.Branch.Branch_Exists (Name)
            then
               Version.Branch.Delete_Branch (Name => Name, Force => True);
            end if;

            raise;
      end;
   end Branch;

end Version.Stash;
