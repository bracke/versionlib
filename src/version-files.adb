with Ada.Directories; use Ada.Directories;
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Ada.IO_Exceptions;
with Version.Platform; use Version.Platform;
with Version.Files.Rollback;
with Version.Files.Internal;
with Version.Filesystem_Guard;

package body Version.Files is

   function Normalize_Separators (Path : String) return String is
      Result : String := Path;
   begin
      for I in Result'Range loop
         if Result (I) = '\' then
            Result (I) := '/';
         end if;
      end loop;
      return Result;
   end Normalize_Separators;

   procedure Require_Reasonable_Path_Length (Path : String) is
      Limit : constant Natural :=
        (if Version.Platform.Current = Version.Platform.Windows_Platform
         then 32_767
         else 4_096);
   begin
      if Path'Length > Limit then
         raise Ada.IO_Exceptions.Name_Error
           with "path exceeds supported runtime length: " & Path;
      end if;
   end Require_Reasonable_Path_Length;

   function To_Native_Path (Path : String) return String is
      Result : String := Normalize_Separators (Path);
   begin
      Require_Reasonable_Path_Length (Path);
      if Version.Platform.Native_Path_Separator = '\' then
         for I in Result'Range loop
            if Result (I) = '/' then
               Result (I) := '\';
            end if;
         end loop;
      end if;

      return Result;
   end To_Native_Path;

   function Join (Left : String; Right : String) return String is
      L : constant String := Normalize_Separators (Left);
      R : constant String := Normalize_Separators (Right);
   begin
      if L'Length = 0 then
         return R;
      elsif R'Length = 0 then
         return L;
      elsif L (L'Last) = '/' then
         return L & R;
      else
         return L & "/" & R;
      end if;
   end Join;

   procedure Create_Directory_If_Missing (Path : String) is
      Native : constant String := To_Native_Path (Path);
   begin
      if not Ada.Directories.Exists (Native) then
         Ada.Directories.Create_Path (Native);
      elsif Ada.Directories.Kind (Native) /= Ada.Directories.Directory then
         raise Ada.IO_Exceptions.Data_Error
           with "path exists but is not a directory: " & Path;
      end if;
   end Create_Directory_If_Missing;

   procedure Create_Parent_Directories (Path : String) is
      Normalized : constant String := Normalize_Separators (Path);
      Last_Slash : Natural := 0;
   begin
      for I in reverse Normalized'Range loop
         if Normalized (I) = '/' then
            Last_Slash := I;
            exit;
         end if;
      end loop;

      if Last_Slash /= 0 then
         declare
            Dir : constant String :=
              Normalized (Normalized'First .. Last_Slash - 1);
         begin
            if Dir'Length > 0 then
               if not Ada.Directories.Exists (To_Native_Path (Dir)) then
                  Ada.Directories.Create_Path (To_Native_Path (Dir));
               elsif Ada.Directories.Kind (To_Native_Path (Dir))
                 /= Ada.Directories.Directory
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "path exists but is not a directory: " & Dir;
               end if;
            end if;
         end;
      end if;
   end Create_Parent_Directories;

   procedure Write_Binary_File (Path : String; Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Create_Parent_Directories (Path);

      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, To_Native_Path (Path));

      if Content'Length > 0 then
         declare
            Data :
              Ada.Streams.Stream_Element_Array
                (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
         begin
            for I in Content'Range loop
               Data
                 (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
                 Ada.Streams.Stream_Element (Character'Pos (Content (I)));
            end loop;

            Ada.Streams.Stream_IO.Write (File, Data);
         end;
      end if;

      Ada.Streams.Stream_IO.Close (File);

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Write_Binary_File;

   procedure Write_Binary_File_Atomic (Path : String; Content : String) is
      Temp_Path : constant String := Path & ".version-tmp";
   begin
      Write_Binary_File (Temp_Path, Content);
      Atomic_Replace (Temp_Path, Path);
   exception
      when others =>
         Delete_File_If_Exists (Temp_Path);
         raise;
   end Write_Binary_File_Atomic;

   function Read_Binary_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, To_Native_Path (Path));

      declare
         Size : constant Ada.Streams.Stream_IO.Count :=
           Ada.Streams.Stream_IO.Size (File);
      begin
         if Size = 0 then
            Ada.Streams.Stream_IO.Close (File);
            return "";
         end if;

         declare
            Data :
              Ada.Streams.Stream_Element_Array
                (1 .. Ada.Streams.Stream_Element_Offset (Size));

            Last : Ada.Streams.Stream_Element_Offset;

            Result : String (1 .. Natural (Size));
         begin
            Ada.Streams.Stream_IO.Read (File, Data, Last);
            Ada.Streams.Stream_IO.Close (File);

            if Last /= Data'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "could not read complete file: " & Path;
            end if;

            for I in Result'Range loop
               Result (I) :=
                 Character'Val (Data (Ada.Streams.Stream_Element_Offset (I)));
            end loop;

            return Result;
         end;
      end;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Read_Binary_File;

   procedure Delete_File_If_Exists (Path : String) is
      Native : constant String := To_Native_Path (Path);
   begin
      if Ada.Directories.Exists (Native)
        and then Ada.Directories.Kind (Native) = Ada.Directories.Ordinary_File
      then
         Ada.Directories.Delete_File (Native);
      end if;
   end Delete_File_If_Exists;

   procedure Rename_Directory (Source : String; Target : String) is
      Native_Source : constant String := To_Native_Path (Source);
      Native_Target : constant String := To_Native_Path (Target);
   begin
      if not Ada.Directories.Exists (Native_Source) then
         raise Ada.IO_Exceptions.Name_Error
           with "directory rename source does not exist: " & Source;
      elsif Ada.Directories.Kind (Native_Source) /= Ada.Directories.Directory
      then
         raise Ada.IO_Exceptions.Data_Error
           with "directory rename source is not a directory: " & Source;
      elsif Ada.Directories.Exists (Native_Target) then
         raise Ada.IO_Exceptions.Data_Error
           with "directory rename target already exists: " & Target;
      end if;

      Create_Parent_Directories (Target);
      Ada.Directories.Rename (Native_Source, Native_Target);
   end Rename_Directory;

   procedure Delete_Directory_Tree_If_Exists (Path : String) is
      Native : constant String := To_Native_Path (Path);
   begin
      if not Ada.Directories.Exists (Native) then
         return;
      elsif Ada.Directories.Kind (Native) /= Ada.Directories.Directory then
         raise Ada.IO_Exceptions.Data_Error
           with "directory delete target is not a directory: " & Path;
      end if;

      Ada.Directories.Delete_Tree (Native);
   end Delete_Directory_Tree_If_Exists;

   procedure Remove_File_If_Safe (Repo_Root : String; Relative_Path : String)
   is
   begin
      Version.Filesystem_Guard.Require_Safe_Delete_Target
        (Repo_Root => Repo_Root, Relative_Path => Relative_Path);

      Delete_File_If_Exists (Join (Repo_Root, Relative_Path));
   end Remove_File_If_Safe;

   procedure Atomic_Replace (Source_Temp : String; Target : String) is
      Native_Target : constant String := To_Native_Path (Target);
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform
        and then Ada.Directories.Exists (Native_Target)
      then
         Version.Files.Rollback.Atomic_Replace_With_Backup_Rollback
           (Source_Temp => Source_Temp,
            Target      => Target);
      else
         Version.Files.Internal.Atomic_Replace_Direct
           (Source_Temp => Source_Temp,
            Target      => Target);
      end if;
   end Atomic_Replace;

   function Is_Ordinary_File (Path : String) return Boolean is
   begin
      return
        Ada.Directories.Exists (To_Native_Path (Path))
        and then
          Ada.Directories.Kind (To_Native_Path (Path))
          = Ada.Directories.Ordinary_File;
   end Is_Ordinary_File;

   function Is_Directory (Path : String) return Boolean is
   begin
      return
        Ada.Directories.Exists (To_Native_Path (Path))
        and then
          Ada.Directories.Kind (To_Native_Path (Path))
          = Ada.Directories.Directory;
   end Is_Directory;

   function Current_Directory return String is
   begin
      return Normalize_Separators (Ada.Directories.Current_Directory);
   end Current_Directory;

   procedure Set_Current_Directory (Path : String) is
   begin
      Ada.Directories.Set_Directory (To_Native_Path (Path));
   end Set_Current_Directory;

   procedure With_Directory (Path : String; Action : not null access procedure)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Ada.Directories.Set_Directory (To_Native_Path (Path));

      begin
         Action.all;
      exception
         when others =>
            Ada.Directories.Set_Directory (Old_Dir);
            raise;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   end With_Directory;

end Version.Files;
