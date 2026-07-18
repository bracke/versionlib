with Ada.Directories; use Ada.Directories;
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Ada.IO_Exceptions;
with Ada.Unchecked_Deallocation;
with Interfaces; use type Interfaces.Unsigned_32;
with Interfaces.C;
with Version.Platform; use Version.Platform;
with Version.Files.Rollback;
with Version.Files.Internal;
with Version.Filesystem_Guard;

package body Version.Files is

   function Relative_To_Prefix
     (Path   : String;
      Prefix : String)
      return String
   is
      function Segment_Count (Text : String) return Natural is
         N : Natural := 0;
      begin
         for C of Text loop
            if C = '/' then
               N := N + 1;
            end if;
         end loop;

         return N;
      end Segment_Count;

      Shared : Natural := 0;   --  characters of Prefix that Path also has
      Cursor : Natural := Path'First;
   begin
      if Prefix = "" or else Path = "" then
         return Path;
      end if;

      --  Walk whole segments of the prefix that the path also starts with.
      while Shared < Prefix'Length loop
         declare
            Stop : Natural := Prefix'First + Shared;
         begin
            while Stop <= Prefix'Last and then Prefix (Stop) /= '/' loop
               Stop := Stop + 1;
            end loop;

            declare
               Segment : constant String :=
                 Prefix (Prefix'First + Shared .. Stop);
            begin
               exit when Cursor + Segment'Length - 1 > Path'Last
                 or else Path (Cursor .. Cursor + Segment'Length - 1)
                         /= Segment;

               Cursor := Cursor + Segment'Length;
               Shared := Shared + Segment'Length;
            end;
         end;
      end loop;

      declare
         --  One "../" for each prefix segment the path did not share.
         Ups   : constant Natural :=
           Segment_Count (Prefix (Prefix'First + Shared .. Prefix'Last));
         Climb : String (1 .. Ups * 3);
      begin
         for I in 1 .. Ups loop
            Climb (I * 3 - 2 .. I * 3) := "../";
         end loop;

         return Climb & Path (Cursor .. Path'Last);
      end;
   end Relative_To_Prefix;

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

   --  Win32 caps a conventional path at MAX_PATH (260, including the NUL), so a
   --  fully-qualified path of 260 characters or more must be given the
   --  "\\?\" extended-length prefix (or "\\?\UNC\" for a UNC path) to be usable
   --  — the same workaround git-for-Windows applies. Only long, already
   --  absolute, backslash-separated paths are rewritten; relative and short
   --  paths keep their conventional form.
   function Extended_Length_Windows_Path (Native : String) return String is
      Prefix : constant String :=
        '\' & '\' & '?' & '\';                 --  \\?\
   begin
      if Native'Length < 260 then
         return Native;
      elsif Native'Length >= Prefix'Length
        and then Native (Native'First .. Native'First + Prefix'Length - 1)
                 = Prefix
      then
         return Native;                          --  already extended-length
      elsif Version.Platform.Is_Windows_Drive_Path (Native) then
         return Prefix & Native;                 --  \\?\C:\...
      elsif Native'Length >= 2
        and then Native (Native'First) = '\'
        and then Native (Native'First + 1) = '\'
      then
         --  UNC "\\server\share\..." -> "\\?\UNC\server\share\..."
         return Prefix & "UNC\"
           & Native (Native'First + 2 .. Native'Last);
      else
         return Native;                          --  relative / not qualified
      end if;
   end Extended_Length_Windows_Path;

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

         return Extended_Length_Windows_Path (Result);
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

         --  Read into a heap buffer rather than a file-sized array on the task
         --  stack (which overflows for large files); the result String is
         --  produced by the extended return, so no large stack local remains.
         declare
            type Buffer_Access is access Ada.Streams.Stream_Element_Array;
            procedure Free is new Ada.Unchecked_Deallocation
              (Ada.Streams.Stream_Element_Array, Buffer_Access);

            Data : Buffer_Access :=
              new Ada.Streams.Stream_Element_Array
                    (1 .. Ada.Streams.Stream_Element_Offset (Size));
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            Ada.Streams.Stream_IO.Read (File, Data.all, Last);
            Ada.Streams.Stream_IO.Close (File);

            if Last /= Data.all'Last then
               Free (Data);
               raise Ada.IO_Exceptions.Data_Error
                 with "could not read complete file: " & Path;
            end if;

            return Result : String (1 .. Natural (Size)) do
               for I in Result'Range loop
                  Result (I) :=
                    Character'Val (Data (Ada.Streams.Stream_Element_Offset (I)));
               end loop;
               Free (Data);
            end return;
         exception
            when others =>
               Free (Data);   --  no-op if already freed (Data is null)
               raise;
         end;
      end;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Read_Binary_File;

   procedure Set_Executable (Path : String; Executable : Boolean) is
      function C_Chmod
        (Name : Interfaces.C.char_array; Mode : Interfaces.C.int)
         return Interfaces.C.int
        with Import, Convention => C, External_Name => "chmod";
      function C_Umask (Mask : Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "umask";

      --  git creates a checked-out file with 0777 (executable) or 0666
      --  (not) and lets the process umask reduce it, so an executable comes
      --  out 755 under umask 022 and 775 under 002. A fixed 0755/0644 would
      --  ignore the umask, and only setting the owner bit -- which
      --  GNAT.OS_Lib.Set_Executable does -- yields 744.
      Saved  : constant Interfaces.C.int := C_Umask (0);
      Ignored : constant Interfaces.C.int := C_Umask (Saved);
      Base   : constant Interfaces.Unsigned_32 :=
        (if Executable then 8#777# else 8#666#);
      Umask  : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Saved) and 8#777#;
      Mode   : constant Interfaces.C.int :=
        Interfaces.C.int (Base and not Umask);
      Result : Interfaces.C.int;
   begin
      pragma Unreferenced (Ignored);
      if Version.Platform.Supports_Executable_Bit then
         Result :=
           C_Chmod (Interfaces.C.To_C (To_Native_Path (Path)), Mode);
         pragma Unreferenced (Result);
      end if;
   end Set_Executable;

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
      --  An empty path is never a file; Ada.Directories rejects it with
      --  Name_Error, so answer directly rather than raising for callers that
      --  probe optional/absent paths (e.g. a suppressed config scope).
      if Path = "" then
         return False;
      end if;

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
