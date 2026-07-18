with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Ada.Containers.Indefinite_Ordered_Maps;
with Interfaces.C;
with System;

with GNAT.OS_Lib;

with Version.Config;
with Version.Objects; use Version.Objects;
with Version.Refs;
with Version.Staging;
with Version.Files;
with Version.LFS;
with Version.Text_Filter;
with Version.Filesystem_Guard; use Version.Filesystem_Guard;
with Version.Revisions;
with Version.Path_Safety; use Version.Path_Safety;
with Version.Platform;
with Version.Sparse;

package body Version.Restore is

   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Version.Platform.Platform_Kind;

   --  True when core.symlinks is configured off (or absent on non-POSIX).
   --  Read inside the body so a missing key does not escape the handler.
   function Core_Symlinks_Disabled
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      declare
         Value : constant String :=
           Version.Config.Trim (Version.Config.Get_Value (Repo, "core.symlinks"));
      begin
         if Value = "false" or else Value = "no"
           or else Value = "0" or else Value = "off"
         then
            return True;
         elsif Value'Length = 0 then
            return Version.Platform.Current /= Version.Platform.POSIX_Platform;
         else
            return False;
         end if;
      end;
   exception
      when others =>
         return Version.Platform.Current /= Version.Platform.POSIX_Platform;
   end Core_Symlinks_Disabled;

   package Path_Position_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => Natural);

   function Tree_Path_Map
     (Items : Version.Objects.Tree_Entry_Vectors.Vector)
      return Path_Position_Maps.Map
   is
      Result : Path_Position_Maps.Map;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Result.Include (To_String (Items.Element (I).Path), I);
         end loop;
      end if;

      return Result;
   end Tree_Path_Map;

   function Find_Tree_Item
     (Items : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
      return Natural is
   begin
      if Items.Is_Empty then
         return Natural'Last;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if To_String (Items.Element (I).Path) = Path then
            return I;
         end if;
      end loop;

      return Natural'Last;
   end Find_Tree_Item;

   function Has_Tree_Prefix
     (Items : Version.Objects.Tree_Entry_Vectors.Vector; Prefix : String)
      return Boolean
   is
      Wanted : constant String := Prefix & "/";
   begin
      if Items.Is_Empty then
         return False;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            P : constant String := To_String (Items.Element (I).Path);
         begin
            if P'Length > Wanted'Length
              and then P (P'First .. P'First + Wanted'Length - 1) = Wanted
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Tree_Prefix;

   function Has_Index_Prefix
     (Entries : Version.Staging.Index_Entry_Vectors.Vector; Prefix : String)
      return Boolean
   is
      Wanted : constant String := Prefix & "/";
   begin
      if Entries.Is_Empty then
         return False;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         declare
            P : constant String := To_String (Entries.Element (I).Path);
         begin
            if P'Length > Wanted'Length
              and then P (P'First .. P'First + Wanted'Length - 1) = Wanted
            then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Has_Index_Prefix;

   function Is_Under_Prefix (Path, Prefix : String) return Boolean is
      Wanted : constant String := Prefix & "/";
   begin
      return
        Path'Length > Wanted'Length
        and then Path (Path'First .. Path'First + Wanted'Length - 1) = Wanted;
   end Is_Under_Prefix;

   function Working_Path_Is_Directory
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
      Native_Path   : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      return
        Ada.Directories.Exists (Native_Path)
        and then
          Ada.Directories.Kind (Native_Path) = Ada.Directories.Directory;
   end Working_Path_Is_Directory;

   function Is_Symlink_Mode (Mode : String) return Boolean is
   begin
      return Mode = "120000";
   end Is_Symlink_Mode;

   function Contains_NUL (Value : String) return Boolean is
   begin
      for C of Value loop
         if C = Character'Val (0) then
            return True;
         end if;
      end loop;

      return False;
   end Contains_NUL;

   function Symlink
     (Target : System.Address; Linkpath : System.Address)
      return Interfaces.C.int;
   pragma Import (C, Symlink, "symlink");

   function Unlink (Path : System.Address) return Interfaces.C.int;
   pragma Import (C, Unlink, "unlink");

   procedure Remove_File_Or_Link_For_Symlink_Write
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
      Native_Path   : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Native_Path) then
         declare
            Native_C : aliased String := Native_Path & Character'Val (0);
         begin
            if Unlink (Native_C'Address) /= 0 then
               raise Ada.IO_Exceptions.Use_Error
                 with "could not remove existing symlink: " & Path;
            end if;
         end;
      elsif Ada.Directories.Exists (Native_Path) then
         if Ada.Directories.Kind (Native_Path) = Ada.Directories.Ordinary_File then
            Version.Files.Delete_File_If_Exists (Absolute_Path);
         elsif Ada.Directories.Kind (Native_Path) = Ada.Directories.Directory then
            raise Ada.IO_Exceptions.Data_Error
              with "directory blocks planned symlink: " & Path;
         else
            raise Ada.IO_Exceptions.Data_Error
              with "unsafe symlink target path: " & Path;
         end if;
      end if;
   end Remove_File_Or_Link_For_Symlink_Write;

   procedure Write_Symlink_To_Working_Tree
     (Repo : Version.Repository.Repository_Handle; Path : String; Target : String)
   is
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
      Native_Path   : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         raise Ada.IO_Exceptions.Data_Error
           with "symlink checkout is not supported on this platform: " & Path;
      elsif Target'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "empty symlink target in tree entry: " & Path;
      elsif Contains_NUL (Target) then
         raise Ada.IO_Exceptions.Data_Error
           with "symlink target contains NUL: " & Path;
      end if;

      Version.Files.Create_Parent_Directories (Absolute_Path);
      Remove_File_Or_Link_For_Symlink_Write (Repo, Path);

      declare
         Target_C : aliased String := Target & Character'Val (0);
         Link_C   : aliased String := Native_Path & Character'Val (0);
      begin
         if Symlink (Target_C'Address, Link_C'Address) /= 0 then
            raise Ada.IO_Exceptions.Use_Error
              with "could not create symlink: " & Path;
         end if;
      end;
   end Write_Symlink_To_Working_Tree;

   function Commit_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Commit_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Cache, Commit_Id);
   begin
      if Version.Objects.Kind (Commit_Object) /= Version.Objects.Commit_Object
      then
         raise Ada.IO_Exceptions.Data_Error with "object is not a commit";
      end if;

      return Version.Objects.Commit_Tree_Id (Commit_Object);
   end Commit_Tree;

   procedure Preflight_Working_Delete
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Normalized    : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Absolute_Path : constant String :=
        Version.Files.Join (Version.Repository.Root_Path (Repo), Normalized);
      Native_Path   : constant String :=
        Version.Files.To_Native_Path (Absolute_Path);
   begin
      Version.Path_Safety.Require_Safe_Relative_Path
        (Normalized, "working-tree delete path");

      if Ada.Directories.Exists (Native_Path) then
         if Ada.Directories.Kind (Native_Path) = Ada.Directories.Ordinary_File
         then
            Version.Filesystem_Guard.Require_Safe_Delete_Target
              (Repo_Root     => Version.Repository.Root_Path (Repo),
               Relative_Path => Normalized);
         elsif Ada.Directories.Kind (Native_Path) = Ada.Directories.Directory
           and then
             Ada.Directories.Exists
               (Version.Files.To_Native_Path
                  (Version.Files.Join (Absolute_Path, ".git")))
         then
            --  Existing gitlink/submodule worktrees are directories.  Phase 37
            --  does not make recursive directory deletion generally safe, but it
            --  still preflights the path boundary before the later, explicit
            --  submodule directory removal path is reached.
            Version.Filesystem_Guard.Require_Safe_Write_Target
              (Repo_Root     => Version.Repository.Root_Path (Repo),
               Relative_Path => Normalized,
               Is_Directory  => True);
         elsif Ada.Directories.Kind (Native_Path) = Ada.Directories.Directory
         then
            raise Ada.IO_Exceptions.Data_Error
              with
                "cannot replace non-submodule directory during restore: "
                & Normalized;
         else
            raise Ada.IO_Exceptions.Data_Error
              with "unsafe delete target: " & Normalized;
         end if;
      end if;
   end Preflight_Working_Delete;

   function Parent_Relative_Path (Path : String) return String is
      Idx : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Idx := I;
            exit;
         end if;
      end loop;
      if Idx = 0 then
         return "";
      else
         return Path (Path'First .. Idx - 1);
      end if;
   end Parent_Relative_Path;

   --  After deleting a tracked file, prune any parent directories it leaves
   --  empty, matching git's checkout behaviour (which never leaves stray
   --  empty directories behind).
   procedure Prune_Empty_Parent_Directories
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Root : constant String := Version.Repository.Root_Path (Repo);
      Rel  : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String (Parent_Relative_Path (Path));
   begin
      while Ada.Strings.Unbounded.Length (Rel) > 0 loop
         declare
            Rel_Str : constant String := Ada.Strings.Unbounded.To_String (Rel);
            Abs_Dir : constant String := Version.Files.Join (Root, Rel_Str);
         begin
            exit when not Ada.Directories.Exists (Abs_Dir);
            exit when Ada.Directories.Kind (Abs_Dir) /= Ada.Directories.Directory;
            begin
               Ada.Directories.Delete_Directory (Abs_Dir);
            exception
               when others =>
                  exit;  --  non-empty (or not removable): stop pruning
            end;
            Rel := Ada.Strings.Unbounded.To_Unbounded_String
              (Parent_Relative_Path (Rel_Str));
         end;
      end loop;
   end Prune_Empty_Parent_Directories;

   procedure Delete_Working_Path_If_Present
     (Repo : Version.Repository.Repository_Handle; Path : String) is
   begin
      Version.Path_Safety.Require_Safe_Relative_Path
        (Path, "working-tree path");

      declare
         Absolute_Path : constant String :=
           Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
      begin
         if Ada.Directories.Exists (Absolute_Path) then
            if Ada.Directories.Kind (Absolute_Path)
              = Ada.Directories.Ordinary_File
            then
               Version.Files.Remove_File_If_Safe
                 (Repo_Root     => Version.Repository.Root_Path (Repo),
                  Relative_Path => Path);
               Prune_Empty_Parent_Directories (Repo, Path);
            elsif Ada.Directories.Exists
                    (Version.Files.Join (Absolute_Path, ".git"))
            then
               Version.Files.Delete_Directory_Tree_If_Exists (Absolute_Path);
            else
               raise Ada.IO_Exceptions.Data_Error
                 with
                   "cannot replace non-submodule directory during restore: "
                   & Path;
            end if;
         end if;
      end;
   end Delete_Working_Path_If_Present;

   procedure Write_Tree_Item_To_Working_Tree
     (Repo  : Version.Repository.Repository_Handle;
      Cache : in out Version.Object_Cache.Object_Cache;
      Item  : Version.Objects.Tree_Entry;
      Path  : String) is
   begin
      Version.Path_Safety.Require_Safe_Relative_Path
        (Path, "working-tree path");
      Version.Path_Safety.Require_Safe_Relative_Path
        (To_String (Item.Path), "tree entry path");
      if Item.Kind = Version.Objects.Tree_Gitlink
        or else To_String (Item.Mode) = "160000"
      then
         --  The superproject stores only the gitlink commit.  Submodule
         --  contents are materialized by Version.Submodules.Update.  Treat
         --  the gitlink path as a directory boundary: an existing submodule
         --  worktree directory is allowed, but an ordinary file at the
         --  gitlink path is a file/submodule conflict and must fail before
         --  mutation.
         Version.Filesystem_Guard.Require_Safe_Write_Target
           (Repo_Root     => Version.Repository.Root_Path (Repo),
            Relative_Path => Path,
            Is_Directory  => True);
         return;
      end if;

      Version.Filesystem_Guard.Require_Safe_Write_Target
        (Repo_Root     => Version.Repository.Root_Path (Repo),
         Relative_Path => Path,
         Is_Symlink    => Is_Symlink_Mode (To_String (Item.Mode)));

      declare
         Blob_Object : constant Version.Objects.Git_Object :=
           Version.Object_Cache.Read_Object (Repo, Cache, Item.Id);

         Absolute_Path : constant String :=
           Version.Files.Join (Version.Repository.Root_Path (Repo), Path);
      begin
         if Version.Objects.Kind (Blob_Object) /= Version.Objects.Blob_Object
         then
            raise Ada.IO_Exceptions.Data_Error
              with "tree entry does not reference blob object";
         end if;

         if Is_Symlink_Mode (To_String (Item.Mode)) then
            if Core_Symlinks_Disabled (Repo) then
               --  core.symlinks=false: materialize the link target as a
               --  regular file containing the target path (matches Git).
               Version.Files.Write_Binary_File_Atomic
                 (Path    => Absolute_Path,
                  Content => Version.Objects.Content (Blob_Object));
            else
               Write_Symlink_To_Working_Tree
                 (Repo   => Repo,
                  Path   => Path,
                  Target => Version.Objects.Content (Blob_Object));
            end if;
         else
            Version.Files.Write_Binary_File_Atomic
              (Path    => Absolute_Path,
               Content => Version.LFS.Worktree_Content
                 (Repo          => Repo,
                  Relative_Path => Path,
                  Content       => Version.Text_Filter.Smudge_Content
                    (Repo          => Repo,
                     Relative_Path => Path,
                     Content       => Version.Objects.Content (Blob_Object))));
            if To_String (Item.Mode) = "100755"
              and then Version.Platform.Supports_Executable_Bit
            then
               --  Not GNAT.OS_Lib.Set_Executable: that sets only the owner
               --  bit, giving 744 where git gives 0777 & ~umask.
               Version.Files.Set_Executable (Absolute_Path, True);
            end if;
         end if;
      end;
   end Write_Tree_Item_To_Working_Tree;

   function Included_By_Candidate_Sparse
     (Repo               : Version.Repository.Repository_Handle;
      Path               : String;
      Override_Sparse    : Boolean;
      Candidate_Enabled  : Boolean;
      Candidate_Patterns : Version.Pathspec.Pathspec_Vectors.Vector)
      return Boolean is
   begin
      if Override_Sparse then
         if not Candidate_Enabled then
            return True;
         end if;

         Version.Path_Safety.Require_Safe_Relative_Path (Path, "sparse path");
         return
           Version.Pathspec.Matches_Any
             (Items        => Candidate_Patterns,
              Path         => Path,
              Is_Directory => False);
      else
         return Version.Sparse.Included (Repo, Path);
      end if;
   end Included_By_Candidate_Sparse;

   procedure Build_Working_Tree_Preflight
     (Repo                      : Version.Repository.Repository_Handle;
      Commit_Id                 : Version.Objects.Hex_Object_Id;
      Objects                   : in out Version.Object_Cache.Object_Cache;
      Trees                     : in out Version.Tree_Cache.Tree_Cache;
      Tree_Items                :
        out Version.Objects.Tree_Entry_Vectors.Vector;
      Existing_Index            :
        out Version.Staging.Index_Entry_Vectors.Vector;
      Override_Sparse           : Boolean := False;
      Candidate_Sparse_Enabled  : Boolean := False;
      Candidate_Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
   is
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Commit_Tree (Repo, Objects, Commit_Id);

      Paths          : Version.Path_Safety.Path_Vector;
      Planned        : Version.Filesystem_Guard.Planned_Path_Vectors.Vector;
      Tree_Positions : Path_Position_Maps.Map;
   begin
      Tree_Items :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);

      Tree_Positions := Tree_Path_Map (Tree_Items);

      Existing_Index := Version.Staging.Load (Repo);

      if not Tree_Items.Is_Empty then
         for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
            declare
               Item          : constant Version.Objects.Tree_Entry :=
                 Tree_Items.Element (I);
               Relative_Path : constant String := To_String (Item.Path);
            begin
               Paths.Append (Relative_Path);

               if Included_By_Candidate_Sparse
                    (Repo,
                     Relative_Path,
                     Override_Sparse,
                     Candidate_Sparse_Enabled,
                     Candidate_Sparse_Patterns)
               then
                  if Item.Kind = Version.Objects.Tree_Gitlink
                    or else To_String (Item.Mode) = "160000"
                  then
                     --  A gitlink materializes as a submodule worktree
                     --  directory.  Include it in the checkout preflight so
                     --  ordinary files cannot collide with submodule paths on
                     --  case-insensitive filesystems or through file/directory
                     --  replacement conflicts.  The contents are still
                     --  populated later by Version.Submodules.Update.
                     Planned.Append
                       (Planned_Path'
                          (Path         => To_Unbounded_String (Relative_Path),
                           Is_Directory => True,
                           Is_Symlink   => False));
                  else
                     Planned.Append
                       (Planned_Path'
                          (Path         => To_Unbounded_String (Relative_Path),
                           Is_Directory => False,
                           Is_Symlink   => Is_Symlink_Mode (To_String (Item.Mode))));
                  end if;
               end if;
            end;
         end loop;
      end if;

      Version.Path_Safety.Check_Case_Collisions
        (Paths            => Paths,
         Case_Insensitive => Version.Platform.Is_Case_Insensitive_Default);

      Version.Filesystem_Guard.Preflight_Checkout
        (Repo_Root => Version.Repository.Root_Path (Repo), Paths => Planned);

      if not Existing_Index.Is_Empty then
         for I in Existing_Index.First_Index .. Existing_Index.Last_Index loop
            declare
               Index_Item    : constant Version.Staging.Index_Entry :=
                 Existing_Index.Element (I);
               Relative_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Index_Item.Path));
            begin
               if (not Tree_Positions.Contains (Relative_Path))
                 or else
                   (not Included_By_Candidate_Sparse
                          (Repo,
                           Relative_Path,
                           Override_Sparse,
                           Candidate_Sparse_Enabled,
                           Candidate_Sparse_Patterns))
               then
                  Preflight_Working_Delete (Repo, Relative_Path);
               end if;
            end;
         end loop;
      end if;
   end Build_Working_Tree_Preflight;

   procedure Preflight_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Objects        : Version.Object_Cache.Object_Cache;
      Trees          : Version.Tree_Cache.Tree_Cache;
      Tree_Items     : Version.Objects.Tree_Entry_Vectors.Vector;
      Existing_Index : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Build_Working_Tree_Preflight
        (Repo           => Repo,
         Commit_Id      => Commit_Id,
         Objects        => Objects,
         Trees          => Trees,
         Tree_Items     => Tree_Items,
         Existing_Index => Existing_Index);
   end Preflight_Working_Tree_For_Commit;

   procedure Preflight_Working_Tree_For_Commit
     (Repo            : Version.Repository.Repository_Handle;
      Commit_Id       : Version.Objects.Hex_Object_Id;
      Sparse_Enabled  : Boolean;
      Sparse_Patterns : Version.Pathspec.Pathspec_Vectors.Vector)
   is
      Objects        : Version.Object_Cache.Object_Cache;
      Trees          : Version.Tree_Cache.Tree_Cache;
      Tree_Items     : Version.Objects.Tree_Entry_Vectors.Vector;
      Existing_Index : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      Build_Working_Tree_Preflight
        (Repo                      => Repo,
         Commit_Id                 => Commit_Id,
         Objects                   => Objects,
         Trees                     => Trees,
         Tree_Items                => Tree_Items,
         Existing_Index            => Existing_Index,
         Override_Sparse           => True,
         Candidate_Sparse_Enabled  => Sparse_Enabled,
         Candidate_Sparse_Patterns => Sparse_Patterns);
   end Preflight_Working_Tree_For_Commit;

   procedure Restore_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Items     : Version.Objects.Tree_Entry_Vectors.Vector;
      Existing_Index : Version.Staging.Index_Entry_Vectors.Vector;
      Tree_Positions : Path_Position_Maps.Map;
   begin
      Build_Working_Tree_Preflight
        (Repo           => Repo,
         Commit_Id      => Commit_Id,
         Objects        => Objects,
         Trees          => Trees,
         Tree_Items     => Tree_Items,
         Existing_Index => Existing_Index);

      Tree_Positions := Tree_Path_Map (Tree_Items);

      if not Existing_Index.Is_Empty then
         for I in Existing_Index.First_Index .. Existing_Index.Last_Index loop
            declare
               Index_Item    : constant Version.Staging.Index_Entry :=
                 Existing_Index.Element (I);
               Relative_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Index_Item.Path));
            begin
               if (not Tree_Positions.Contains (Relative_Path))
                 or else (not Version.Sparse.Included (Repo, Relative_Path))
               then
                  Delete_Working_Path_If_Present (Repo, Relative_Path);
               end if;
            end;
         end loop;
      end if;

      if not Tree_Items.Is_Empty then
         for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
            declare
               Tree_Item     : constant Version.Objects.Tree_Entry :=
                 Tree_Items.Element (I);
               Relative_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Tree_Item.Path));
            begin
               if Version.Sparse.Included (Repo, Relative_Path) then
                  Write_Tree_Item_To_Working_Tree
                    (Repo, Objects, Tree_Item, Relative_Path);
               end if;
            end;
         end loop;
      end if;
   end Restore_Working_Tree_For_Commit;

   procedure Restore_Working_Tree_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      Restore_Working_Tree_For_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Objects   => Objects,
         Trees     => Trees);
   end Restore_Working_Tree_For_Commit;

   procedure Restore_Working_Tree (Repo : Version.Repository.Repository_Handle)
   is
      Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Commit_Id'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot restore unborn branch";
      end if;

      Restore_Working_Tree_For_Commit
        (Repo => Repo, Commit_Id => Version.Objects.To_Object_Id (Commit_Id));
   end Restore_Working_Tree;

   procedure Write_Index_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Id     : constant Version.Objects.Hex_Object_Id :=
        Commit_Tree (Repo, Objects, Commit_Id);
      Tree_Items  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      Index_Items : Version.Staging.Index_Entry_Vectors.Vector;
   begin
      if not Tree_Items.Is_Empty then
         for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
            declare
               Tree_Item : constant Version.Objects.Tree_Entry :=
                 Tree_Items.Element (I);
               Safe_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Tree_Item.Path));
            begin
               Index_Items.Append
                 (Version.Staging.Index_Entry'
                    (Path => To_Unbounded_String (Safe_Path),
                     Id   => Tree_Item.Id,
                     Mode => Tree_Item.Mode,
                     Stage => 0, Skip_Worktree => False));
            end;
         end loop;
      end if;

      Version.Staging.Write (Repo => Repo, Entries => Index_Items);
   end Write_Index_For_Commit;

   procedure Write_Index_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id)
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      Write_Index_For_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Objects   => Objects,
         Trees     => Trees);
   end Write_Index_For_Commit;

   procedure Require_Sparse_Materialization_Allowed
     (Repo : Version.Repository.Repository_Handle; Path : String) is
   begin
      if Version.Sparse.Enabled (Repo)
        and then not Version.Sparse.Included (Repo, Path)
      then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot restore sparse-excluded path: " & Path;
      end if;
   end Require_Sparse_Materialization_Allowed;

   procedure Restore_Tree_Prefix_To_Working_Tree
     (Repo       : Version.Repository.Repository_Handle;
      Objects    : in out Version.Object_Cache.Object_Cache;
      Tree_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Prefix     : String)
   is
      Restored       : Natural := 0;
      Tree_Positions : constant Path_Position_Maps.Map :=
        Tree_Path_Map (Tree_Items);
      Existing_Index : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      if Tree_Items.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error
           with "no tracked paths under directory: " & Prefix;
      end if;

      if not Existing_Index.Is_Empty then
         for I in Existing_Index.First_Index .. Existing_Index.Last_Index loop
            declare
               Entry_Path : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Existing_Index.Element (I).Path));
            begin
               if Is_Under_Prefix (Entry_Path, Prefix)
                 and then not Tree_Positions.Contains (Entry_Path)
               then
                  if To_String (Existing_Index.Element (I).Mode) = "160000"
                  then
                     --  A working-tree directory restore must not recurse into
                     --  or remove a submodule worktree merely because the
                     --  selected source lacks the gitlink.  Staged restore
                     --  remains responsible for removing source-missing index
                     --  entries.
                     null;
                  else
                     Delete_Working_Path_If_Present (Repo, Entry_Path);
                  end if;
               end if;
            end;
         end loop;
      end if;

      for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
         declare
            Item_Path : constant String :=
              To_String (Tree_Items.Element (I).Path);
         begin
            if Is_Under_Prefix (Item_Path, Prefix) then
               Require_Sparse_Materialization_Allowed (Repo, Item_Path);
               Write_Tree_Item_To_Working_Tree
                 (Repo, Objects, Tree_Items.Element (I), Item_Path);
               Restored := Restored + 1;
            end if;
         end;
      end loop;

      if Restored = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "no tracked paths under directory: " & Prefix;
      end if;
   end Restore_Tree_Prefix_To_Working_Tree;

   procedure Restore_Index_Prefix_To_Working_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Entries : Version.Staging.Index_Entry_Vectors.Vector;
      Prefix  : String)
   is
      Restored : Natural := 0;
   begin
      if Entries.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error
           with "no tracked paths under directory: " & Prefix;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         declare
            Current_Entry : constant Version.Staging.Index_Entry :=
              Entries.Element (I);
            Entry_Path    : constant String := To_String (Current_Entry.Path);
         begin
            if Is_Under_Prefix (Entry_Path, Prefix) then
               Require_Sparse_Materialization_Allowed (Repo, Entry_Path);
               Write_Tree_Item_To_Working_Tree
                 (Repo,
                  Objects,
                  Version.Objects.Tree_Entry'
                    (Path => Current_Entry.Path,
                     Id   => Current_Entry.Id,
                     Kind =>
                       (if To_String (Current_Entry.Mode) = "160000"
                        then Version.Objects.Tree_Gitlink
                        else Version.Objects.Tree_Blob),
                     Mode => Current_Entry.Mode),
                  Entry_Path);
               Restored := Restored + 1;
            end if;
         end;
      end loop;

      if Restored = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "no tracked paths under directory: " & Prefix;
      end if;
   end Restore_Index_Prefix_To_Working_Tree;

   procedure Restore_Index_Prefix_From_Tree_Items
     (Repo       : Version.Repository.Repository_Handle;
      Tree_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Prefix     : String)
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Kept    : Version.Staging.Index_Entry_Vectors.Vector;
      Matched : Natural := 0;
   begin
      if not Entries.Is_Empty then
         for I in Entries.First_Index .. Entries.Last_Index loop
            declare
               Entry_Path : constant String :=
                 To_String (Entries.Element (I).Path);
            begin
               if not Is_Under_Prefix (Entry_Path, Prefix) then
                  Kept.Append (Entries.Element (I));
               end if;
            end;
         end loop;
      end if;

      if not Tree_Items.Is_Empty then
         for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
            declare
               Item      : constant Version.Objects.Tree_Entry :=
                 Tree_Items.Element (I);
               Item_Path : constant String := To_String (Item.Path);
            begin
               if Is_Under_Prefix (Item_Path, Prefix) then
                  Kept.Append
                    (Version.Staging.Index_Entry'
                       (Path => To_Unbounded_String (Item_Path),
                        Id   => Item.Id,
                        Mode => Item.Mode,
                        Stage => 0, Skip_Worktree => False));
                  Matched := Matched + 1;
               end if;
            end;
         end loop;
      end if;

      if Matched = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "no tracked paths under directory: " & Prefix;
      end if;

      Version.Staging.Sort_By_Path (Kept);
      Version.Staging.Write (Repo => Repo, Entries => Kept);
   end Restore_Index_Prefix_From_Tree_Items;

   procedure Restore_Path_From_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Path    : String)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Objects    : Version.Object_Cache.Object_Cache;
      Trees      : Version.Tree_Cache.Tree_Cache;
      Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      Pos        : constant Natural := Find_Tree_Item (Tree_Items, Normalized);
   begin
      Require_Sparse_Materialization_Allowed (Repo, Normalized);

      if Pos = Natural'Last then
         if Has_Tree_Prefix (Tree_Items, Normalized) then
            Restore_Tree_Prefix_To_Working_Tree
              (Repo, Objects, Tree_Items, Normalized);
         elsif Working_Path_Is_Directory (Repo, Normalized) then
            raise Ada.IO_Exceptions.Data_Error
              with "no tracked paths under directory: " & Normalized;
         else
            Delete_Working_Path_If_Present (Repo, Normalized);
         end if;
      else
         Write_Tree_Item_To_Working_Tree
           (Repo, Objects, Tree_Items.Element (Pos), Normalized);
      end if;
   end Restore_Path_From_Tree;

   procedure Restore_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Id    : constant Version.Objects.Hex_Object_Id :=
        Commit_Tree (Repo, Objects, Commit_Id);
      Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Pos        : constant Natural := Find_Tree_Item (Tree_Items, Normalized);
   begin
      Require_Sparse_Materialization_Allowed (Repo, Normalized);

      if Pos = Natural'Last then
         if Has_Tree_Prefix (Tree_Items, Normalized) then
            Restore_Tree_Prefix_To_Working_Tree
              (Repo, Objects, Tree_Items, Normalized);
         elsif Working_Path_Is_Directory (Repo, Normalized) then
            raise Ada.IO_Exceptions.Data_Error
              with "no tracked paths under directory: " & Normalized;
         else
            Delete_Working_Path_If_Present (Repo, Normalized);
         end if;
      else
         Write_Tree_Item_To_Working_Tree
           (Repo, Objects, Tree_Items.Element (Pos), Normalized);
      end if;
   end Restore_Path_From_Commit;

   procedure Restore_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String)
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      Restore_Path_From_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Path      => Path,
         Objects   => Objects,
         Trees     => Trees);
   end Restore_Path_From_Commit;

   procedure Restore_Path_From_Index
     (Repo : Version.Repository.Repository_Handle; Path : String)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Objects    : Version.Object_Cache.Object_Cache;
      Entries    : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Pos        : constant Natural :=
        Version.Staging.Find_Entry (Entries, Normalized);
   begin
      Require_Sparse_Materialization_Allowed (Repo, Normalized);

      if Pos = Natural'Last then
         if Has_Index_Prefix (Entries, Normalized) then
            Restore_Index_Prefix_To_Working_Tree
              (Repo, Objects, Entries, Normalized);
         elsif Working_Path_Is_Directory (Repo, Normalized) then
            raise Ada.IO_Exceptions.Data_Error
              with "no tracked paths under directory: " & Normalized;
         else
            Delete_Working_Path_If_Present (Repo, Normalized);
         end if;
      else
         declare
            Current_Entry : constant Version.Staging.Index_Entry :=
              Entries.Element (Pos);
            Item          : constant Version.Objects.Tree_Entry :=
              (Path => Current_Entry.Path,
               Id   => Current_Entry.Id,
               Kind =>
                 (if To_String (Current_Entry.Mode) = "160000"
                  then Version.Objects.Tree_Gitlink
                  else Version.Objects.Tree_Blob),
               Mode => Current_Entry.Mode);
         begin
            Write_Tree_Item_To_Working_Tree (Repo, Objects, Item, Normalized);
         end;
      end if;
   end Restore_Path_From_Index;

   procedure Restore_Index_Path_From_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Path    : String)
   is
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Trees      : Version.Tree_Cache.Tree_Cache;
      Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      Pos        : constant Natural := Find_Tree_Item (Tree_Items, Normalized);
      Entries    : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      if Pos = Natural'Last then
         if Has_Tree_Prefix (Tree_Items, Normalized) then
            Restore_Index_Prefix_From_Tree_Items
              (Repo, Tree_Items, Normalized);
            return;
         end if;

         Version.Staging.Remove_Path (Entries, Normalized);
      else
         declare
            Tree_Item : constant Version.Objects.Tree_Entry :=
              Tree_Items.Element (Pos);
         begin
            Version.Staging.Replace_Entry
              (Entries,
               Version.Staging.Index_Entry'
                 (Path => To_Unbounded_String (Normalized),
                  Id   => Tree_Item.Id,
                  Mode => Tree_Item.Mode,
                  Stage => 0, Skip_Worktree => False));
         end;
      end if;

      Version.Staging.Write (Repo => Repo, Entries => Entries);
   end Restore_Index_Path_From_Tree;

   procedure Restore_Index_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Trees     : in out Version.Tree_Cache.Tree_Cache)
   is
      Tree_Id    : constant Version.Objects.Hex_Object_Id :=
        Commit_Tree (Repo, Objects, Commit_Id);
      Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Tree_Cache.Flatten_Tree
          (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
      Normalized : constant String :=
        Version.Path_Safety.Normalize_Relative_Path (Path);
      Pos        : constant Natural := Find_Tree_Item (Tree_Items, Normalized);
      Entries    : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
   begin
      if Pos = Natural'Last then
         if Has_Tree_Prefix (Tree_Items, Normalized) then
            Restore_Index_Prefix_From_Tree_Items
              (Repo, Tree_Items, Normalized);
            return;
         end if;

         Version.Staging.Remove_Path (Entries, Normalized);
      else
         declare
            Tree_Item : constant Version.Objects.Tree_Entry :=
              Tree_Items.Element (Pos);
         begin
            Version.Staging.Replace_Entry
              (Entries,
               Version.Staging.Index_Entry'
                 (Path => To_Unbounded_String (Normalized),
                  Id   => Tree_Item.Id,
                  Mode => Tree_Item.Mode,
                  Stage => 0, Skip_Worktree => False));
         end;
      end if;

      Version.Staging.Write (Repo => Repo, Entries => Entries);
   end Restore_Index_Path_From_Commit;

   procedure Restore_Index_Path_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String)
   is
      Objects : Version.Object_Cache.Object_Cache;
      Trees   : Version.Tree_Cache.Tree_Cache;
   begin
      Restore_Index_Path_From_Commit
        (Repo      => Repo,
         Commit_Id => Commit_Id,
         Path      => Path,
         Objects   => Objects,
         Trees     => Trees);
   end Restore_Index_Path_From_Commit;

   function Current_Head
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Hex_Object_Id
   is
      Commit_Id : constant String := Version.Refs.Current_Commit_Id (Repo);
   begin
      if Commit_Id'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "cannot restore path from unborn branch";
      end if;

      return Version.Objects.To_Object_Id (Commit_Id);
   end Current_Head;

   procedure Restore_Path (Path : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Restore_Path_From_Commit (Repo, Current_Head (Repo), Path);
   end Restore_Path;

   procedure Restore_Staged_Path (Path : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Restore_Index_Path_From_Commit (Repo, Current_Head (Repo), Path);
   end Restore_Staged_Path;

   procedure Restore_Staged_Path_From_Source (Source : String; Path : String)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Restore_Index_Path_From_Commit
        (Repo, Version.Revisions.Resolve_Commit (Repo, Source), Path);
   end Restore_Staged_Path_From_Source;

   procedure Restore_Path_From_Source (Source : String; Path : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Restore_Path_From_Commit
        (Repo, Version.Revisions.Resolve_Commit (Repo, Source), Path);
   end Restore_Path_From_Source;

   procedure Restore_Current_Commit is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      Restore_Working_Tree (Repo);
   end Restore_Current_Commit;

   procedure Apply_Sparse_Skip_Worktree
     (Repo : Version.Repository.Repository_Handle)
   is
      Items   : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Enabled : constant Boolean := Version.Sparse.Enabled (Repo);
      Changed : Boolean := False;
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            E    : Version.Staging.Index_Entry := Items.Element (I);
            Want : constant Boolean :=
              Enabled
              and then E.Stage = 0
              and then not Version.Sparse.Included
                             (Repo, To_String (E.Path));
         begin
            if E.Skip_Worktree /= Want then
               E.Skip_Worktree := Want;
               Items.Replace_Element (I, E);
               Changed := True;
            end if;
         end;
      end loop;

      if Changed then
         Version.Staging.Write (Repo, Items);
      end if;
   end Apply_Sparse_Skip_Worktree;

   procedure Clear_Skip_Worktree
     (Repo : Version.Repository.Repository_Handle)
   is
      Items   : Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Changed : Boolean := False;
   begin
      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I).Skip_Worktree then
            declare
               E : Version.Staging.Index_Entry := Items.Element (I);
            begin
               E.Skip_Worktree := False;
               Items.Replace_Element (I, E);
               Changed := True;
            end;
         end if;
      end loop;

      if Changed then
         Version.Staging.Write (Repo, Items);
      end if;
   end Clear_Skip_Worktree;

end Version.Restore;
