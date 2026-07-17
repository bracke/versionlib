with Ada.IO_Exceptions;
with Ada.Streams;

with Version.Files;

package body Version.Tar is

   use Ada.Streams;

   Block_Size : constant := 512;

   procedure Write_String
     (File : in out Ada.Streams.Stream_IO.File_Type;
      Text : String)
   is
   begin
      if Text'Length = 0 then
         return;
      end if;

      declare
         Data : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
         J    : Stream_Element_Offset := Data'First;
      begin
         for C of Text loop
            Data (J) := Stream_Element (Character'Pos (C));
            J := J + 1;
         end loop;
         Ada.Streams.Stream_IO.Write (File, Data);
      end;
   end Write_String;

   function Zero_Block return String is
      Result : constant String (1 .. Block_Size) := [others => Character'Val (0)];
   begin
      return Result;
   end Zero_Block;

   procedure Put_Field
     (Header : in out String;
      First  : Positive;
      Length : Positive;
      Text   : String)
   is
      Last : constant Natural := First + Length - 1;
   begin
      Header (First .. Last) := [others => Character'Val (0)];
      if Text'Length > Length then
         raise Ada.IO_Exceptions.Data_Error with "tar header field too long";
      end if;
      Header (First .. First + Text'Length - 1) := Text;
   end Put_Field;

   function Octal
     (Value : Natural;
      Width : Positive)
      return String
   is
      Octal_Digits : String (1 .. Width - 1) := (others => '0');
      V      : Natural := Value;
      Pos    : Natural := Octal_Digits'Last;
      Result : String (1 .. Width) := (others => Character'Val (0));
   begin
      while V > 0 loop
         if Pos < Octal_Digits'First then
            raise Ada.IO_Exceptions.Data_Error with "tar numeric field overflow";
         end if;
         Octal_Digits (Pos) := Character'Val (Character'Pos ('0') + (V mod 8));
         V := V / 8;
         Pos := Pos - 1;
      end loop;

      Result (1 .. Width - 1) := Octal_Digits;
      Result (Width) := Character'Val (0);
      return Result;
   end Octal;

   procedure Split_Ustar_Path
     (Path   : String;
      Name   : out Unbounded_String;
      Prefix : out Unbounded_String)
   is
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty tar path";
      elsif Path'Length <= 100 then
         Name := To_Unbounded_String (Path);
         Prefix := Null_Unbounded_String;
         return;
      elsif Path'Length > 256 then
         raise Ada.IO_Exceptions.Data_Error with "tar path too long: " & Path;
      end if;

      for I in reverse Path'Range loop
         if Path (I) = '/' and then I < Path'Last then
            declare
               Prefix_Text : constant String := Path (Path'First .. I - 1);
               Name_Text   : constant String := Path (I + 1 .. Path'Last);
            begin
               if Prefix_Text'Length <= 155
                 and then Name_Text'Length > 0
                 and then Name_Text'Length <= 100
               then
                  Prefix := To_Unbounded_String (Prefix_Text);
                  Name := To_Unbounded_String (Name_Text);
                  return;
               end if;
            end;
         end if;
      end loop;

      raise Ada.IO_Exceptions.Data_Error with "tar path too long: " & Path;
   end Split_Ustar_Path;

   function Is_Disallowed_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Disallowed_Control;

   function Canonical_Entry_Name (Path : String) return String is
   begin
      if Path'Length > 0 and then Path (Path'Last) = '/' then
         return Path (Path'First .. Path'Last - 1);
      else
         return Path;
      end if;
   end Canonical_Entry_Name;

   function Has_Name
     (Writer : Tar_Writer;
      Name   : String)
      return Boolean
   is
   begin
      if Writer.Names.Is_Empty then
         return False;
      end if;

      for I in Writer.Names.First_Index .. Writer.Names.Last_Index loop
         if To_String (Writer.Names.Element (I)) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Has_Name;

   procedure Remember_Name
     (Writer : in out Tar_Writer;
      Name   : String)
   is
      Canonical : constant String := Canonical_Entry_Name (Name);
   begin
      if Has_Name (Writer, Canonical) then
         raise Ada.IO_Exceptions.Data_Error with "duplicate tar archive entry: " & Name;
      end if;
      Writer.Names.Append (To_Unbounded_String (Canonical));
   end Remember_Name;

   procedure Validate_Component
     (Full_Path : String;
      Component : String)
   is
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty tar path component: " & Full_Path;
      elsif Component = "." or else Component = ".." or else Component = ".git" then
         raise Ada.IO_Exceptions.Data_Error with "unsafe tar path: " & Full_Path;
      end if;
   end Validate_Component;

   procedure Validate_Archive_Path (Path : String) is
      Start : Natural;
      Stop  : Natural;
   begin
      if Path'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty tar path";
      elsif Path (Path'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error with "absolute tar path rejected: " & Path;
      end if;

      for C of Path loop
         if C = '\' or else C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "invalid tar path: " & Path;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "tar path contains control character";
         end if;
      end loop;

      Start := Path'First;
      while Start <= Path'Last loop
         Stop := Start;
         while Stop <= Path'Last and then Path (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         Validate_Component (Path, Path (Start .. Stop - 1));
         Start := Stop + 1;
      end loop;
   end Validate_Archive_Path;

   procedure Validate_Link_Target (Target : String) is
      Start : Natural;
      Stop  : Natural;
   begin
      if Target'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "empty tar symlink target";
      elsif Target'Length > 100 then
         raise Ada.IO_Exceptions.Data_Error with "tar symlink target too long";
      elsif Target (Target'First) = '/' then
         raise Ada.IO_Exceptions.Data_Error with "absolute tar symlink target rejected: " & Target;
      end if;

      for C of Target loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with "tar symlink target contains NUL";
         elsif C = '\' then
            raise Ada.IO_Exceptions.Data_Error with "invalid tar symlink target: " & Target;
         elsif Is_Disallowed_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with "tar symlink target contains control character";
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
               raise Ada.IO_Exceptions.Data_Error with
                 "empty tar symlink target component: " & Target;
            end if;
         elsif Target (Start .. Stop - 1) = "."
           or else Target (Start .. Stop - 1) = ".."
         then
            raise Ada.IO_Exceptions.Data_Error with
              "unsafe tar symlink target: " & Target;
         end if;

         Start := Stop + 1;
      end loop;
   end Validate_Link_Target;

   procedure Write_Header
     (Writer       : in out Tar_Writer;
      Archive_Path : String;
      Size         : Natural;
      Mode         : Natural;
      Typeflag     : Character;
      Link_Target  : String := "")
   is
      Header      : String (1 .. Block_Size) := [others => Character'Val (0)];
      Sum         : Natural := 0;
      Full_Name   : constant String :=
        (if Typeflag = '5' and then Archive_Path'Length > 0
         and then Archive_Path (Archive_Path'Last) /= '/'
         then Archive_Path & "/"
         else Archive_Path);
      Name_Field  : Unbounded_String;
      Prefix      : Unbounded_String;
   begin
      if not Writer.Open then
         raise Ada.IO_Exceptions.Status_Error with "tar writer is not open";
      end if;

      Validate_Archive_Path (Full_Name);
      if Typeflag = '2' then
         Validate_Link_Target (Link_Target);
      end if;
      Remember_Name (Writer, Full_Name);
      Split_Ustar_Path (Full_Name, Name_Field, Prefix);

      Put_Field (Header, 1, 100, To_String (Name_Field));
      Put_Field (Header, 101, 8, Octal (Mode, 8));
      Put_Field (Header, 109, 8, Octal (0, 8));
      Put_Field (Header, 117, 8, Octal (0, 8));
      Put_Field (Header, 125, 12, Octal (Size, 12));
      Put_Field (Header, 137, 12, Octal (Writer.Mtime, 12));
      Header (149 .. 156) := [others => ' '];
      Header (157) := Typeflag;
      if Typeflag = '2' then
         Put_Field (Header, 158, 100, Link_Target);
      end if;
      Put_Field (Header, 258, 6, "ustar");
      Put_Field (Header, 264, 2, "00");
      --  git stamps every entry with owner/group "root" (uid/gid 0) and
      --  writes the devmajor/devminor fields as octal zero (not left NUL).
      Put_Field (Header, 266, 32, "root");
      Put_Field (Header, 298, 32, "root");
      Put_Field (Header, 330, 8, Octal (0, 8));
      Put_Field (Header, 338, 8, Octal (0, 8));
      if Length (Prefix) > 0 then
         Put_Field (Header, 346, 155, To_String (Prefix));
      end if;

      for C of Header loop
         Sum := Sum + Character'Pos (C);
      end loop;

      --  git writes the checksum as a 7-digit zero-padded octal followed by a
      --  NUL (matching the other numeric fields), not "6 digits + NUL + space".
      Put_Field (Header, 149, 8, Octal (Sum, 8));

      Write_String (Writer.File, Header);
   end Write_Header;

   procedure Create
     (Writer      : in out Tar_Writer;
      Output_Path : String;
      Mtime       : Natural := 0)
   is
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
      Writer.Mtime := Mtime;
      Writer.Names.Clear;
   end Create;

   procedure Add_File
     (Writer       : in out Tar_Writer;
      Archive_Path : String;
      Content      : String;
      Executable   : Boolean := False)
   is
      Pad : constant Natural :=
        (if Content'Length mod Block_Size = 0
         then 0
         else Block_Size - (Content'Length mod Block_Size));
   begin
      if Archive_Path'Length > 0
        and then Archive_Path (Archive_Path'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "regular tar file path must not end with slash: " & Archive_Path;
      end if;

      Write_Header
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Size         => Content'Length,
         --  git's tar mode: (0666 or 0777 for exec) & ~tar.umask (default
         --  0002) -> 0664 for a plain file, 0775 for an executable.
         Mode         => (if Executable then 8#775# else 8#664#),
         Typeflag     => '0');
      Write_String (Writer.File, Content);
      if Pad > 0 then
         Write_String (Writer.File, String'(1 .. Pad => Character'Val (0)));
      end if;
   end Add_File;

   procedure Add_Pax_Global_Header
     (Writer  : in out Tar_Writer;
      Comment : String)
   is
      Field : constant String :=
        "comment=" & Comment & Character'Val (10);

      --  A pax record is "<len> <field>" where <len> is the total record
      --  length in decimal, including its own digits -- solve the self-
      --  reference by iterating to a fixed point.
      function Dec (N : Natural) return String is
         S : constant String := Natural'Image (N);
      begin
         return S (S'First + 1 .. S'Last);  --  drop the leading space
      end Dec;

      function Record_Text return String is
         N : Natural := Field'Length + 1;
      begin
         loop
            declare
               Candidate : constant String := Dec (N) & " " & Field;
            begin
               if Candidate'Length = N then
                  return Candidate;
               end if;
               N := Candidate'Length;
            end;
         end loop;
      end Record_Text;

      Content : constant String := Record_Text;
      Pad     : constant Natural :=
        (if Content'Length mod Block_Size = 0
         then 0
         else Block_Size - (Content'Length mod Block_Size));
   begin
      Write_Header
        (Writer       => Writer,
         Archive_Path => "pax_global_header",
         Size         => Content'Length,
         Mode         => 8#666#,
         Typeflag     => 'g');
      Write_String (Writer.File, Content);
      if Pad > 0 then
         Write_String (Writer.File, String'(1 .. Pad => Character'Val (0)));
      end if;
   end Add_Pax_Global_Header;

   procedure Add_Directory
     (Writer       : in out Tar_Writer;
      Archive_Path : String)
   is
   begin
      Write_Header
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Size         => 0,
         --  git: (0777) & ~tar.umask (0002) -> 0775 for a directory.
         Mode         => 8#775#,
         Typeflag     => '5');
   end Add_Directory;

   procedure Add_Symlink
     (Writer       : in out Tar_Writer;
      Archive_Path : String;
      Link_Target  : String)
   is
   begin
      if Archive_Path'Length > 0
        and then Archive_Path (Archive_Path'Last) = '/'
      then
         raise Ada.IO_Exceptions.Data_Error with
           "tar symlink path must not end with slash: " & Archive_Path;
      end if;

      Write_Header
        (Writer       => Writer,
         Archive_Path => Archive_Path,
         Size         => 0,
         --  git writes symlinks with mode 0777 (tar.umask is not applied to
         --  a symlink, unlike files and directories).
         Mode         => 8#777#,
         Typeflag     => '2',
         Link_Target  => Link_Target);
   end Add_Symlink;

   procedure Close
     (Writer : in out Tar_Writer)
   is
      --  git pads the archive to a full 20-block (512 * 20 = 10240) record,
      --  matching GNU tar's default blocking factor, after the two trailing
      --  zero blocks. Everything is written in 512-byte blocks, so the offset
      --  is always a multiple of 512; pad up to the next 10240 boundary.
      Record_Size : constant Long_Long_Integer := 10_240;
   begin
      if Writer.Open then
         Write_String (Writer.File, Zero_Block);
         Write_String (Writer.File, Zero_Block);
         declare
            Pos       : constant Long_Long_Integer :=
              Long_Long_Integer (Ada.Streams.Stream_IO.Size (Writer.File));
            Remainder : constant Natural :=
              Natural (Pos mod Record_Size);
         begin
            if Remainder /= 0 then
               Write_String
                 (Writer.File,
                  String'(1 .. Natural (Record_Size) - Remainder
                          => Character'Val (0)));
            end if;
         end;
         Ada.Streams.Stream_IO.Close (Writer.File);
         Writer.Open := False;
         Writer.Names.Clear;
      end if;
   end Close;

end Version.Tar;
