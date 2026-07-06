with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;

with Version.Files;
with Version.Object_Cache;
with Version.Tree_Cache;
with Version.Merge_State;
with Version.Pack_Write;
with Version.Pack_Index_Cache;
with Version.Reachability;
with Version.Shallow_Cache;

package body Version.Maintenance is

   use Version.Objects;

   package Object_Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);

   function To_Set
     (Items : Version.Objects.Object_Id_Vectors.Vector)
      return Object_Id_Sets.Set
   is
      Result : Object_Id_Sets.Set;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Result.Include (Items.Element (I));
         end loop;
      end if;

      return Result;
   end To_Set;

   function Join (Left, Right : String) return String renames Version.Files.Join;

   procedure Validate_Object
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Trees   : in out Version.Tree_Cache.Tree_Cache;
      Shallow : in out Version.Shallow_Cache.Shallow_Cache;
      Id      : Version.Objects.Hex_Object_Id)
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Id);
   begin
      case Version.Objects.Kind (Obj) is
         when Version.Objects.Commit_Object =>
            declare
               Tree_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.Commit_Tree_Id (Obj);
               Tree_Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, Tree_Id);
               Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
                 Version.Objects.Commit_Parent_Ids (Obj);
            begin
               if Version.Objects.Kind (Tree_Obj) /= Version.Objects.Tree_Object then
                  raise Ada.IO_Exceptions.Data_Error with
                    "commit tree is not a tree: " & To_String (Tree_Id);
               end if;

               if not Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Id)
                 and then not Parents.Is_Empty
               then
                  for I in Parents.First_Index .. Parents.Last_Index loop
                     declare
                        Parent_Obj : constant Version.Objects.Git_Object :=
                          Version.Object_Cache.Read_Object (Repo, Objects, Parents.Element (I));
                     begin
                        if Version.Objects.Kind (Parent_Obj) /= Version.Objects.Commit_Object then
                           raise Ada.IO_Exceptions.Data_Error with
                             "commit parent is not a commit: " & To_String (Parents.Element (I));
                        end if;
                     end;
                  end loop;
               end if;
            end;

         when Version.Objects.Tree_Object =>
            declare
               Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                 Version.Tree_Cache.Flatten_Tree (Repo, Trees, Id);
            begin
               if not Entries.Is_Empty then
                  for I in Entries.First_Index .. Entries.Last_Index loop
                     case Entries.Element (I).Kind is
                        when Version.Objects.Tree_Gitlink =>
                           null;

                        when Version.Objects.Tree_Blob | Version.Objects.Tree_Directory =>
                           declare
                              Child : constant Version.Objects.Git_Object :=
                                Version.Object_Cache.Read_Object (Repo, Objects, Entries.Element (I).Id);
                           begin
                              case Entries.Element (I).Kind is
                                 when Version.Objects.Tree_Blob =>
                                    if Version.Objects.Kind (Child) /= Version.Objects.Blob_Object
                                      and then Version.Objects.Kind (Child) /= Version.Objects.Commit_Object
                                    then
                                       raise Ada.IO_Exceptions.Data_Error with
                                         "tree entry target has invalid kind: "
                                         & To_String (Entries.Element (I).Id);
                                    end if;
                                 when Version.Objects.Tree_Directory =>
                                    if Version.Objects.Kind (Child) /= Version.Objects.Tree_Object then
                                       raise Ada.IO_Exceptions.Data_Error with
                                         "tree directory target is not a tree: "
                                         & To_String (Entries.Element (I).Id);
                                    end if;
                                 when Version.Objects.Tree_Gitlink =>
                                    null;
                              end case;
                           end;
                     end case;
                  end loop;
               end if;
            end;

         when Version.Objects.Blob_Object | Version.Objects.Unknown_Object =>
            null;

         when Version.Objects.Tag_Object =>
            null;
      end case;
   end Validate_Object;

   function Verify
     (Repo : Version.Repository.Repository_Handle)
      return Maintenance_Result
   is
      Roots     : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Repository_Roots (Repo);
      Reachable : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Reachable_From (Repo, Roots);
      Result    : Maintenance_Result;
      Objects   : Version.Object_Cache.Object_Cache;
      Trees     : Version.Tree_Cache.Tree_Cache;
      Shallow   : Version.Shallow_Cache.Shallow_Cache;
   begin
      if not Reachable.Is_Empty then
         for I in Reachable.First_Index .. Reachable.Last_Index loop
            Validate_Object (Repo, Objects, Trees, Shallow, Reachable.Element (I));
         end loop;
      end if;

      Result.Object_Count := Natural (Reachable.Length);
      return Result;
   end Verify;

   function Repack
     (Repo : Version.Repository.Repository_Handle)
      return Maintenance_Result
   is
      Roots     : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Repository_Roots (Repo);
      Reachable : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Reachable_From (Repo, Roots);
      Pack_Dir  : constant String := Join (Version.Repository.Common_Git_Dir (Repo), "objects/pack");
      Pack_Path : constant String := Join (Pack_Dir, "version-repack.pack");
      Idx_Path  : constant String := Join (Pack_Dir, "version-repack.idx");
      Temp_Pack : constant String := Pack_Path & ".lock";
      Temp_Idx  : constant String := Idx_Path & ".lock";
      Backup_Pack : constant String := Pack_Path & ".backup";
      Backup_Idx  : constant String := Idx_Path & ".backup";
      Result    : Maintenance_Result;

      procedure Cleanup_Temporary_Files is
      begin
         Version.Files.Delete_File_If_Exists (Temp_Pack);
         Version.Files.Delete_File_If_Exists (Temp_Idx);
      end Cleanup_Temporary_Files;

      procedure Cleanup_Backups is
      begin
         Version.Files.Delete_File_If_Exists (Backup_Pack);
         Version.Files.Delete_File_If_Exists (Backup_Idx);
      end Cleanup_Backups;

      procedure Restore_Backups
        (Had_Pack : Boolean;
         Had_Idx  : Boolean)
      is
      begin
         if Had_Pack then
            Version.Files.Atomic_Replace (Backup_Pack, Pack_Path);
         else
            Version.Files.Delete_File_If_Exists (Pack_Path);
         end if;

         if Had_Idx then
            Version.Files.Atomic_Replace (Backup_Idx, Idx_Path);
         else
            Version.Files.Delete_File_If_Exists (Idx_Path);
         end if;
      end Restore_Backups;

      procedure Verify_Temporary_Pack is
         Pack_Indexes : Version.Pack_Index_Cache.Cache;
      begin
         Version.Pack_Index_Cache.Load_Index
           (Item       => Pack_Indexes,
            Index_Path => Temp_Idx,
            Pack_Path  => Temp_Pack,
            Algorithm  => Version.Repository.Algorithm (Repo));

         if not Reachable.Is_Empty then
            for I in Reachable.First_Index .. Reachable.Last_Index loop
               if not Version.Pack_Index_Cache.Contains
                 (Pack_Indexes, Reachable.Element (I))
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "repack verification failed for object: " & To_String (Reachable.Element (I));
               end if;
            end loop;
         end if;
      end Verify_Temporary_Pack;

      procedure Publish_Temporary_Pack is
         Had_Pack : constant Boolean := Version.Files.Is_Ordinary_File (Pack_Path);
         Had_Idx  : constant Boolean := Version.Files.Is_Ordinary_File (Idx_Path);
         Backed_Up_Pack : Boolean := False;
         Backed_Up_Idx  : Boolean := False;
      begin
         Cleanup_Backups;

         begin
            if Had_Pack then
               Version.Files.Atomic_Replace (Pack_Path, Backup_Pack);
               Backed_Up_Pack := True;
            end if;

            if Had_Idx then
               Version.Files.Atomic_Replace (Idx_Path, Backup_Idx);
               Backed_Up_Idx := True;
            end if;
         exception
            when others =>
               if Backed_Up_Pack then
                  Version.Files.Atomic_Replace (Backup_Pack, Pack_Path);
               end if;

               if Backed_Up_Idx then
                  Version.Files.Atomic_Replace (Backup_Idx, Idx_Path);
               end if;

               raise;
         end;

         begin
            Version.Files.Atomic_Replace (Temp_Pack, Pack_Path);
            Version.Files.Atomic_Replace (Temp_Idx, Idx_Path);
         exception
            when others =>
               Cleanup_Temporary_Files;
               Restore_Backups (Had_Pack => Had_Pack, Had_Idx => Had_Idx);
               raise;
         end;

         Cleanup_Backups;
      exception
         when others =>
            Cleanup_Temporary_Files;
            Cleanup_Backups;
            raise;
      end Publish_Temporary_Pack;
   begin
      Result := Verify (Repo);

      Version.Files.Create_Directory_If_Missing (Pack_Dir);
      Cleanup_Temporary_Files;

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Reachable,
         Pack_Path  => Temp_Pack,
         Index_Path => Temp_Idx);
      Verify_Temporary_Pack;
      Publish_Temporary_Pack;

      Result.Object_Count := Natural (Reachable.Length);
      return Result;
   exception
      when others =>
         Cleanup_Temporary_Files;
         raise;
   end Repack;

   function Unreachable_Loose_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Roots     : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Repository_Roots (Repo);
      Reachable : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.Reachable_From (Repo, Roots);
      Loose     : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Reachability.All_Loose_Objects (Repo);
      Reachable_Set : constant Object_Id_Sets.Set := To_Set (Reachable);
      Result        : Version.Objects.Object_Id_Vectors.Vector;
      Shallow       : Version.Shallow_Cache.Shallow_Cache;
   begin
      if not Loose.Is_Empty then
         for I in Loose.First_Index .. Loose.Last_Index loop
            if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Loose.Element (I)) then
               null;
            elsif not Reachable_Set.Contains (Loose.Element (I)) then
               Result.Append (Loose.Element (I));
            end if;
         end loop;
      end if;

      return Result;
   end Unreachable_Loose_Objects;

   function Prune
     (Repo    : Version.Repository.Repository_Handle;
      Dry_Run : Boolean := True;
      Now     : Boolean := False)
      return Maintenance_Result
   is
      Result      : Maintenance_Result;
      Unreachable : Version.Objects.Object_Id_Vectors.Vector;
   begin
      if not Dry_Run then
         if not Now then
            raise Ada.IO_Exceptions.Data_Error with
              "destructive prune requires --now";
         end if;

         if Version.Merge_State.State_Exists (Repo) then
            raise Ada.IO_Exceptions.Data_Error with
              "cannot prune during merge";
         end if;
      end if;

      Result := Verify (Repo);

      Unreachable := Unreachable_Loose_Objects (Repo);
      Result.Unreachable_Count := Natural (Unreachable.Length);

      if not Dry_Run and then not Unreachable.Is_Empty then
         for I in Unreachable.First_Index .. Unreachable.Last_Index loop
            declare
               Path : constant String :=
                 Version.Objects.Loose_Object_Path (Repo, Unreachable.Element (I));
            begin
               if Version.Files.Is_Ordinary_File (Path) then
                  Version.Files.Delete_File_If_Exists (Path);
                  Result.Deleted_Count := Result.Deleted_Count + 1;
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Prune;

   function GC
     (Repo    : Version.Repository.Repository_Handle;
      Dry_Run : Boolean := True)
      return Maintenance_Result
   is
      Result : Maintenance_Result;
      Pruned : Maintenance_Result;
   begin
      Result := Repack (Repo);
      Pruned := Prune (Repo, Dry_Run => Dry_Run, Now => not Dry_Run);
      Result.Unreachable_Count := Pruned.Unreachable_Count;
      Result.Deleted_Count := Pruned.Deleted_Count;
      return Result;
   end GC;

end Version.Maintenance;
