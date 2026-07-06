with Ada.IO_Exceptions;
with Ada.Streams;

with Version.Compression;
with Version.Files;

package body Version.Zip is

   use Ada.Streams;

   Fixed_Time : constant Unsigned_16 := 0;
   Fixed_Date : constant Unsigned_16 := 16#0021#; -- 1980-01-01

   function To_U32 (Value : Natural) return Unsigned_32 is
   begin
      return Unsigned_32 (Value);
   end To_U32;

   procedure Advance (Writer : in out Zip_Writer; Count : Natural) is
   begin
      if Unsigned_32'Last - Writer.Offset < Unsigned_32 (Count) then
         raise Ada.IO_Exceptions.Data_Error with "zip archive too large";
      end if;
      Writer.Offset := Writer.Offset + Unsigned_32 (Count);
   end Advance;

   procedure Write_Bytes
     (Writer : in out Zip_Writer; Data : Stream_Element_Array) is
   begin
      Ada.Streams.Stream_IO.Write (Writer.File, Data);
      Advance (Writer, Natural (Data'Length));
   end Write_Bytes;

   procedure Write_String (Writer : in out Zip_Writer; Text : String) is
   begin
      if Text'Length = 0 then
         return;
      end if;

      declare
         Data :
           Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
         J    : Stream_Element_Offset := Data'First;
      begin
         for C of Text loop
            Data (J) := Stream_Element (Character'Pos (C));
            J := J + 1;
         end loop;
         Write_Bytes (Writer, Data);
      end;
   end Write_String;

   procedure Write_U16 (Writer : in out Zip_Writer; Value : Unsigned_16) is
      Data : Stream_Element_Array (1 .. 2);
      V    : constant Unsigned_32 := Unsigned_32 (Value);
   begin
      Data (1) := Stream_Element (V and 16#FF#);
      Data (2) := Stream_Element (Shift_Right (V, 8) and 16#FF#);
      Write_Bytes (Writer, Data);
   end Write_U16;

   procedure Write_U32 (Writer : in out Zip_Writer; Value : Unsigned_32) is
      Data : Stream_Element_Array (1 .. 4);
   begin
      Data (1) := Stream_Element (Value and 16#FF#);
      Data (2) := Stream_Element (Shift_Right (Value, 8) and 16#FF#);
      Data (3) := Stream_Element (Shift_Right (Value, 16) and 16#FF#);
      Data (4) := Stream_Element (Shift_Right (Value, 24) and 16#FF#);
      Write_Bytes (Writer, Data);
   end Write_U32;

   function CRC32 (Text : String) return Unsigned_32 is
      CRC : Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for C of Text loop
         CRC := CRC xor Unsigned_32 (Character'Pos (C));
         for Bit in 1 .. 8 loop
            if (CRC and 1) /= 0 then
               CRC := Shift_Right (CRC, 1) xor 16#EDB8_8320#;
            else
               CRC := Shift_Right (CRC, 1);
            end if;
         end loop;
      end loop;
      return CRC xor 16#FFFF_FFFF#;
   end CRC32;

   function Directory_Name (Archive_Path : String) return String is
   begin
      if Archive_Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty zip path";
      elsif Archive_Path (Archive_Path'Last) = '/' then
         return Archive_Path;
      else
         return Archive_Path & "/";
      end if;
   end Directory_Name;

   procedure Write_Local_Header
     (Writer            : in out Zip_Writer;
      Name              : String;
      CRC               : Unsigned_32;
      Compressed_Size   : Unsigned_32;
      Uncompressed_Size : Unsigned_32;
      Method            : Unsigned_16) is
   begin
      if Name'Length = 0 or else Name'Length > Natural (Unsigned_16'Last) then
         raise Ada.IO_Exceptions.Data_Error with "invalid zip path length";
      end if;

      Write_U32 (Writer, 16#0403_4B50#);
      Write_U16 (Writer, 20);
      Write_U16 (Writer, 0);
      Write_U16 (Writer, Method);
      Write_U16 (Writer, Fixed_Time);
      Write_U16 (Writer, Fixed_Date);
      Write_U32 (Writer, CRC);
      Write_U32 (Writer, Compressed_Size);
      Write_U32 (Writer, Uncompressed_Size);
      Write_U16 (Writer, Unsigned_16 (Name'Length));
      Write_U16 (Writer, 0);
      Write_String (Writer, Name);
   end Write_Local_Header;

   function Raw_Deflate_Stored (Content : String) return String is
      Wrapped : constant String := Version.Compression.Deflate_Zlib (Content);
   begin
      if Wrapped'Length < 6 then
         raise Ada.IO_Exceptions.Data_Error
           with "zip deflate output too short";
      end if;

      --  ZIP method 8 stores a raw deflate stream.  The integrated Zlib helper
      --  intentionally produces a zlib-wrapped stored-deflate stream for the
      --  rest of the project, so the ZIP writer removes the two-byte zlib
      --  header and four-byte Adler-32 trailer while keeping the deflate blocks.
      return Wrapped (Wrapped'First + 2 .. Wrapped'Last - 4);
   end Raw_Deflate_Stored;

   function Is_Disallowed_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Disallowed_Control;

   procedure Validate_Name_Component (Full_Name : String; Component : String)
   is
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "empty zip path component: " & Full_Name;
      elsif Component = "." or else Component = ".." or else Component = ".git"
      then
         raise Ada.IO_Exceptions.Data_Error
           with "unsafe zip path: " & Full_Name;
      end if;
   end Validate_Name_Component;

   procedure Validate_Name (Name : String) is
      Start : Natural;
      Stop  : Natural;
   begin
      if Name'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty zip path";
      elsif Name'Length > Natural (Unsigned_16'Last) then
         raise Ada.IO_Exceptions.Data_Error with "invalid zip path length";
      elsif Name (Name'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error
           with "absolute zip path rejected: " & Name;
      end if;

      for C of Name loop
         if C = '\' or else C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid zip path: " & Name;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error
              with "zip path contains control character";
         end if;
      end loop;

      Start := Name'First;
      while Start <= Name'Last loop
         Stop := Start;
         while Stop <= Name'Last and then Name (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         Validate_Name_Component (Name, Name (Start .. Stop - 1));
         Start := Stop + 1;
      end loop;
   end Validate_Name;

   procedure Validate_Link_Target (Target : String) is
      Start : Natural;
      Stop  : Natural;
   begin
      if Target'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty zip symlink target";
      elsif Target (Target'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error
           with "absolute zip symlink target rejected: " & Target;
      end if;

      for C of Target loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error
              with "zip symlink target contains NUL";
         elsif C = '\' then
            raise Ada.IO_Exceptions.Data_Error
              with "invalid zip symlink target: " & Target;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error
              with "zip symlink target contains control character";
         end if;
      end loop;

      Start := Target'First;
      while Start <= Target'Last loop
         Stop := Start;
         while Stop <= Target'Last and then Target (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         if Stop = Start then
            if Stop /= Target'Last then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty zip symlink target component: " & Target;
            end if;
         elsif Target (Start .. Stop - 1) = "."
           or else Target (Start .. Stop - 1) = ".."
         then
            raise Ada.IO_Exceptions.Data_Error
              with "unsafe zip symlink target: " & Target;
         end if;

         Start := Stop + 1;
      end loop;
   end Validate_Link_Target;

   function Canonical_Entry_Name (Name : String) return String is
   begin
      if Name'Length > 0 and then Name (Name'Last) = '/' then
         return Name (Name'First .. Name'Last - 1);
      else
         return Name;
      end if;
   end Canonical_Entry_Name;

   procedure Add_Entry
     (Writer       : in out Zip_Writer;
      Archive_Path : String;
      Content      : String;
      Executable   : Boolean;
      Directory    : Boolean;
      Symlink      : Boolean := False)
   is
      Name              : constant String :=
        (if Directory then Directory_Name (Archive_Path) else Archive_Path);
      Offset            : constant Unsigned_32 := Writer.Offset;
      CRC               : constant Unsigned_32 :=
        (if Directory then 0 else CRC32 (Content));
      Method            : constant Unsigned_16 :=
        (if Directory or else Symlink then 0 else 8);
      Payload           : constant String :=
        (if Directory
         then ""
         elsif Symlink
         then Content
         else Raw_Deflate_Stored (Content));
      Compressed_Size   : constant Unsigned_32 := To_U32 (Payload'Length);
      Uncompressed_Size : constant Unsigned_32 :=
        (if Directory then 0 else To_U32 (Content'Length));
      Unix_Mode         : constant Unsigned_32 :=
        (if Directory
         then 8#040755#
         elsif Symlink
         then 8#120777#
         elsif Executable
         then 8#100755#
         else 8#100644#);
   begin
      if not Writer.Open then
         raise Ada.IO_Exceptions.Status_Error with "zip writer is not open";
      end if;

      Validate_Name (Name);
      if Symlink then
         Validate_Link_Target (Content);
      end if;
      declare
         Canonical : constant String := Canonical_Entry_Name (Name);
      begin
         if Writer.Names.Contains (To_Unbounded_String (Canonical)) then
            raise Ada.IO_Exceptions.Data_Error
              with "duplicate zip archive entry: " & Name;
         end if;
         Writer.Names.Include (To_Unbounded_String (Canonical));
      end;

      Write_Local_Header
        (Writer            => Writer,
         Name              => Name,
         CRC               => CRC,
         Compressed_Size   => Compressed_Size,
         Uncompressed_Size => Uncompressed_Size,
         Method            => Method);
      if not Directory then
         Write_String (Writer, Payload);
      end if;

      Writer.Entries.Append
        (Central_Entry'
           (Name              => To_Unbounded_String (Name),
            CRC               => CRC,
            Compressed_Size   => Compressed_Size,
            Uncompressed_Size => Uncompressed_Size,
            Offset            => Offset,
            External          => Shift_Left (Unix_Mode, 16),
            Method            => Method,
            Directory         => Directory,
            Symlink           => Symlink));
   end Add_Entry;

   procedure Create (Writer : in out Zip_Writer; Output_Path : String) is
   begin
      if Writer.Open then
         Close (Writer);
      end if;

      Version.Files.Create_Parent_Directories (Output_Path);
      Ada.Streams.Stream_IO.Create
        (Writer.File,
         Ada.Streams.Stream_IO.Out_File,
         Version.Files.To_Native_Path (Output_Path));
      Writer.Open := True;
      Writer.Offset := 0;
      Writer.Entries.Clear;
      Writer.Names.Clear;
   end Create;

   procedure Add_File
     (Writer       : in out Zip_Writer;
      Archive_Path : String;
      Content      : String;
      Executable   : Boolean := False) is
   begin
      if Archive_Path'Length > 0
        and then Archive_Path (Archive_Path'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error
           with
             "regular zip file path must not end with slash: " & Archive_Path;
      end if;

      Add_Entry
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Content      => Content,
         Executable   => Executable,
         Directory    => False,
         Symlink      => False);
   end Add_File;

   procedure Add_Directory (Writer : in out Zip_Writer; Archive_Path : String)
   is
   begin
      Add_Entry
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Content      => "",
         Executable   => False,
         Directory    => True,
         Symlink      => False);
   end Add_Directory;

   procedure Add_Symlink
     (Writer : in out Zip_Writer; Archive_Path : String; Link_Target : String)
   is
   begin
      if Archive_Path'Length > 0
        and then Archive_Path (Archive_Path'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error
           with "zip symlink path must not end with slash: " & Archive_Path;
      end if;

      Add_Entry
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Content      => Link_Target,
         Executable   => False,
         Directory    => False,
         Symlink      => True);
   end Add_Symlink;

   procedure Write_Central_Entry
     (Writer : in out Zip_Writer; Current_Entry : Central_Entry)
   is
      Name : constant String := To_String (Current_Entry.Name);
   begin
      Write_U32 (Writer, 16#0201_4B50#);
      Write_U16 (Writer, 16#031E#);
      Write_U16 (Writer, 20);
      Write_U16 (Writer, 0);
      Write_U16 (Writer, Current_Entry.Method);
      Write_U16 (Writer, Fixed_Time);
      Write_U16 (Writer, Fixed_Date);
      Write_U32 (Writer, Current_Entry.CRC);
      Write_U32 (Writer, Current_Entry.Compressed_Size);
      Write_U32 (Writer, Current_Entry.Uncompressed_Size);
      Write_U16 (Writer, Unsigned_16 (Name'Length));
      Write_U16 (Writer, 0);
      Write_U16 (Writer, 0);
      Write_U16 (Writer, 0);
      Write_U16 (Writer, 0);
      Write_U32 (Writer, Current_Entry.External);
      Write_U32 (Writer, Current_Entry.Offset);
      Write_String (Writer, Name);
   end Write_Central_Entry;

   procedure Close (Writer : in out Zip_Writer) is
      Central_Start : Unsigned_32;
      Central_Size  : Unsigned_32;
      Count         : constant Natural := Natural (Writer.Entries.Length);
   begin
      if Writer.Open then
         begin
            if Count > Natural (Unsigned_16'Last) then
               raise Ada.IO_Exceptions.Data_Error with "too many zip entries";
            end if;

            Central_Start := Writer.Offset;
            if not Writer.Entries.Is_Empty then
               for I in Writer.Entries.First_Index .. Writer.Entries.Last_Index
               loop
                  Write_Central_Entry (Writer, Writer.Entries.Element (I));
               end loop;
            end if;
            Central_Size := Writer.Offset - Central_Start;

            Write_U32 (Writer, 16#0605_4B50#);
            Write_U16 (Writer, 0);
            Write_U16 (Writer, 0);
            Write_U16 (Writer, Unsigned_16 (Count));
            Write_U16 (Writer, Unsigned_16 (Count));
            Write_U32 (Writer, Central_Size);
            Write_U32 (Writer, Central_Start);
            Write_U16 (Writer, 0);
         exception
            when others =>
               Ada.Streams.Stream_IO.Close (Writer.File);
               Writer.Open := False;
               raise;
         end;

         Ada.Streams.Stream_IO.Close (Writer.File);
         Writer.Open := False;
      end if;
   end Close;

end Version.Zip;
