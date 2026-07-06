with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Interfaces; use Interfaces;
with Zlib;       use Zlib;
with Version.Files;
with Version.Hash;
with Version.Pack_Index;

package body Version.Pack is
   use Version.Objects;

   use Ada.Streams;
   use Ada.Strings.Unbounded;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   function Byte_At (Data : Stream_Element_Array; Pos : U64) return Natural is
      --  Pack offsets are zero-based file offsets.
      --  Stream_Element_Array indexes are Data'First-based.
      P : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Pos);
   begin
      if P < Data'First or else P > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: byte offset outside pack file";
      end if;

      return Natural (Data (P));
   end Byte_At;

   function Object_Type_From_Code (Code : Natural) return Packed_Object_Type is
   begin
      case Code is
         when 1      =>
            return Packed_Commit;

         when 2      =>
            return Packed_Tree;

         when 3      =>
            return Packed_Blob;

         when 4      =>
            return Packed_Tag;

         when 6      =>
            return Packed_Ofs_Delta;

         when 7      =>
            return Packed_Ref_Delta;

         when others =>
            return Packed_Unsupported;
      end case;
   end Object_Type_From_Code;
   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Read_File (Path : String) return Stream_Element_Array is
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Open
        (File, Stream_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         Size : constant Stream_IO.Count := Stream_IO.Size (File);
         Data : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
         Last : Stream_Element_Offset;
      begin
         Stream_IO.Read (File, Data, Last);
         Stream_IO.Close (File);

         if Last /= Data'Last then
            raise Ada.IO_Exceptions.Data_Error
              with "could not read complete pack index";
         end if;

         return Data;
      end;

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         raise;
   end Read_File;

   function U32_BE
     (Data : Stream_Element_Array; Pos : Stream_Element_Offset) return U32 is
   begin
      if Pos + 3 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack index: truncated u32";
      end if;

      return
        U32 (Data (Pos)) * 16#1000000# + U32 (Data (Pos + 1)) * 16#10000#
        + U32 (Data (Pos + 2)) * 16#100#
        + U32 (Data (Pos + 3));
   end U32_BE;

   function U64_BE
     (Data : Stream_Element_Array; Pos : Stream_Element_Offset) return U64
   is
      Result : U64 := 0;
   begin
      if Pos + 7 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack index: truncated u64";
      end if;

      for I in 0 .. 7 loop
         Result := Result * 256 + U64 (Data (Pos + Stream_Element_Offset (I)));
      end loop;

      return Result;
   end U64_BE;

   function Hex_Nibble (C : Character) return Natural is
   begin
      if C in '0' .. '9' then
         return Character'Pos (C) - Character'Pos ('0');
      elsif C in 'a' .. 'f' then
         return Character'Pos (C) - Character'Pos ('a') + 10;
      elsif C in 'A' .. 'F' then
         return Character'Pos (C) - Character'Pos ('A') + 10;
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid object id hex digit";
      end if;
   end Hex_Nibble;

   function Hex_Byte
     (Id : Version.Objects.Hex_Object_Id; Index : Positive) return Natural is
   begin
      return Hex_Nibble (To_String (Id) (Index)) * 16 + Hex_Nibble (To_String (Id) (Index + 1));
   end Hex_Byte;

   function Compare_Id_At
     (Data       : Stream_Element_Array;
      Pos        : Stream_Element_Offset;
      Id         : Version.Objects.Hex_Object_Id;
      Raw_Length : Natural) return Integer is
   begin
      if Pos + Stream_Element_Offset (Raw_Length) - 1 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack index: truncated object name table";
      end if;

      for I in 0 .. Raw_Length - 1 loop
         declare
            A : constant Natural :=
              Natural (Data (Pos + Stream_Element_Offset (I)));

            B : constant Natural := Hex_Byte (Id, I * 2 + 1);
         begin
            if A < B then
               return -1;
            elsif A > B then
               return 1;
            end if;
         end;
      end loop;

      return 0;
   end Compare_Id_At;

   function Id_First_Byte (Id : Version.Objects.Hex_Object_Id) return Natural
   is
   begin
      return Hex_Byte (Id, 1);
   end Id_First_Byte;

   function Offset_For_Index
     (Data         : Stream_Element_Array;
      Object_Count : Natural;
      Object_Index : Natural;
      Names_Start  : Stream_Element_Offset;
      Raw_Length   : Natural) return U64
   is
      Crc_Start : constant Stream_Element_Offset :=
        Names_Start + Stream_Element_Offset (Object_Count * Raw_Length);

      Offset_Start : constant Stream_Element_Offset :=
        Crc_Start + Stream_Element_Offset (Object_Count * 4);

      Offset_Pos : constant Stream_Element_Offset :=
        Offset_Start + Stream_Element_Offset (Object_Index * 4);

      Off32 : constant U32 := U32_BE (Data, Offset_Pos);
   begin
      if Offset_Start + Stream_Element_Offset (Object_Count * 4) - 1
        > Data'Last
      then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack index: truncated offset table";
      end if;

      if Off32 < 16#80000000# then
         return U64 (Off32);
      end if;

      declare
         Large_Index : constant Natural := Natural (Off32 and 16#7FFFFFFF#);

         Large_Start : constant Stream_Element_Offset :=
           Offset_Start + Stream_Element_Offset (Object_Count * 4);

         Large_Pos : constant Stream_Element_Offset :=
           Large_Start + Stream_Element_Offset (Large_Index * 8);
      begin
         return U64_BE (Data, Large_Pos);
      end;
   end Offset_For_Index;

   function Next_Offset_After
     (Data         : Stream_Element_Array;
      Object_Count : Natural;
      Names_Start  : Stream_Element_Offset;
      Offset       : U64;
      Pack_Size    : U64;
      Raw_Length   : Natural) return U64
   is
      Best : U64 := Pack_Size - U64 (Raw_Length); -- exclude pack checksum
   begin
      for I in 0 .. Object_Count - 1 loop
         declare
            Candidate : constant U64 :=
              Offset_For_Index
                (Data         => Data,
                 Object_Count => Object_Count,
                 Object_Index => I,
                 Names_Start  => Names_Start,
                 Raw_Length   => Raw_Length);
         begin
            if Candidate > Offset and then Candidate < Best then
               Best := Candidate;
            end if;
         end;
      end loop;

      return Best;
   end Next_Offset_After;
   function Index_Find_Location
     (Index_Path : String;
      Pack_Path  : String;
      Id         : Version.Objects.Hex_Object_Id;
      Raw_Length : Natural) return Pack_Location
   is
      Data : constant Stream_Element_Array := Read_File (Index_Path);

      Magic : constant U32 := U32_BE (Data, Data'First);
      Ver   : constant U32 := U32_BE (Data, Data'First + 4);

      Fanout_Start : constant Stream_Element_Offset := Data'First + 8;
   begin
      if Magic /= 16#FF744F63# then
         raise Ada.IO_Exceptions.Data_Error
           with "unsupported pack index: missing v2 magic";
      end if;

      if Ver /= 2 then
         raise Ada.IO_Exceptions.Data_Error
           with "unsupported pack index: only version 2 is supported";
      end if;

      if Data'Length < 8 + 256 * 4 then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack index: too small";
      end if;

      declare
         First_Byte : constant Natural := Id_First_Byte (Id);

         Low_Count : constant Natural :=
           (if First_Byte = 0
            then 0
            else
              Natural
                (U32_BE
                   (Data,
                    Fanout_Start
                    + Stream_Element_Offset ((First_Byte - 1) * 4))));

         High_Count : constant Natural :=
           Natural
             (U32_BE
                (Data, Fanout_Start + Stream_Element_Offset (First_Byte * 4)));

         Object_Count : constant Natural :=
           Natural
             (U32_BE (Data, Fanout_Start + Stream_Element_Offset (255 * 4)));

         Names_Start : constant Stream_Element_Offset :=
           Fanout_Start + Stream_Element_Offset (256 * 4);

         Low  : Integer := Integer (Low_Count);
         High : Integer := Integer (High_Count) - 1;
      begin
         if Object_Count = 0 then
            return
              (Found      => False,
               Pack_Path  => Null_Unbounded_String,
               Offset     => 0,
               End_Offset => 0);
         end if;

         if Names_Start + Stream_Element_Offset (Object_Count * Raw_Length) - 1
           > Data'Last
         then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt pack index: truncated object name table";
         end if;

         while Low <= High loop
            declare
               Mid : constant Integer := (Low + High) / 2;

               Name_Pos : constant Stream_Element_Offset :=
                 Names_Start + Stream_Element_Offset (Mid * Raw_Length);

               Cmp : constant Integer :=
                 Compare_Id_At
                   (Data => Data, Pos => Name_Pos, Id => Id,
                    Raw_Length => Raw_Length);
            begin
               if Cmp = 0 then
                  declare
                     Offset : constant U64 :=
                       Offset_For_Index
                         (Data         => Data,
                          Object_Count => Object_Count,
                          Object_Index => Natural (Mid),
                          Names_Start  => Names_Start,
                          Raw_Length   => Raw_Length);

                     Pack_Size : constant U64 :=
                       U64 (Ada.Directories.Size (Pack_Path));

                     End_Offset : constant U64 :=
                       Next_Offset_After
                         (Data         => Data,
                          Object_Count => Object_Count,
                          Names_Start  => Names_Start,
                          Offset       => Offset,
                          Pack_Size    => Pack_Size,
                          Raw_Length   => Raw_Length);
                  begin
                     return
                       (Found      => True,
                        Pack_Path  => To_Unbounded_String (Pack_Path),
                        Offset     => Offset,
                        End_Offset => End_Offset);
                  end;
               elsif Cmp < 0 then
                  Low := Mid + 1;
               else
                  High := Mid - 1;
               end if;
            end;
         end loop;

         return
           (Found      => False,
            Pack_Path  => Null_Unbounded_String,
            Offset     => 0,
            End_Offset => 0);
      end;
   end Index_Find_Location;

   function Find_Location
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Pack_Location
   is
      Pack_Dir : constant String :=
        Join
          (Join (Version.Repository.Common_Git_Dir (Repo), "objects"), "pack");

      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));

      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if not Ada.Directories.Exists (Pack_Dir) then
         return
           (Found      => False,
            Pack_Path  => Null_Unbounded_String,
            Offset     => 0,
            End_Offset => 0);
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Pack_Dir,
         Pattern   => "*.idx",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => False,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Index_Path : constant String := Ada.Directories.Full_Name (E);

            Pack_Path : constant String :=
              Index_Path (Index_Path'First .. Index_Path'Last - 3) & "pack";

            Location : constant Pack_Location :=
              Index_Find_Location
                (Index_Path => Index_Path, Pack_Path => Pack_Path, Id => Id,
                 Raw_Length => Raw_Length);
         begin
            if Location.Found then
               Ada.Directories.End_Search (Search);
               return Location;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);

      return
        (Found      => False,
         Pack_Path  => Null_Unbounded_String,
         Offset     => 0,
         End_Offset => 0);

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;

         raise;
   end Find_Location;

   function Contains
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Boolean is
   begin
      return Find_Location (Repo, Id).Found;
   end Contains;

   function Read_Header (Location : Pack_Location) return Packed_Object_Header
   is
      Data : constant Stream_Element_Array :=
        Read_File (To_String (Location.Pack_Path));

      Pos : U64 := Location.Offset;

      First : constant Natural := Byte_At (Data, Pos);

      Kind_Code : constant Natural := (First / 16) mod 8;

      Size : U64 := U64 (First mod 16);

      Shift : Natural := 4;
   begin
      if not Location.Found then
         raise Ada.IO_Exceptions.Data_Error with "pack location not found";
      end if;

      Pos := Pos + 1;

      if (First / 16#80#) mod 2 /= 0 then
         loop
            declare
               B : constant Natural := Byte_At (Data, Pos);
            begin
               Pos := Pos + 1;

               Size :=
                 Size + Interfaces.Shift_Left (U64 (B mod 16#80#), Shift);

               exit when (B / 16#80#) mod 2 = 0;

               Shift := Shift + 7;

               if Shift > 63 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "corrupt pack: object size varint too long";
               end if;
            end;
         end loop;
      end if;

      return
        (Kind        => Object_Type_From_Code (Kind_Code),
         Size        => Size,
         Data_Offset => Pos);
   end Read_Header;

   function Compressed_Slice
     (Data : Stream_Element_Array; Start : U64; Stop : U64)
      return Zlib.Byte_Array
   is
      First : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Start);

      Last : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Stop) - 1;

      Length : constant Natural := Natural (Last - First + 1);

      Result : Zlib.Byte_Array (1 .. Length);
      Outpos : Natural := Result'First;
   begin
      if First < Data'First or else Last > Data'Last or else Last < First then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: compressed stream bounds outside pack file";
      end if;

      for I in First .. Last loop
         Result (Outpos) := Zlib.Byte (Data (I));
         Outpos := Outpos + 1;
      end loop;

      return Result;
   end Compressed_Slice;

   function To_String (Input : Zlib.Byte_Array) return String is
      Result : String (1 .. Input'Length);
   begin
      for I in Input'Range loop
         Result (I - Input'First + 1) := Character'Val (Input (I));
      end loop;

      return Result;
   end To_String;

   function Non_Delta_Object_Kind_For
     (Kind : Packed_Object_Type) return Version.Objects.Object_Kind is
   begin
      case Kind is
         when Packed_Commit                       =>
            return Version.Objects.Commit_Object;

         when Packed_Tree                         =>
            return Version.Objects.Tree_Object;

         when Packed_Blob                         =>
            return Version.Objects.Blob_Object;

         when Packed_Tag                          =>
            return Version.Objects.Tag_Object;

         when Packed_Ofs_Delta | Packed_Ref_Delta =>
            raise Ada.IO_Exceptions.Data_Error
              with "delta object kind must be resolved before object-kind lookup";

         when Packed_Unsupported                  =>
            raise Ada.IO_Exceptions.Data_Error
              with "unsupported packed object type";
      end case;
   end Non_Delta_Object_Kind_For;

   function Raw_Id_At
     (Data : Stream_Element_Array; Pos : U64; Raw_Length : Natural)
      return Version.Objects.Hex_Object_Id
   is
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. Raw_Length * 2);
      Outpos : Natural := 1;
      P      : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Pos);
      Last   : constant Stream_Element_Offset :=
        P + Stream_Element_Offset (Raw_Length) - 1;
   begin
      if P < Data'First or else Last > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: truncated ref-delta base id";
      end if;

      for I in P .. Last loop
         declare
            V : constant Natural := Natural (Data (I));
         begin
            Result (Outpos) := Hex ((V / 16) + 1);
            Result (Outpos + 1) := Hex ((V mod 16) + 1);
            Outpos := Outpos + 2;
         end;
      end loop;

      return Version.Objects.To_Object_Id (Result);
   end Raw_Id_At;

   function Decode_Delta_Size (Data : String; Pos : in out Natural) return U64
   is
      Result : U64 := 0;
      Shift  : Natural := 0;
   begin
      loop
         if Pos > Data'Last then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt delta: truncated size varint";
         end if;

         declare
            B : constant Natural := Character'Pos (Data (Pos));
         begin
            Pos := Pos + 1;

            Result :=
              Result + Interfaces.Shift_Left (U64 (B mod 16#80#), Shift);

            exit when (B / 16#80#) mod 2 = 0;

            Shift := Shift + 7;

            if Shift > 63 then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt delta: size varint too long";
            end if;
         end;
      end loop;

      return Result;
   end Decode_Delta_Size;

   function Apply_Delta (Base : String; D : String) return String is
      Pos         : Natural := D'First;
      Base_Size   : constant U64 := Decode_Delta_Size (D, Pos);
      Result_Size : constant U64 := Decode_Delta_Size (D, Pos);

      Result : String (1 .. Natural (Result_Size));
      Outpos : Natural := Result'First;
   begin
      if Base_Size /= U64 (Base'Length) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt delta: base size mismatch";
      end if;

      while Pos <= D'Last loop
         declare
            Op : constant Natural := Character'Pos (D (Pos));
         begin
            Pos := Pos + 1;

            if (Op / 16#80#) mod 2 /= 0 then
               declare
                  Copy_Offset : Natural := 0;
                  Copy_Size   : Natural := 0;

                  procedure Read_Offset_Byte (Mask : Natural; Shift : Natural)
                  is
                  begin
                     if (Op / Mask) mod 2 /= 0 then
                        if Pos > D'Last then
                           raise Ada.IO_Exceptions.Data_Error
                             with "corrupt delta: truncated copy offset";
                        end if;

                        Copy_Offset :=
                          Copy_Offset + Character'Pos (D (Pos)) * (2 ** Shift);

                        Pos := Pos + 1;
                     end if;
                  end Read_Offset_Byte;

                  procedure Read_Size_Byte (Mask : Natural; Shift : Natural) is
                  begin
                     if (Op / Mask) mod 2 /= 0 then
                        if Pos > D'Last then
                           raise Ada.IO_Exceptions.Data_Error
                             with "corrupt delta: truncated copy size";
                        end if;

                        Copy_Size :=
                          Copy_Size + Character'Pos (D (Pos)) * (2 ** Shift);

                        Pos := Pos + 1;
                     end if;
                  end Read_Size_Byte;

               begin
                  Read_Offset_Byte (16#01#, 0);
                  Read_Offset_Byte (16#02#, 8);
                  Read_Offset_Byte (16#04#, 16);
                  Read_Offset_Byte (16#08#, 24);

                  Read_Size_Byte (16#10#, 0);
                  Read_Size_Byte (16#20#, 8);
                  Read_Size_Byte (16#40#, 16);

                  if Copy_Size = 0 then
                     Copy_Size := 16#10000#;
                  end if;

                  if Copy_Offset + Copy_Size > Base'Length then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt delta: copy exceeds base";
                  end if;

                  if Outpos + Copy_Size - 1 > Result'Last then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt delta: copy exceeds result";
                  end if;

                  for I in 0 .. Copy_Size - 1 loop
                     Result (Outpos + I) :=
                       Base (Base'First + Copy_Offset + I);
                  end loop;

                  Outpos := Outpos + Copy_Size;
               end;

            elsif Op /= 0 then
               declare
                  Insert_Size : constant Natural := Op;
               begin
                  if Pos + Insert_Size - 1 > D'Last then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt delta: insert exceeds delta";
                  end if;

                  if Outpos + Insert_Size - 1 > Result'Last then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt delta: insert exceeds result";
                  end if;

                  for I in 0 .. Insert_Size - 1 loop
                     Result (Outpos + I) := D (Pos + I);
                  end loop;

                  Pos := Pos + Insert_Size;
                  Outpos := Outpos + Insert_Size;
               end;

            else
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt delta: zero opcode";
            end if;
         end;
      end loop;

      if Outpos /= Result'Last + 1 then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt delta: result size mismatch";
      end if;

      return Result;
   end Apply_Delta;

   function Inflate_Pack_Data
     (Data : Stream_Element_Array; Start : U64; Stop : U64) return String
   is
      Compressed : constant Zlib.Byte_Array :=
        Compressed_Slice (Data => Data, Start => Start, Stop => Stop);

      Status : Zlib.Status_Code;

      Inflated : constant Zlib.Byte_Array :=
        Zlib.Inflate (Input => Compressed, Status => Status);
   begin
      if Status /= Zlib.Ok then
         raise Ada.IO_Exceptions.Data_Error
           with "pack object inflate failed: " & Zlib.Status_Image (Status);
      end if;

      return To_String (Inflated);
   end Inflate_Pack_Data;

   function Decode_Ofs_Delta_Base_Offset
     (Data : Stream_Element_Array; Current_Offset : U64; Pos : in out U64)
      return U64
   is
      B      : Natural := Byte_At (Data, Pos);
      Offset : U64 := U64 (B mod 16#80#);
   begin
      Pos := Pos + 1;

      while (B / 16#80#) mod 2 /= 0 loop
         B := Byte_At (Data, Pos);
         Pos := Pos + 1;

         Offset := (Offset + 1) * 16#80# + U64 (B mod 16#80#);
      end loop;

      if Offset > Current_Offset then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt ofs-delta: base offset before start of pack";
      end if;

      return Current_Offset - Offset;
   end Decode_Ofs_Delta_Base_Offset;

   function Read_Object_At_Location
     (Repo : Version.Repository.Repository_Handle; Location : Pack_Location)
      return Version.Objects.Git_Object
   is
      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
   begin
      if not Location.Found then
         raise Ada.IO_Exceptions.Data_Error with "pack location not found";
      end if;

      declare
         Header : constant Packed_Object_Header := Read_Header (Location);

         Data : constant Stream_Element_Array :=
           Read_File (To_String (Location.Pack_Path));
      begin
         case Header.Kind is
            when Packed_Commit | Packed_Tree | Packed_Blob =>
               declare
                  Content : constant String :=
                    Inflate_Pack_Data
                      (Data  => Data,
                       Start => Header.Data_Offset,
                       Stop  => Location.End_Offset);
               begin
                  if U64 (Content'Length) /= Header.Size then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt pack: inflated object size mismatch";
                  end if;

                  return
                    Version.Objects.Create_Object
                      (Kind    => Non_Delta_Object_Kind_For (Header.Kind),
                       Content => Content);
               end;

            when Packed_Ref_Delta                          =>
               declare
                  Base_Id : constant Version.Objects.Hex_Object_Id :=
                    Raw_Id_At
                      (Data => Data, Pos => Header.Data_Offset,
                       Raw_Length => Raw_Length);

                  Delta_Start : constant U64 :=
                    Header.Data_Offset + U64 (Raw_Length);

                  D : constant String :=
                    Inflate_Pack_Data
                      (Data  => Data,
                       Start => Delta_Start,
                       Stop  => Location.End_Offset);

                  Base_Obj : constant Version.Objects.Git_Object :=
                    Version.Objects.Read_Object (Repo, Base_Id);

                  Base_Content : constant String :=
                    Version.Objects.Content (Base_Obj);

                  Resolved_Content : constant String :=
                    Apply_Delta (Base => Base_Content, D => D);
               begin
                  if U64 (D'Length) /= Header.Size then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt ref-delta: inflated delta size mismatch";
                  end if;

                  return
                    Version.Objects.Create_Object
                      (Kind    => Version.Objects.Kind (Base_Obj),
                       Content => Resolved_Content);
               end;

            when Packed_Ofs_Delta                          =>
               declare
                  Delta_Start : U64 := Header.Data_Offset;

                  Base_Offset : constant U64 :=
                    Decode_Ofs_Delta_Base_Offset
                      (Data           => Data,
                       Current_Offset => Location.Offset,
                       Pos            => Delta_Start);

                  Base_Location : constant Pack_Location :=
                    (Found      => True,
                     Pack_Path  => Location.Pack_Path,
                     Offset     => Base_Offset,
                     End_Offset => Location.Offset);

                  D : constant String :=
                    Inflate_Pack_Data
                      (Data  => Data,
                       Start => Delta_Start,
                       Stop  => Location.End_Offset);

                  Base_Obj : constant Version.Objects.Git_Object :=
                    Read_Object_At_Location
                      (Repo => Repo, Location => Base_Location);

                  Base_Content : constant String :=
                    Version.Objects.Content (Base_Obj);

                  Resolved_Content : constant String :=
                    Apply_Delta (Base => Base_Content, D => D);
               begin
                  if U64 (D'Length) /= Header.Size then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt ofs-delta: inflated delta size mismatch";
                  end if;

                  return
                    Version.Objects.Create_Object
                      (Kind    => Version.Objects.Kind (Base_Obj),
                       Content => Resolved_Content);
               end;

            when Packed_Tag                                =>
               declare
                  D : constant String :=
                    Inflate_Pack_Data
                      (Data  => Data,
                       Start => Header.Data_Offset,
                       Stop  => Location.End_Offset);
               begin
                  if U64 (D'Length) /= Header.Size then
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt pack: inflated tag size mismatch";
                  end if;

                  return
                    Version.Objects.Create_Object
                      (Kind    => Version.Objects.Tag_Object,
                       Content => D);
               end;

            when Packed_Unsupported                        =>
               raise Ada.IO_Exceptions.Data_Error
                 with "unsupported packed object type";
         end case;
      end;
   end Read_Object_At_Location;
   function Read_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Version.Objects.Git_Object
   is
      Location : constant Pack_Location := Find_Location (Repo, Id);
   begin
      return Read_Object_At_Location (Repo => Repo, Location => Location);
   end Read_Object;

   subtype Indexed_Object is Version.Pack_Index.Index_Entry;
   package Indexed_Object_Vectors renames Version.Pack_Index.Entry_Vectors;

   type Scanned_Object is record
      Offset      : U64 := 0;
      End_Offset  : U64 := 0;
      Kind        : Packed_Object_Type := Packed_Unsupported;
      Size        : U64 := 0;
      Data_Offset : U64 := 0;
      Id          : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Object_Kind : Version.Objects.Object_Kind :=
        Version.Objects.Unknown_Object;
      Content     : Unbounded_String;
      Resolved    : Boolean := False;
   end record;

   package Scanned_Object_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Scanned_Object);

   function Object_Kind_Name (Kind : Version.Objects.Object_Kind) return String
   is
   begin
      case Kind is
         when Version.Objects.Blob_Object    =>
            return "blob";

         when Version.Objects.Tree_Object    =>
            return "tree";

         when Version.Objects.Commit_Object  =>
            return "commit";

         when Version.Objects.Tag_Object     =>
            return "tag";

         when Version.Objects.Unknown_Object =>
            raise Ada.IO_Exceptions.Data_Error
              with "cannot hash unknown packed object kind";
      end case;
   end Object_Kind_Name;

   function Object_Id_For
     (Kind      : Version.Objects.Object_Kind; Content : String;
      Algorithm : Version.Hash.Hash_Algorithm)
      return Version.Objects.Hex_Object_Id
   is
      Header    : constant String :=
        Object_Kind_Name (Kind) & " " & Natural'Image (Content'Length);
      --  Natural'Image has a leading space; remove it explicitly below.
      Len_Image : constant String := Natural'Image (Content'Length);
      Canonical : constant String :=
        Object_Kind_Name (Kind)
        & " "
        & Len_Image (Len_Image'First + 1 .. Len_Image'Last)
        & Character'Val (0)
        & Content;
      pragma Unreferenced (Header);
   begin
      return Version.Objects.To_Object_Id
        (Version.Hash.Object_Hash_Hex (Algorithm, Canonical));
   end Object_Id_For;

   function CRC32
     (Data : Stream_Element_Array; First : U64; Last : U64) return U32
   is
      C : U32 := 16#FFFF_FFFF#;
   begin
      if Last < First then
         return 0;
      end if;

      for Pos in First .. Last loop
         C := C xor U32 (Byte_At (Data, Pos));

         for Bit in 1 .. 8 loop
            if (C and 1) /= 0 then
               C := Shift_Right (C, 1) xor 16#EDB8_8320#;
            else
               C := Shift_Right (C, 1);
            end if;
         end loop;
      end loop;

      return not C;
   end CRC32;

   function Pack_Trailing_Checksum
     (Data : Stream_Element_Array; Raw_Length : Natural) return String
   is
      Result : String (1 .. Raw_Length);
      First  : constant Stream_Element_Offset :=
        Data'Last - Stream_Element_Offset (Raw_Length) + 1;
      Outpos : Natural := Result'First;
   begin
      if Data'Length < Raw_Length then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: missing checksum";
      end if;

      for I in First .. Data'Last loop
         Result (Outpos) := Character'Val (Data (I));
         Outpos := Outpos + 1;
      end loop;

      return Result;
   end Pack_Trailing_Checksum;

   function To_String
     (Data  : Stream_Element_Array;
      First : Stream_Element_Offset;
      Last  : Stream_Element_Offset) return String
   is
      Result : String (1 .. Natural (Last - First + 1));
      Outpos : Natural := Result'First;
   begin
      if First > Last then
         return "";
      end if;

      for I in First .. Last loop
         Result (Outpos) := Character'Val (Data (I));
         Outpos := Outpos + 1;
      end loop;

      return Result;
   end To_String;

   procedure Require_Valid_Pack_Checksum
     (Data      : Stream_Element_Array;
      Algorithm : Version.Hash.Hash_Algorithm)
   is
      Raw_Length : constant Natural := Version.Hash.Raw_Length (Algorithm);
      Body_Last  : constant Stream_Element_Offset :=
        Data'Last - Stream_Element_Offset (Raw_Length);
      Expected   : constant String :=
        Version.Hash.Object_Hash_Raw
          (Algorithm, To_String (Data, Data'First, Body_Last));
      Actual     : constant String :=
        Pack_Trailing_Checksum (Data, Raw_Length);
   begin
      if Actual /= Expected then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: checksum mismatch";
      end if;
   end Require_Valid_Pack_Checksum;

   function Index_Path_For (Pack_Path : String) return String is
   begin
      if Pack_Path'Length >= 5
        and then Pack_Path (Pack_Path'Last - 4 .. Pack_Path'Last) = ".pack"
      then
         return Pack_Path (Pack_Path'First .. Pack_Path'Last - 4) & "idx";
      end if;

      return Pack_Path & ".idx";
   end Index_Path_For;

   function Compressed_Data_Start
     (Data       : Stream_Element_Array; Offset : U64;
      Header     : Packed_Object_Header;
      Raw_Length : Natural)
      return U64
   is
      Pos : U64 := Header.Data_Offset;
   begin
      case Header.Kind is
         when Packed_Ref_Delta =>
            return Header.Data_Offset + U64 (Raw_Length);

         when Packed_Ofs_Delta =>
            declare
               Ignored : constant U64 :=
                 Decode_Ofs_Delta_Base_Offset
                   (Data => Data, Current_Offset => Offset, Pos => Pos);
               pragma Unreferenced (Ignored);
            begin
               return Pos;
            end;

         when others           =>
            return Header.Data_Offset;
      end case;
   end Compressed_Data_Start;

   procedure Scan_Object_Data
     (Data       : Stream_Element_Array;
      Start      : U64;
      Expected   : U64;
      Pack_Limit : U64;
      End_Offset : out U64;
      Content    : out Unbounded_String)
   is
      --  A pack does not store the compressed length of an object, so the
      --  boundary is where its zlib stream ends. Inflate the object exactly
      --  once with a streaming inflater: the inflated bytes are returned (they
      --  are the object content for a base object, or the delta stream for a
      --  delta, and are reused by the resolve pass instead of re-inflating),
      --  and the number of input bytes consumed (including the zlib
      --  wrapper/adler32) is the compressed size. The previous byte-by-byte
      --  "try every Stop and re-inflate" search was O(pack^2) and hung on any
      --  non-trivial object.
      Filter    : Zlib.Filter_Type;
      In_First  : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Start);
      In_Limit  : constant Stream_Element_Offset :=
        Data'First + Stream_Element_Offset (Pack_Limit) - 1;
      In_Pos    : Stream_Element_Offset := In_First;
      In_Last   : Stream_Element_Offset;
      Out_Buf   : Stream_Element_Array (1 .. 65536);
      Out_Last  : Stream_Element_Offset;
      Result    : String (1 .. Natural (Expected));
      Out_Pos   : Natural := 0;
   begin
      End_Offset := 0;
      Content := Null_Unbounded_String;
      if Pack_Limit <= Start + 5 or else In_Limit > Data'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: truncated object data";
      end if;

      Zlib.Inflate_Init (Filter, Header => Zlib.Zlib_Header);
      loop
         declare
            Prev_Pos : constant Stream_Element_Offset := In_Pos;
         begin
            Zlib.Translate
              (Filter   => Filter,
               In_Data  => Data (In_Pos .. In_Limit),
               In_Last  => In_Last,
               Out_Data => Out_Buf,
               Out_Last => Out_Last,
               Flush    => Zlib.No_Flush);

            if In_Last >= In_Pos then
               In_Pos := In_Last + 1;
            end if;
            if Out_Last >= Out_Buf'First then
               declare
                  N : constant Natural :=
                    Natural (Out_Last - Out_Buf'First + 1);
               begin
                  if Out_Pos + N > Result'Length then
                     Zlib.Close (Filter, Ignore_Error => True);
                     raise Ada.IO_Exceptions.Data_Error
                       with "corrupt pack: inflated object size mismatch";
                  end if;
                  Result (Out_Pos + 1 .. Out_Pos + N) :=
                    To_String (Out_Buf, Out_Buf'First, Out_Last);
                  Out_Pos := Out_Pos + N;
               end;
            end if;

            exit when Zlib.Stream_End (Filter);

            --  No forward progress on a still-open stream means the object is
            --  truncated or corrupt; stop rather than spin.
            if In_Pos = Prev_Pos and then Out_Last < Out_Buf'First then
               Zlib.Close (Filter, Ignore_Error => True);
               raise Ada.IO_Exceptions.Data_Error
                 with
                   "corrupt pack: could not determine compressed object "
                   & "boundary";
            end if;
         end;
      end loop;
      Zlib.Close (Filter, Ignore_Error => True);

      if Out_Pos /= Natural (Expected) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: inflated object size mismatch";
      end if;

      Content := To_Unbounded_String (Result);
      End_Offset := Start + U64 (In_Pos - In_First);
   exception
      when Zlib.Zlib_Error | Zlib.Status_Error =>
         Zlib.Close (Filter, Ignore_Error => True);
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: could not inflate object to find boundary";
   end Scan_Object_Data;

   function Find_Scanned_By_Offset
     (Items : Scanned_Object_Vectors.Vector; Offset : U64) return Natural is
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Items.Element (I).Offset = Offset then
               return I;
            end if;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error
        with "corrupt pack: delta base offset not present in pack";
   end Find_Scanned_By_Offset;

   function Find_Scanned_By_Id
     (Items : Scanned_Object_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id) return Natural is
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Items.Element (I).Resolved and then Items.Element (I).Id = Id
            then
               return I;
            end if;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error
        with "corrupt pack: ref-delta base id not present in pack";
   end Find_Scanned_By_Id;

   procedure Index_Pack
     (Repo : Version.Repository.Repository_Handle; Pack_Path : String)
   is
      Data           : constant Stream_Element_Array := Read_File (Pack_Path);
      Magic          : String (1 .. 4) := [others => Character'Val (0)];
      Version_Number : U32 := 0;
      Object_Count   : Natural := 0;
      Pack_Limit     : U64 := 0;
      Objects        : Scanned_Object_Vectors.Vector;
      Indexed        : Indexed_Object_Vectors.Vector;

      Algo       : constant Version.Hash.Hash_Algorithm :=
        Version.Repository.Algorithm (Repo);
      Raw_Length : constant Natural := Version.Hash.Raw_Length (Algo);
   begin
      if Data'Length < 32 then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: missing PACK header";
      end if;

      Magic :=
        [1 => Character'Val (Data (Data'First)),
         2 => Character'Val (Data (Data'First + 1)),
         3 => Character'Val (Data (Data'First + 2)),
         4 => Character'Val (Data (Data'First + 3))];
      Version_Number := U32_BE (Data, Data'First + 4);
      Object_Count := Natural (U32_BE (Data, Data'First + 8));
      Pack_Limit := U64 (Data'Length) - U64 (Raw_Length);

      if Magic /= "PACK" then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt pack: missing PACK header";
      end if;

      if Version_Number /= 2 and then Version_Number /= 3 then
         raise Ada.IO_Exceptions.Data_Error with "unsupported pack version";
      end if;

      Require_Valid_Pack_Checksum (Data, Algo);

      declare
         Pos : U64 := 12;
      begin
         for N in 1 .. Object_Count loop
            declare
               Offset           : constant U64 := Pos;
               Location         : constant Pack_Location :=
                 (Found      => True,
                  Pack_Path  => To_Unbounded_String (Pack_Path),
                  Offset     => Offset,
                  End_Offset => Pack_Limit);
               Header           : constant Packed_Object_Header :=
                 Read_Header (Location);
               Compressed_Start : constant U64 :=
                 Compressed_Data_Start
                   (Data => Data, Offset => Offset, Header => Header,
                    Raw_Length => Raw_Length);
               End_Offset       : U64;
               Scan_Content     : Unbounded_String;
            begin
               --  Inflate the object's stream once here; the resolve pass reuses
               --  Scan_Content (object content for base objects, delta stream
               --  for deltas) instead of inflating each object a second time.
               Scan_Object_Data
                 (Data       => Data,
                  Start      => Compressed_Start,
                  Expected   => Header.Size,
                  Pack_Limit => Pack_Limit,
                  End_Offset => End_Offset,
                  Content    => Scan_Content);
               Objects.Append
                 (Scanned_Object'(Offset      => Offset,
                   End_Offset  => End_Offset,
                   Kind        => Header.Kind,
                   Size        => Header.Size,
                   Data_Offset => Header.Data_Offset,
                   Id          => Version.Objects.Zero_Object_Id,
                   Object_Kind => Version.Objects.Unknown_Object,
                   Content     => Scan_Content,
                   Resolved    => False));

               Pos := End_Offset;
            end;
         end loop;

         if Pos /= Pack_Limit then
            raise Ada.IO_Exceptions.Data_Error
              with "corrupt pack: object stream does not end at pack checksum";
         end if;
      end;

      --  Resolve non-delta objects first, then iterate over deltas until no
      --  additional object can be resolved. Ofs-delta bases are normally
      --  earlier in the same pack; ref-delta bases may be either in-pack or
      --  already present in the repository for thin packs.
      if not Objects.Is_Empty then
         for I in Objects.First_Index .. Objects.Last_Index loop
            declare
               Obj : Scanned_Object := Objects.Element (I);
            begin
               if Obj.Kind in Packed_Commit | Packed_Tree | Packed_Blob | Packed_Tag then
                  declare
                     --  Obj.Content already holds the inflated object bytes from
                     --  the scan pass (size validated there); no re-inflate.
                     Content : constant String := To_String (Obj.Content);
                     Kind    : constant Version.Objects.Object_Kind :=
                       Non_Delta_Object_Kind_For (Obj.Kind);
                  begin
                     Obj.Object_Kind := Kind;
                     Obj.Id := Object_Id_For (Kind, Content, Algo);
                     Obj.Resolved := True;
                     Objects.Replace_Element (I, Obj);
                  end;
               elsif Obj.Kind = Packed_Unsupported then
                  raise Ada.IO_Exceptions.Data_Error
                    with "unsupported packed object type";
               end if;
            end;
         end loop;
      end if;

      declare
         Progress : Boolean := True;
      begin
         while Progress loop
            Progress := False;

            if not Objects.Is_Empty then
               for I in Objects.First_Index .. Objects.Last_Index loop
                  declare
                     Obj : Scanned_Object := Objects.Element (I);
                  begin
                     if not Obj.Resolved and then Obj.Kind = Packed_Ofs_Delta
                     then
                        declare
                           Pos         : U64 := Obj.Data_Offset;
                           Base_Offset : constant U64 :=
                             Decode_Ofs_Delta_Base_Offset
                               (Data           => Data,
                                Current_Offset => Obj.Offset,
                                Pos            => Pos);
                           Base_Index  : constant Natural :=
                             Find_Scanned_By_Offset (Objects, Base_Offset);
                           Base        : constant Scanned_Object :=
                             Objects.Element (Base_Index);
                        begin
                           if Base.Resolved then
                              declare
                                 --  Obj.Content holds the delta stream inflated
                                 --  during the scan pass; no re-inflate.
                                 Delta_Data : constant String :=
                                   To_String (Obj.Content);
                                 Content    : constant String :=
                                   Apply_Delta
                                     (Base => To_String (Base.Content),
                                      D    => Delta_Data);
                              begin
                                 if U64 (Delta_Data'Length) /= Obj.Size then
                                    raise Ada.IO_Exceptions.Data_Error
                                      with "corrupt ofs-delta: inflated delta size mismatch";
                                 end if;

                                 Obj.Content := To_Unbounded_String (Content);
                                 Obj.Object_Kind := Base.Object_Kind;
                                 Obj.Id :=
                                   Object_Id_For (Base.Object_Kind, Content, Algo);
                                 Obj.Resolved := True;
                                 Objects.Replace_Element (I, Obj);
                                 Progress := True;
                              end;
                           end if;
                        end;

                     elsif not Obj.Resolved
                       and then Obj.Kind = Packed_Ref_Delta
                     then
                        declare
                           Base_Id      :
                             constant Version.Objects.Hex_Object_Id :=
                               Raw_Id_At
                                 (Data => Data, Pos => Obj.Data_Offset,
                                  Raw_Length => Raw_Length);
                           --  Obj.Content holds the delta stream inflated during
                           --  the scan pass; no re-inflate.
                           Delta_Data   : constant String :=
                             To_String (Obj.Content);
                           Base_Content : Unbounded_String;
                           Base_Kind    : Version.Objects.Object_Kind;
                           Found_Base   : Boolean := False;
                        begin
                           begin
                              declare
                                 Base_Index : constant Natural :=
                                   Find_Scanned_By_Id (Objects, Base_Id);
                                 Base       : constant Scanned_Object :=
                                   Objects.Element (Base_Index);
                              begin
                                 Base_Content := Base.Content;
                                 Base_Kind := Base.Object_Kind;
                                 Found_Base := True;
                              end;
                           exception
                              when Ada.IO_Exceptions.Data_Error =>
                                 declare
                                    Base_Obj :
                                      constant Version.Objects.Git_Object :=
                                        Version.Objects.Read_Object
                                          (Repo, Base_Id);
                                 begin
                                    Base_Content :=
                                      To_Unbounded_String
                                        (Version.Objects.Content (Base_Obj));
                                    Base_Kind :=
                                      Version.Objects.Kind (Base_Obj);
                                    Found_Base := True;
                                 end;
                           end;

                           if Found_Base then
                              declare
                                 Content : constant String :=
                                   Apply_Delta
                                     (Base => To_String (Base_Content),
                                      D    => Delta_Data);
                              begin
                                 if U64 (Delta_Data'Length) /= Obj.Size then
                                    raise Ada.IO_Exceptions.Data_Error
                                      with "corrupt ref-delta: inflated delta size mismatch";
                                 end if;

                                 Obj.Content := To_Unbounded_String (Content);
                                 Obj.Object_Kind := Base_Kind;
                                 Obj.Id := Object_Id_For (Base_Kind, Content, Algo);
                                 Obj.Resolved := True;
                                 Objects.Replace_Element (I, Obj);
                                 Progress := True;
                              end;
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end if;
         end loop;
      end;

      if not Objects.Is_Empty then
         for I in Objects.First_Index .. Objects.Last_Index loop
            declare
               Obj : constant Scanned_Object := Objects.Element (I);
            begin
               if not Obj.Resolved then
                  raise Ada.IO_Exceptions.Data_Error
                    with "could not resolve all objects in fetched pack";
               end if;

               Indexed.Append
                 (Indexed_Object'(Id     => Obj.Id,
                   Offset => Obj.Offset,
                   Crc    => CRC32 (Data, Obj.Offset, Obj.End_Offset - 1)));
            end;
         end loop;
      end if;

      Version.Files.Write_Binary_File
        (Path    => Index_Path_For (Pack_Path),
         Content =>
           Version.Pack_Index.Build
             (Entries       => Indexed,
              Pack_Checksum => Pack_Trailing_Checksum (Data, Raw_Length),
              Algorithm     => Version.Repository.Algorithm (Repo)));
   end Index_Pack;
end Version.Pack;
