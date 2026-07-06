with Ada.Containers;
with Ada.Directories;
with Ada.IO_Exceptions;

with Version.Files;
with Version.Ref_Names;
with Version.Refs;

package body Version.Ref_Transaction is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;
   use type Ada.Directories.File_Kind;

   --  The "must not exist / just created" sentinel: an all-zero object id of
   --  either hash width (40 zeros for sha1, 64 for sha256).
   function Is_Null_Id (Id : String) return Boolean is
     ((Id'Length = 40 or else Id'Length = 64)
      and then (for all C of Id => C = '0'));

   function Join (Left, Right : String) return String renames Version.Files.Join;

   function Invalid_Expected_Old_Diagnostic return String is
   begin
      return "invalid expected old ref object id";
   end Invalid_Expected_Old_Diagnostic;

   function Expected_Missing_Ref_Diagnostic (Ref_Name : String) return String is
   begin
      return "expected missing ref: " & Ref_Name;
   end Expected_Missing_Ref_Diagnostic;

   function Expected_Old_Mismatch_Diagnostic (Ref_Name : String) return String is
   begin
      return "expected old ref mismatch: " & Ref_Name;
   end Expected_Old_Mismatch_Diagnostic;

   procedure Ensure_Active (Item : Transaction) is
   begin
      if not Item.Active then
         raise Ada.IO_Exceptions.Data_Error with "ref transaction is not active";
      end if;
   end Ensure_Active;

   function Is_Valid_Ref_Name (Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Ref_Name (Name);
   end Is_Valid_Ref_Name;

   procedure Validate_Ref_Name (Name : String) is
   begin
      if not Is_Valid_Ref_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error with "invalid ref name: " & Name;
      end if;
   end Validate_Ref_Name;

   procedure Validate_Expected_Old (Expected_Old : String) is
   begin
      if Expected_Old'Length = 0 then
         return;
      end if;

      if Is_Null_Id (Expected_Old) then
         return;
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Expected_Old) then
         raise Ada.IO_Exceptions.Data_Error with
           Invalid_Expected_Old_Diagnostic;
      end if;
   end Validate_Expected_Old;

   function Loose_Ref_Path
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String)
      return String
   is
   begin
      return Join (Version.Repository.Common_Git_Dir (Repo), Ref);
   end Loose_Ref_Path;

   function Current_Ref_Id_Or_Empty
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String)
      return String
   is
   begin
      if Version.Refs.Ref_Exists (Repo => Repo, Name => Ref) then
         return To_String (Version.Refs.Resolve_Ref (Repo => Repo, Name => Ref));
      end if;

      return "";
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return "";
   end Current_Ref_Id_Or_Empty;

   function Packed_Ref_Exists
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String)
      return Boolean
   is
      Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      return Version.Packed_Refs.Find
        (Repo => Repo,
         Name => Ref,
         Id   => Id);
   end Packed_Ref_Exists;

   procedure Validate_Expected_Values (Item : Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op       : constant Operation := Item.Ops.Element (I);
            Expected : constant String := To_String (Op.Expected_Old);
            Current  : constant String :=
              Current_Ref_Id_Or_Empty
                (Repo => Item.Repo,
                 Ref  => To_String (Op.Ref_Name));
         begin
            if Expected'Length > 0 then
               if Is_Null_Id (Expected) then
                  if Current'Length > 0 then
                     raise Ada.IO_Exceptions.Data_Error with
                       Expected_Missing_Ref_Diagnostic
                         (To_String (Op.Ref_Name));
                  end if;
               elsif Current /= Expected then
                  raise Ada.IO_Exceptions.Data_Error with
                    Expected_Old_Mismatch_Diagnostic
                      (To_String (Op.Ref_Name));
               end if;
            end if;
         end;
      end loop;
   end Validate_Expected_Values;

   function Ref_Already_Staged
     (Item : Transaction;
      Ref  : String)
      return Boolean
   is
   begin
      if Item.Ops.Is_Empty then
         return False;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         if To_String (Item.Ops.Element (I).Ref_Name) = Ref then
            return True;
         end if;
      end loop;

      return False;
   end Ref_Already_Staged;

   procedure Reject_Duplicate_Ref
     (Item : Transaction;
      Ref  : String)
   is
   begin
      if Ref_Already_Staged (Item, Ref) then
         raise Ada.IO_Exceptions.Data_Error with
           "duplicate ref transaction operation: " & Ref;
      end if;
   end Reject_Duplicate_Ref;

   function Less_By_Ref
     (Left  : Operation;
      Right : Operation)
      return Boolean
   is
   begin
      return To_String (Left.Ref_Name) < To_String (Right.Ref_Name);
   end Less_By_Ref;

   procedure Sort_Operations (Ops : in out Operation_Vectors.Vector) is
      J : Natural;
   begin
      if Ops.Length < 2 then
         return;
      end if;

      for I in Ops.First_Index + 1 .. Ops.Last_Index loop
         declare
            Key : constant Operation := Ops.Element (I);
         begin
            J := I;
            while J > Ops.First_Index
              and then Less_By_Ref (Key, Ops.Element (J - 1))
            loop
               Ops.Replace_Element (J, Ops.Element (J - 1));
               J := J - 1;
            end loop;

            Ops.Replace_Element (J, Key);
         end;
      end loop;
   end Sort_Operations;

   procedure Acquire_Locks (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Ref_Path  : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Item.Ops.Element (I).Ref_Name));
            Lock_Path : constant String := Ref_Path & ".lock";
         begin
            if Ada.Directories.Exists (Lock_Path) then
               raise Ada.IO_Exceptions.Data_Error with
                 "lock file already exists: " & Lock_Path;
            end if;
         end;
      end loop;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op        : Operation := Item.Ops.Element (I);
            Ref_Path  : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Op.Ref_Name));
            Lock_Path : constant String := Ref_Path & ".lock";
            Content   : constant String :=
              (if Op.Kind = Update_Ref
               then To_String (Op.New_Id) & Character'Val (10)
               else "delete" & Character'Val (10));
         begin
            Version.Files.Write_Binary_File
              (Path    => Lock_Path,
               Content => Content);

            Op.Lock_Path := To_Unbounded_String (Lock_Path);
            Item.Ops.Replace_Element (I, Op);
         end;
      end loop;
   exception
      when others =>
         Cancel (Item);
         raise;
   end Acquire_Locks;

   procedure Stage_Packed_Ref_Backup (Item : in out Transaction) is
   begin
      if not Item.Packed_Backup_Staged then
         Item.Packed_Backup := Version.Packed_Refs.Read_All (Item.Repo);
         Item.Packed_Backup_Staged := True;
         Item.Packed_Backup_Applied := False;
      end if;
   end Stage_Packed_Ref_Backup;

   procedure Restore_Packed_Ref_Backup (Item : in out Transaction) is
   begin
      if Item.Packed_Backup_Staged and then Item.Packed_Backup_Applied then
         begin
            Version.Packed_Refs.Write_All
              (Repo => Item.Repo,
               Refs => Item.Packed_Backup);
         exception
            when others =>
               null;
         end;
      end if;

      Item.Packed_Backup.Clear;
      Item.Packed_Backup_Staged := False;
      Item.Packed_Backup_Applied := False;
   end Restore_Packed_Ref_Backup;

   procedure Clear_Packed_Ref_Backup (Item : in out Transaction) is
   begin
      Item.Packed_Backup.Clear;
      Item.Packed_Backup_Staged := False;
      Item.Packed_Backup_Applied := False;
   end Clear_Packed_Ref_Backup;

   procedure Apply_Packed_Ref_Deletions (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op  : constant Operation := Item.Ops.Element (I);
            Ref : constant String := To_String (Op.Ref_Name);
         begin
            if Op.Kind = Delete_Ref
              and then Packed_Ref_Exists (Repo => Item.Repo, Ref => Ref)
            then
               Stage_Packed_Ref_Backup (Item);
               Version.Packed_Refs.Remove (Repo => Item.Repo, Name => Ref);
               Item.Packed_Backup_Applied := True;
            end if;
         end;
      end loop;
   exception
      when others =>
         Restore_Packed_Ref_Backup (Item);
         raise;
   end Apply_Packed_Ref_Deletions;

   function Image (Value : Positive) return String is
      Raw : constant String := Positive'Image (Value);
   begin
      if Raw'Length > 0 and then Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      end if;

      return Raw;
   end Image;

   function Rollback_Backup_Path
     (Ref_Path : String;
      Attempt  : Positive)
      return String is
   begin
      return Ref_Path & ".rollback-" & Image (Attempt);
   end Rollback_Backup_Path;

   function Allocate_Rollback_Backup_Path (Ref_Path : String) return String is
      Max_Attempts : constant Positive := 1_000;
   begin
      for Attempt in Positive range 1 .. Max_Attempts loop
         declare
            Candidate : constant String :=
              Rollback_Backup_Path (Ref_Path, Attempt);
         begin
            if not Ada.Directories.Exists (Candidate) then
               return Candidate;
            end if;
         end;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with
        "could not allocate rollback file for: " & Ref_Path;
   end Allocate_Rollback_Backup_Path;

   function Legacy_Rollback_Backup_Path (Ref_Path : String) return String is
   begin
      return Ref_Path & ".rollback";
   end Legacy_Rollback_Backup_Path;

   procedure Restore_Backups (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in reverse Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op          : Operation := Item.Ops.Element (I);
            Ref_Path    : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Op.Ref_Name));
            Backup_Path : constant String :=
              (if To_String (Op.Backup_Path)'Length > 0
               then To_String (Op.Backup_Path)
               else Rollback_Backup_Path (Ref_Path, 1));
            Legacy_Path : constant String := Legacy_Rollback_Backup_Path (Ref_Path);
         begin
            if Op.Applied then
               Version.Files.Delete_File_If_Exists (Ref_Path);
            end if;

            if Op.Had_Backup and then Backup_Path'Length > 0 then
               begin
                  Version.Files.Atomic_Replace (Backup_Path, Ref_Path);
               exception
                  when others =>
                     null;
               end;
            else
               Version.Files.Delete_File_If_Exists (Backup_Path);
            end if;

            Version.Files.Delete_File_If_Exists (Legacy_Path);

            Op.Applied := False;
            Op.Backup_Path := Null_Unbounded_String;
            Op.Had_Backup := False;
            Item.Ops.Replace_Element (I, Op);
         end;
      end loop;
   end Restore_Backups;

   procedure Delete_Backups (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op          : Operation := Item.Ops.Element (I);
            Backup_Path : constant String := To_String (Op.Backup_Path);
         begin
            if Op.Had_Backup and then Backup_Path'Length > 0 then
               Version.Files.Delete_File_If_Exists (Backup_Path);
            end if;

            Op.Backup_Path := Null_Unbounded_String;
            Op.Had_Backup := False;
            Op.Applied := False;
            Item.Ops.Replace_Element (I, Op);
         end;
      end loop;
   end Delete_Backups;

   procedure Prepare_Backups (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Ref_Path    : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Item.Ops.Element (I).Ref_Name));
            Legacy_Path : constant String := Legacy_Rollback_Backup_Path (Ref_Path);
         begin
            Version.Files.Delete_File_If_Exists (Legacy_Path);

            if Ada.Directories.Exists (Ref_Path)
              and then Ada.Directories.Kind (Ref_Path)
                       /= Ada.Directories.Ordinary_File
            then
               raise Ada.IO_Exceptions.Data_Error with
                 "ref target is not an ordinary file: " & Ref_Path;
            end if;
         end;
      end loop;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op          : Operation := Item.Ops.Element (I);
            Ref_Path    : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Op.Ref_Name));
            Backup_Path : constant String := Allocate_Rollback_Backup_Path (Ref_Path);
         begin
            if Ada.Directories.Exists (Ref_Path) then
               Ada.Directories.Rename (Ref_Path, Backup_Path);
               Op.Backup_Path := To_Unbounded_String (Backup_Path);
               Op.Had_Backup := True;
               Item.Ops.Replace_Element (I, Op);
            end if;
         end;
      end loop;
   exception
      when others =>
         Restore_Backups (Item);
         raise;
   end Prepare_Backups;

   procedure Apply_Operations (Item : in out Transaction) is
   begin
      if Item.Ops.Is_Empty then
         return;
      end if;

      for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
         declare
            Op       : constant Operation := Item.Ops.Element (I);
            Ref_Path : constant String :=
              Loose_Ref_Path
                (Repo => Item.Repo,
                 Ref  => To_String (Op.Ref_Name));
            Lock_Path : constant String := To_String (Op.Lock_Path);
         begin
            if Op.Kind = Update_Ref then
               Version.Files.Atomic_Replace (Lock_Path, Ref_Path);
            else
               Version.Files.Delete_File_If_Exists (Ref_Path);
               Version.Files.Delete_File_If_Exists (Lock_Path);
            end if;

            declare
               Updated : Operation := Op;
            begin
               Updated.Applied := True;
               Item.Ops.Replace_Element (I, Updated);
            end;
         end;
      end loop;
   exception
      when others =>
         Restore_Backups (Item);
         Cancel (Item);
         raise;
   end Apply_Operations;

   procedure Start
     (Item : out Transaction;
      Repo : Version.Repository.Repository_Handle)
   is
   begin
      Item.Repo := Repo;
      Item.Active := True;
      Item.Ops.Clear;
      Clear_Packed_Ref_Backup (Item);
   end Start;

   procedure Add_Update
     (Item         : in out Transaction;
      Ref_Name     : String;
      New_Id       : Version.Objects.Hex_Object_Id;
      Expected_Old : String := "")
   is
   begin
      Ensure_Active (Item);
      Validate_Ref_Name (Ref_Name);
      Validate_Expected_Old (Expected_Old);
      Reject_Duplicate_Ref (Item, Ref_Name);

      Item.Ops.Append
        (Operation'(Kind         => Update_Ref,
          Ref_Name     => To_Unbounded_String (Ref_Name),
          New_Id       => New_Id,
          Expected_Old => To_Unbounded_String (Expected_Old),
          Lock_Path    => Null_Unbounded_String,
          Backup_Path  => Null_Unbounded_String,
          Had_Backup   => False,
          Applied      => False));
   end Add_Update;

   procedure Add_Delete
     (Item         : in out Transaction;
      Ref_Name     : String;
      Expected_Old : String := "")
   is
   begin
      Ensure_Active (Item);
      Validate_Ref_Name (Ref_Name);
      Validate_Expected_Old (Expected_Old);
      Reject_Duplicate_Ref (Item, Ref_Name);

      Item.Ops.Append
        (Operation'(Kind         => Delete_Ref,
          Ref_Name     => To_Unbounded_String (Ref_Name),
          New_Id       => Version.Objects.Zero_Object_Id,
          Expected_Old => To_Unbounded_String (Expected_Old),
          Lock_Path    => Null_Unbounded_String,
          Backup_Path  => Null_Unbounded_String,
          Had_Backup   => False,
          Applied      => False));
   end Add_Delete;

   procedure Commit
     (Item : in out Transaction)
   is
   begin
      Ensure_Active (Item);
      Validate_Expected_Values (Item);
      Sort_Operations (Item.Ops);
      Acquire_Locks (Item);
      Prepare_Backups (Item);
      Apply_Packed_Ref_Deletions (Item);
      Apply_Operations (Item);
      Delete_Backups (Item);
      Clear_Packed_Ref_Backup (Item);
      Item.Ops.Clear;
      Item.Active := False;
   exception
      when others =>
         Restore_Backups (Item);
         Restore_Packed_Ref_Backup (Item);
         Cancel (Item);
         raise;
   end Commit;

   procedure Cancel
     (Item : in out Transaction)
   is
   begin
      if not Item.Ops.Is_Empty then
         for I in Item.Ops.First_Index .. Item.Ops.Last_Index loop
            declare
               Lock_Path : constant String := To_String (Item.Ops.Element (I).Lock_Path);
            begin
               if Lock_Path'Length > 0
                 and then Ada.Directories.Exists (Lock_Path)
               then
                  Version.Files.Delete_File_If_Exists (Lock_Path);
               end if;
            end;
         end loop;
      end if;

      Item.Ops.Clear;
      Clear_Packed_Ref_Backup (Item);
      Item.Active := False;
   end Cancel;

end Version.Ref_Transaction;
