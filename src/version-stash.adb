with Ada.Containers; use Ada.Containers;
with Ada.Exceptions;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

with Version.Branch;
with Version.Config;
with Version.Revisions;
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
         --  git spells a detached HEAD "(no branch)" in stash messages.
         return "(no branch)";
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

   --  The stash's own title: git's "On <branch>: <message>" when the user
   --  gave `-m`, otherwise the default "WIP on <branch>: <short> <subject>".
   function Top_Stash_Message
     (Repo    : Version.Repository.Repository_Handle;
      Head_Id : Version.Objects.Hex_Object_Id;
      Message : String)
      return String
   is
   begin
      if Message /= "" then
         return "On " & Head_Name (Repo) & ": " & Message;
      else
         return Stash_Message (Repo, Head_Id, "WIP");
      end if;
   end Top_Stash_Message;

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
                     Stage => 0, Skip_Worktree => False, Assume_Valid => False, Intent_To_Add => False));
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
           (Path     => To_Unbounded_String (Path),
            Kind     => Version.Status.Modified_File,
            Old_Path => Null_Unbounded_String));
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
                  if Version.Files.Exists (Full)
                    and then Ada.Directories.Kind (Full) = Ada.Directories.Ordinary_File
                  then
                     Result.Append
                       (Version.Staging.Index_Entry'
                          (Path => To_Unbounded_String (Path),
                           Id   => Version.Write.Write_Blob
                                     (Repo    => Repo,
                                      Content => Version.Files.Read_Binary_File (Full)),
                           Mode => To_Unbounded_String ("100644"),
                           Stage => 0, Skip_Worktree => False, Assume_Valid => False, Intent_To_Add => False));
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
      --  Untracked files never block an apply: git ignores them here (they
      --  are not part of what the stash restores), and refusing on them made
      --  `stash pop` fail in the extremely ordinary case of one stray new file
      --  sitting in the tree.
      if not Status.Changes.Is_Empty
        or else not Status.Staged.Is_Empty
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
                  if not Version.Files.Exists (Full) then
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
               if Version.Files.Exists (Full)
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
                        Stage => 0, Skip_Worktree => False, Assume_Valid => False, Intent_To_Add => False));
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
      if Version.Files.Exists (Version.Files.To_Native_Path (Full)) then
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

         --  git's `clean -fd` takes the directories with the files.
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Path : constant String := To_String (Entries.Element (I).Path);
               Last : Natural := Path'Last;
            begin
               while Last >= Path'First loop
                  if Path (Last) = '/' then
                     declare
                        Dir : constant String :=
                          Join (Version.Repository.Root_Path (Repo),
                                Path (Path'First .. Last - 1));
                        Search : Ada.Directories.Search_Type;
                        Empty  : Boolean := True;
                     begin
                        exit when not Version.Files.Exists (Dir);
                        Ada.Directories.Start_Search (Search, Dir, "");
                        while Ada.Directories.More_Entries (Search) loop
                           declare
                              Item : Ada.Directories.Directory_Entry_Type;
                           begin
                              Ada.Directories.Get_Next_Entry (Search, Item);
                              if Ada.Directories.Simple_Name (Item)
                                 not in "." | ".."
                              then
                                 Empty := False;
                              end if;
                           end;
                        end loop;
                        Ada.Directories.End_Search (Search);
                        exit when not Empty;
                        Ada.Directories.Delete_Directory (Dir);
                     end;
                  end if;
                  Last := Last - 1;
               end loop;
            exception
               when others =>
                  null;   --  a directory we may not remove simply stays
            end;
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
      if not Version.Files.Exists (Path) then
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

   function Show
     (Spec      : String := "stash@{0}";
      Options   : Version.Diff.Diff_Options := (others => <>);
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

      --  git renders `stash show` as a diff between the stash and its base,
      --  through the ordinary diff engine, so every format (the default
      --  --stat, -p, --name-only/-status, --numstat) follows Options. Only the
      --  tracked changes are shown; the untracked tree of an
      --  `--include-untracked` stash (the third parent) is not, as in git.
      declare
         Base_Id : constant Version.Objects.Hex_Object_Id :=
           Parents.Element (Parents.First_Index);
      begin
         return
           Version.Diff.Diff_Commits
             (Repo      => Repo,
              Old_Id    => Base_Id,
              New_Id    => Stash_Id,
              Pathspecs => Pathspecs,
              Options   => Options);
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

   --  git's stash commit: commit_tree stores the message exactly as given,
   --  and the stash's own message carries no trailing newline (the index
   --  and untracked commits, which git builds with one, do).
   function Write_Stash_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String) return Version.Objects.Hex_Object_Id
   is
      LF      : constant Character := Character'Val (10);
      Content : Unbounded_String;
   begin
      Append (Content, "tree " & To_String (Tree_Id) & LF);
      for P of Parents loop
         Append (Content, "parent " & To_String (P) & LF);
      end loop;
      Append (Content, "author " & Version.Config.Author_Signature (Repo) & LF);
      Append (Content,
              "committer " & Version.Config.Committer_Signature (Repo) & LF);
      Append (Content, LF);
      Append (Content, Message);
      return Version.Write.Write_Object (Repo, "commit", To_String (Content));
   end Write_Stash_Commit;

   function Create
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Message           : String := "")
      return String
   is
      Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
      Head_Id : Version.Objects.Object_Id_Storage;
      --  git stashes every file under an untracked directory, so the
      --  untracked list must be the expanded one.
      Status : constant Version.Status.Status_Result :=
        (if Pathspecs.Is_Empty
         then Version.Status.Current_Status (All_Untracked => Include_Untracked)
         else Version.Status.Current_Status (Pathspecs, Include_Untracked));
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
            Full_Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Version.Staging.Load (Repo);
            Full_Work_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Index_Entries_With_Working_Tree (Repo);
            --  git's stash under a pathspec: the index parent records the
            --  whole index, and the stash's own tree is that index with the
            --  working-tree content of the matched paths laid over it --
            --  so a staged file outside the pathspec travels along, while
            --  an unstaged change outside it does not.
            Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Full_Index_Entries;
            Work_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
              Overlay_Selected_Entries
                (Full_Index_Entries, Full_Work_Entries, Pathspecs);
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
                  --  git's do_create_stash commits the untracked tree with
                  --  no parent at all.
                  UCommit : constant Version.Objects.Hex_Object_Id :=
                    Write_Stash_Commit
                      (Repo    => Repo,
                       Tree_Id => UTree,
                       Parents => Version.Objects.Object_Id_Vectors.Empty_Vector,
                       Message =>
                         Stash_Message (Repo, Head_Id, "untracked files")
                         & Character'Val (10));
               begin
                  Parents.Append (UCommit);
               end;
            end if;

            return
              To_String
                (Write_Stash_Commit
                   (Repo    => Repo,
                    Tree_Id => Work_Tree,
                    Parents => Parents,
                    Message => Top_Stash_Message (Repo, Head_Id, Message)));
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
         --  git's do_store_stash default.
         Reflog_Message : constant String :=
           (if Message'Length /= 0 then Message
            else "Created via ""git stash store"".");
         pragma Unreferenced (Subject);
      begin
         --  Storing the commit the stash ref already holds changes
         --  nothing, and git records no reflog entry for it.
         if Old_Id = To_String (Commit_Id) then
            return;
         end if;
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


   --  The untracked files a stash carries, written back into the working
   --  tree (git's restore_untracked); an existing path is in the way.
   procedure Apply_Untracked_Parent_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id)
   is
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
   begin
      for Item of Items loop
         if Item.Kind /= Version.Objects.Tree_Directory then
            declare
               Path : constant String := To_String (Item.Path);
               Full : constant String :=
                 Join (Version.Repository.Root_Path (Repo), Path);
               Obj  : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Repo, Item.Id);
            begin
               Version.Path_Safety.Require_Safe_Relative_Path
                 (Path, "stash untracked path");
               Version.Filesystem_Guard.Require_Safe_Write_Target
                 (Repo_Root     => Version.Repository.Root_Path (Repo),
                  Relative_Path => Path);
               if Version.Files.Exists (Full) then
                  raise Ada.IO_Exceptions.Data_Error with
                    "untracked path already exists: " & Path;
               end if;
               Version.Files.Create_Parent_Directories (Full);
               Version.Files.Write_Binary_File_Atomic
                 (Path => Full, Content => Version.Objects.Content (Obj));
            end;
         end if;
      end loop;
   end Apply_Untracked_Parent_Tree;

   --  Write a tree's blobs into the working tree, overwriting what is
   --  there (git's `checkout --no-overlay <tree> -- :/` for --keep-index).
   procedure Restore_Tree_To_Working_Files
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id)
   is
      Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
   begin
      for Item of Items loop
         if Item.Kind /= Version.Objects.Tree_Directory then
            declare
               Path : constant String := To_String (Item.Path);
               Full : constant String :=
                 Join (Version.Repository.Root_Path (Repo), Path);
               Obj  : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Repo, Item.Id);
            begin
               Version.Path_Safety.Require_Safe_Relative_Path
                 (Path, "stash path");
               Version.Filesystem_Guard.Require_Safe_Write_Target
                 (Repo_Root     => Version.Repository.Root_Path (Repo),
                  Relative_Path => Path);
               if Version.Objects.Kind (Obj) = Version.Objects.Blob_Object then
                  Version.Files.Create_Parent_Directories (Full);
                  Version.Files.Write_Binary_File_Atomic
                    (Path => Full, Content => Version.Objects.Content (Obj));
               end if;
            end;
         end if;
      end loop;
   end Restore_Tree_To_Working_Files;

   --  `stash push --staged`: the stash's working tree is the index tree, so
   --  only what was staged travels with it.
   function Create_Staged_Only
     (Repo    : Version.Repository.Repository_Handle;
      Head_Id : Version.Objects.Hex_Object_Id;
      Message : String) return String
   is
      Index_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Index_Tree : constant Version.Objects.Hex_Object_Id :=
        Version.Write.Write_Tree_From_Index (Repo, Index_Entries);
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
      return To_String
        (Write_Stash_Commit
           (Repo    => Repo,
            Tree_Id => Index_Tree,
            Parents => Parents,
            Message => Top_Stash_Message (Repo, Head_Id, Message)));
   end Create_Staged_Only;

   procedure Rewrite_Stash_Reflog
     (Repo    : Version.Repository.Repository_Handle;
      Entries : Stash_Entry_Vectors.Vector);


   ---------------------------------------------------------------------------
   --  git's stash_info and the subcommands built on it
   ---------------------------------------------------------------------------

   function Get_Info
     (Repo : Version.Repository.Repository_Handle;
      Spec : String := "") return Stash_Info
   is
      function All_Digits (Text : String) return Boolean is
        (Text'Length > 0 and then (for all C of Text => C in '0' .. '9'));

      --  git's parse_stash_revision.
      Revision : constant String :=
        (if Spec'Length = 0 then Stash_Ref & "@{0}"
         elsif All_Digits (Spec) then Stash_Ref & "@{" & Spec & "}"
         else Spec);

      Result : Stash_Info;
   begin
      if Spec'Length = 0
        and then not Version.Refs.Ref_Exists (Repo, Stash_Ref)
      then
         raise Stash_Failure with "No stash entries found.";
      end if;

      Result.Revision := To_Unbounded_String (Revision);

      begin
         Result.W_Commit := Version.Revisions.Resolve (Repo, Revision);
      exception
         when E : Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
            --  A reflog that does not go back that far is git's own die
            --  ("log for 'stash' only has N entries"); anything else is
            --  simply not a reference.
            declare
               Text : constant String := Ada.Exceptions.Exception_Message (E);
            begin
               if Text'Length > 8
                 and then Text (Text'First .. Text'First + 7) = "log for "
               then
                  raise Stash_Error with Text;
               end if;
               raise Stash_Failure with Revision & " is not a valid reference";
            end;
      end;

      --  git's assert_stash_like: a stash commit has a base parent whose
      --  tree is the base, and an index parent whose tree is the index; a
      --  third parent carries the untracked files.
      declare
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Result.W_Commit);
         Parents : Version.Objects.Object_Id_Vectors.Vector;
      begin
         if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
            raise Stash_Error with
              "'" & Revision & "' is not a stash-like commit";
         end if;
         Parents := Version.Objects.Commit_Parent_Ids (Obj);
         if Natural (Parents.Length) not in 2 .. 3 then
            raise Stash_Error with
              "'" & Revision & "' is not a stash-like commit";
         end if;
         Result.W_Tree := Version.Objects.Commit_Tree_Id (Obj);
         Result.B_Commit := Parents.Element (Parents.First_Index);
         Result.B_Tree := Tree_Id_For_Commit (Repo, Result.B_Commit);
         Result.I_Tree :=
           Tree_Id_For_Commit (Repo, Parents.Element (Parents.First_Index + 1));
         Result.Has_U := Natural (Parents.Length) = 3;
         if Result.Has_U then
            Result.U_Tree :=
              Tree_Id_For_Commit (Repo, Parents.Element (Parents.First_Index + 2));
         end if;
      exception
         when Stash_Error =>
            raise;
         when others =>
            raise Stash_Error with
              "'" & Revision & "' is not a stash-like commit";
      end;

      --  git checks whether the part before "@" names refs/stash.
      declare
         At_Pos : Natural := 0;
      begin
         for I in Revision'Range loop
            if Revision (I) = '@' then
               At_Pos := I;
               exit;
            end if;
         end loop;
         declare
            Symbolic : constant String :=
              (if At_Pos = 0 then Revision
               else Revision (Revision'First .. At_Pos - 1));
         begin
            Result.Is_Stash_Ref :=
              Symbolic = Stash_Ref
              or else (Symbolic = "stash"
                       and then Version.Refs.Ref_Exists (Repo, Stash_Ref));
         end;
      end;

      return Result;
   end Get_Info;

   --  The tree of the live index, which is git's `c_tree`.
   function Current_Index_Tree
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      for E of Entries loop
         if E.Stage /= 0 then
            raise Stash_Error with
              "cannot apply a stash in the middle of a merge";
         end if;
      end loop;
      return Version.Write.Write_Tree_From_Index (Repo, Entries);
   end Current_Index_Tree;

   function Untracked_Tree
     (Repo : Version.Repository.Repository_Handle;
      Info : Stash_Info) return Version.Objects.Hex_Object_Id
   is
      Trees   : Version.Tree_Cache.Tree_Cache;
      Entries : Version.Staging.Index_Entry_Vectors.Vector :=
        Tree_As_Index_Entries (Repo, Info.W_Tree);
   begin
      if not Info.Has_U then
         return Info.W_Tree;
      end if;
      for E of Version.Tree_Cache.Flatten_Tree (Repo, Trees, Info.U_Tree) loop
         if E.Kind /= Version.Objects.Tree_Directory then
            Version.Staging.Replace_Entry
              (Entries,
               (Path => E.Path, Id => E.Id, Mode => E.Mode, Stage => 0,
                Skip_Worktree => False, Assume_Valid => False,
                Intent_To_Add => False));
         end if;
      end loop;
      Version.Staging.Sort_By_Path (Entries);
      return Version.Write.Write_Tree_From_Index (Repo, Entries);
   end Untracked_Tree;

   --  git's unpack-trees guard: a path the merge would touch must not carry
   --  working-tree changes that are not in the index.
   procedure Require_No_Overwrite
     (Repo        : Version.Repository.Repository_Handle;
      Base_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Other_Items : Version.Objects.Tree_Entry_Vectors.Vector)
   is
      Status : constant Version.Status.Status_Result :=
        Version.Status.Current_Status;
      Blocked : Unbounded_String;

      --  True when the two trees disagree about Path, i.e. the merge has
      --  something to write there.
      function Touched (Path : String) return Boolean is
         function Id_In (Items : Version.Objects.Tree_Entry_Vectors.Vector)
            return String is
         begin
            for E of Items loop
               if To_String (E.Path) = Path then
                  return To_String (E.Id);
               end if;
            end loop;
            return "";
         end Id_In;
      begin
         return Id_In (Base_Items) /= Id_In (Other_Items);
      end Touched;
   begin
      for C of Status.Changes loop
         if Touched (To_String (C.Path)) then
            Append (Blocked, Character'Val (9) & To_String (C.Path)
                    & Character'Val (10));
         end if;
      end loop;

      if Length (Blocked) > 0 then
         raise Stash_Error with
           "Your local changes to the following files would be overwritten by "
           & "merge:" & Character'Val (10) & To_String (Blocked)
           & "Please commit your changes or stash them before you merge."
           & Character'Val (10) & "Aborting";
      end if;
   end Require_No_Overwrite;

   --  git's unstage_changes_unless_new: after a clean apply without
   --  --index, the index goes back to what it held, except that paths the
   --  stash adds anew stay staged.
   procedure Unstage_Unless_New
     (Repo     : Version.Repository.Repository_Handle;
      C_Tree   : Version.Objects.Hex_Object_Id;
      Merged   : Version.Staging.Index_Entry_Vectors.Vector)
   is
      Old_Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Tree_As_Index_Entries (Repo, C_Tree);
      Result      : Version.Staging.Index_Entry_Vectors.Vector := Old_Entries;

      function In_Old (Path : String) return Boolean is
      begin
         for E of Old_Entries loop
            if To_String (E.Path) = Path then
               return True;
            end if;
         end loop;
         return False;
      end In_Old;
   begin
      for E of Merged loop
         if not In_Old (To_String (E.Path)) then
            Version.Staging.Replace_Entry (Result, E);
         end if;
      end loop;
      Version.Staging.Sort_By_Path (Result);
      Version.Staging.Write (Repo, Result);
   end Unstage_Unless_New;

   procedure Apply_Info
     (Repo       : Version.Repository.Repository_Handle;
      Info       : Stash_Info;
      Options    : Apply_Options;
      Conflicted : out Boolean;
      Narration  : out Message_Vectors.Vector)
   is
      Trees   : Version.Tree_Cache.Tree_Cache;
      C_Tree  : constant Version.Objects.Hex_Object_Id :=
        Current_Index_Tree (Repo);
      Has_Index : Boolean := Options.Restore_Index;
      Index_Tree : Version.Objects.Object_Id_Storage := C_Tree;

      function Label (Given : Unbounded_String; Default : String)
         return String is
        (if Length (Given) > 0 then To_String (Given) else Default);

      Base_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree (Repo, Trees, Info.B_Tree);
      Work_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree (Repo, Trees, Info.W_Tree);
   begin
      Conflicted := False;
      Narration.Clear;

      if Options.Restore_Index then
         --  Nothing was staged when the stash was made, or the index is
         --  already that tree: there is no index to recreate.
         if Info.B_Tree = Info.I_Tree or else C_Tree = Info.I_Tree then
            Has_Index := False;
         else
            --  git applies the stash's staged diff to the index; the index
            --  the stash recorded is exactly that result.
            Index_Tree := Info.I_Tree;
         end if;
      end if;

      Require_No_Overwrite (Repo, Base_Items, Work_Items);

      declare
         Current_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Tree_Cache.Flatten_Tree (Repo, Trees, C_Tree);
         Merged_Index : Version.Staging.Index_Entry_Vectors.Vector;
         Conflicts    : Version.Merge.Conflict_Vectors.Vector;
      begin
         Version.Merge.Merge_Trees
           (Repo          => Repo,
            Current_Name  =>
              (if Info.B_Tree = C_Tree and then Length (Options.Label_Ours) = 0
               then "Version stash was based on"
               else Label (Options.Label_Ours, "Updated upstream")),
            Target_Name   => Label (Options.Label_Theirs, "Stashed changes"),
            Base_Items    => Base_Items,
            Current_Items => Current_Items,
            Target_Items  => Work_Items,
            Merged_Index  => Merged_Index,
            Conflicts     => Conflicts,
            Behavior      => Version.Merge.Merge_Behavior'
              (Base_Label => To_Unbounded_String
                 (Label (Options.Label_Base, "Stash base")),
               others     => <>));

         --  git narrates the merge: an "Auto-merging" line for every file
         --  it content-merged, each conflict's line right after its own.
         declare
            function Id_At
              (Items : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
               return String is
            begin
               for E of Items loop
                  if To_String (E.Path) = Path then
                     return To_String (E.Id);
                  end if;
               end loop;
               return "";
            end Id_At;

            Merged_Paths : Message_Vectors.Vector;
            Next         : Positive := 1;

            function Kind_Word (K : Version.Merge.Conflict_Kind) return String is
              (case K is
                  when Version.Merge.Add_Add_Conflict        => "add/add",
                  when Version.Merge.Binary_Conflict         => "binary",
                  when Version.Merge.Directory_File_Conflict => "file/directory",
                  when others                                => "content");
         begin
            for E of Current_Items loop
               declare
                  Path : constant String := To_String (E.Path);
                  O    : constant String := To_String (E.Id);
                  T    : constant String := Id_At (Work_Items, Path);
                  B    : constant String := Id_At (Base_Items, Path);
               begin
                  if T /= "" and then O /= T
                    and then (B = "" or else (O /= B and then T /= B))
                  then
                     Merged_Paths.Append (Path);
                  end if;
               end;
            end loop;

            for C of Conflicts loop
               declare
                  CP : constant String := To_String (C.Path);
               begin
                  while Next <= Natural (Merged_Paths.Length)
                    and then Merged_Paths.Element (Next) < CP
                  loop
                     Narration.Append
                       (String'("Auto-merging " & Merged_Paths.Element (Next)));
                     Next := Next + 1;
                  end loop;
                  if Next <= Natural (Merged_Paths.Length)
                    and then Merged_Paths.Element (Next) = CP
                  then
                     Narration.Append (String'("Auto-merging " & CP));
                     Next := Next + 1;
                  end if;
                  Narration.Append
                    (String'("CONFLICT (" & Kind_Word (C.Kind)
                     & "): Merge conflict in " & CP));
               end;
            end loop;
            while Next <= Natural (Merged_Paths.Length) loop
               Narration.Append
                 (String'("Auto-merging " & Merged_Paths.Element (Next)));
               Next := Next + 1;
            end loop;
         end;

         --  A stash whose tracked side is already in the tree merges to
         --  nothing, which git's merge reports.
         if Conflicts.Is_Empty
           and then Version.Write.Write_Tree_From_Index (Repo, Merged_Index) = C_Tree
         then
            Narration.Append (String'("Already up to date."));
         end if;

         if not Conflicts.Is_Empty then
            Conflicted := True;
            Version.Staging.Write (Repo, Merged_Index);
         elsif Has_Index then
            --  The recreated index; the working tree keeps the merge.
            Version.Staging.Write
              (Repo, Tree_As_Index_Entries (Repo, Index_Tree));
         else
            Unstage_Unless_New (Repo, C_Tree, Merged_Index);
         end if;
      end;

      if Info.Has_U then
         begin
            Apply_Untracked_Parent_Tree (Repo, Info.U_Tree);
         exception
            when others =>
               raise Stash_Error with
                 "could not restore untracked files from stash";
         end;
      end if;
   end Apply_Info;

   procedure Drop_Info
     (Repo : Version.Repository.Repository_Handle;
      Info : Stash_Info)
   is
      Revision : constant String := To_String (Info.Revision);

      --  The entry number in "<ref>@{N}"; anything else drops the top.
      function Entry_Index return Natural is
         Open : Natural := 0;
      begin
         for K in Revision'Range loop
            if Revision (K) = '{' then
               Open := K;
            end if;
         end loop;
         if Open = 0 or else Revision (Revision'Last) /= '}' then
            return 0;
         end if;
         return Natural'Value (Revision (Open + 1 .. Revision'Last - 1));
      exception
         when Constraint_Error =>
            return 0;
      end Entry_Index;

      Entries : Stash_Entry_Vectors.Vector := List_Entries (Repo);
      N       : constant Natural := Entry_Index;
   begin
      if Natural (Entries.Length) <= N then
         raise Stash_Error with
           To_String (Info.Revision) & ": Could not drop stash entry";
      end if;
      Entries.Delete (Entries.First_Index + N);
      Rewrite_Stash_Reflog (Repo, Entries);
   end Drop_Info;

   procedure Push_Entry
     (Repo      : Version.Repository.Repository_Handle;
      Options   : Push_Options;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Saved     : out Boolean;
      Title     : out Unbounded_String)
   is
      Head_Id : Version.Objects.Object_Id_Storage;
      Status  : constant Version.Status.Status_Result :=
        (if Pathspecs.Is_Empty
         then Version.Status.Current_Status
                (All_Untracked => Options.Include_Untracked)
         else Version.Status.Current_Status
                (Pathspecs, Options.Include_Untracked));
   begin
      Saved := False;
      Title := Null_Unbounded_String;
      Require_Head (Repo, Head_Id);

      declare
         Selected_Untracked : constant Version.Staging.Index_Entry_Vectors.Vector :=
           Selected_Untracked_For_Stash
             (Repo              => Repo,
              Status            => Status,
              Include_Untracked => Options.Include_Untracked,
              Include_Ignored   => Options.Include_Ignored,
              Pathspecs         => Pathspecs);
         --  `--staged` stashes the staged changes alone, so the working
         --  tree's own edits do not count as something to save.
         Nothing : constant Boolean :=
           (if Options.Only_Staged
            then Status.Staged.Is_Empty
            else Status_Is_Clean
                   (Status, Options.Include_Untracked, Options.Include_Ignored,
                    Natural (Selected_Untracked.Length)));
      begin
         if Nothing then
            return;
         end if;

         declare
            Stash_Text : constant String :=
              (if Options.Only_Staged
               then Create_Staged_Only (Repo, Head_Id, To_String (Options.Message))
               else Create
                      (Include_Untracked => Options.Include_Untracked,
                       Include_Ignored   => Options.Include_Ignored,
                       Pathspecs         => Pathspecs,
                       Message           => To_String (Options.Message)));
            Stash_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Stash_Text);
            Old_Id   : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);
            Message  : constant String :=
              Top_Stash_Message (Repo, Head_Id, To_String (Options.Message));
         begin
            Update_Stash_Ref (Repo, Stash_Id, Old_Id);
            Version.Reflog.Append
              (Repo, Stash_Ref, Old_Id, To_String (Stash_Id), Message);
            Saved := True;
            Title := To_Unbounded_String (Message);

            if Options.Only_Staged then
               --  git reverses the staged diff in the working tree and then
               --  resets the index, so a staged-only stash takes the staged
               --  content out of both.
               declare
                  Head_Tree : constant Version.Objects.Hex_Object_Id :=
                    Tree_Id_For_Commit (Repo, Head_Id);
                  Head_Items : constant Version.Staging.Index_Entry_Vectors.Vector :=
                    Tree_As_Index_Entries (Repo, Head_Tree);
               begin
                  for Change of Status.Staged loop
                     declare
                        Path : constant String := To_String (Change.Path);
                        Full : constant String :=
                          Join (Version.Repository.Root_Path (Repo), Path);
                     begin
                        if Version.Staging.Find_Entry (Head_Items, Path) = 0 then
                           Version.Files.Delete_File_If_Exists (Full);
                        else
                           Version.Restore.Restore_Path_From_Commit
                             (Repo => Repo, Commit_Id => Head_Id, Path => Path);
                        end if;
                     end;
                  end loop;
                  Version.Staging.Write (Repo, Head_Items);
               end;
            else
               Restore_Selected_Tracked_Paths
                 (Repo      => Repo,
                  Head_Id   => Head_Id,
                  Status    => Status,
                  Pathspecs => Pathspecs);
               if Options.Include_Untracked or else Options.Include_Ignored then
                  Remove_Untracked_Files (Repo, Selected_Untracked);
               end if;

               if Options.Keep_Index then
                  --  git checks the recorded index tree back out over the
                  --  reset working tree, so the staged state survives.
                  declare
                     Info : constant Stash_Info := Get_Info (Repo, Stash_Text);
                  begin
                     Version.Staging.Write
                       (Repo, Tree_As_Index_Entries (Repo, Info.I_Tree));
                     Restore_Tree_To_Working_Files (Repo, Info.I_Tree);
                  end;
               end if;
            end if;
         end;
      end;
   end Push_Entry;

   procedure Push
     (Include_Untracked : Boolean := False;
      Include_Ignored   : Boolean := False;
      Pathspecs         : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Message           : String := "")
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
                 Pathspecs         => Pathspecs,
                 Message           => Message);
            Stash_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Stash_Text);
            Old_Id   : constant String := Current_Ref_Id_Or_Zero (Repo, Stash_Ref);
            Reflog_Message : constant String :=
              Top_Stash_Message (Repo, Head_Id, Message);
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
               Message => Reflog_Message);
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
                     if Version.Files.Exists (Full) then
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
                     if Version.Files.Exists (Full) then
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
            Current_Name  => "Updated upstream",
            Target_Name   => "Stashed changes",
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
            Current_Name  => "Updated upstream",
            Target_Name   => "Stashed changes",
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
      if Version.Files.Exists (Version.Files.To_Native_Path (Ref_Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Ref_Lock_Path;
      end if;

      if Version.Files.Exists (Version.Files.To_Native_Path (Log_Lock_Path)) then
         raise Ada.IO_Exceptions.Data_Error
           with "lock file already exists: " & Log_Lock_Path;
      end if;

      if Version.Files.Exists (Native_Log_Path)
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
               if not Version.Files.Exists (Native_Path) then
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
