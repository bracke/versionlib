with Ada.Containers;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Interfaces;

with Version.Compression;
with Version.Files;
with Version.Hash;
with Version.Object_Cache;
with Version.Pack_Index;

package body Version.Pack_Write is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use Interfaces;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   subtype Packed_Object_Info is Version.Pack_Index.Index_Entry;
   package Packed_Object_Info_Vectors renames Version.Pack_Index.Entry_Vectors;

   function Byte (Value : Natural) return Character is
   begin
      return Character'Val (Value);
   end Byte;

   function U32_BE (Value : U32) return String is
      Result : String (1 .. 4);
   begin
      Result (1) := Byte (Natural (Interfaces.Shift_Right (Value, 24) and 16#FF#));
      Result (2) := Byte (Natural (Interfaces.Shift_Right (Value, 16) and 16#FF#));
      Result (3) := Byte (Natural (Interfaces.Shift_Right (Value, 8) and 16#FF#));
      Result (4) := Byte (Natural (Value and 16#FF#));
      return Result;
   end U32_BE;

   function Decimal_Image (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal_Image;

   procedure Ensure_Parent_Directory (Path : String) is
   begin
      Version.Files.Create_Parent_Directories (Path);
   end Ensure_Parent_Directory;

   function Object_Count_Field
     (Count : Ada.Containers.Count_Type) return U32
   is
   begin
      return U32 (Count);
   end Object_Count_Field;

   procedure Write_File (Path : String; Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
      Data : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
   begin
      for I in Content'Range loop
         Data (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Content (I)));
      end loop;

      Ensure_Parent_Directory (Path);
      Ada.Streams.Stream_IO.Create
        (File,
         Ada.Streams.Stream_IO.Out_File,
         Version.Files.To_Native_Path (Path));
      Ada.Streams.Stream_IO.Write (File, Data);
      Ada.Streams.Stream_IO.Close (File);

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Write_File;

   function Object_Type_Number (Kind : Version.Objects.Object_Kind) return Natural is
   begin
      case Kind is
         when Version.Objects.Commit_Object =>
            return 1;
         when Version.Objects.Tree_Object =>
            return 2;
         when Version.Objects.Blob_Object =>
            return 3;
         when Version.Objects.Tag_Object =>
            return 4;
         when Version.Objects.Unknown_Object =>
            raise Ada.IO_Exceptions.Data_Error with
              "unsupported object kind for pack writing";
      end case;
   end Object_Type_Number;

   function Object_Kind_Name
     (Kind : Version.Objects.Object_Kind) return String
   is
   begin
      case Kind is
         when Version.Objects.Commit_Object =>
            return "commit";
         when Version.Objects.Tree_Object =>
            return "tree";
         when Version.Objects.Blob_Object =>
            return "blob";
         when Version.Objects.Tag_Object =>
            return "tag";
         when Version.Objects.Unknown_Object =>
            raise Ada.IO_Exceptions.Data_Error with
              "unsupported object kind for pack writing";
      end case;
   end Object_Kind_Name;

   function Canonical_Object_Id
     (Kind      : Version.Objects.Object_Kind;
      Payload   : String;
      Algorithm : Version.Hash.Hash_Algorithm)
      return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Object_Kind_Name (Kind)
        & " "
        & Decimal_Image (Payload'Length)
        & Character'Val (0);
   begin
      return Version.Objects.To_Object_Id
        (Version.Hash.Object_Hash_Hex (Algorithm, Header & Payload));
   end Canonical_Object_Id;

   function Encode_Object_Header
     (Kind : Version.Objects.Object_Kind;
      Size : Natural) return String
   is
      Type_Number : constant Natural := Object_Type_Number (Kind);
      Remaining   : U64 := U64 (Size) / 16;
      First       : Natural := (Type_Number * 16) + (Size mod 16);
      Result      : Unbounded_String;
   begin
      if Remaining /= 0 then
         First := First + 16#80#;
      end if;

      Append (Result, Byte (First));

      while Remaining /= 0 loop
         declare
            Part : Natural := Natural (Remaining mod 16#80#);
         begin
            Remaining := Remaining / 16#80#;

            if Remaining /= 0 then
               Part := Part + 16#80#;
            end if;

            Append (Result, Byte (Part));
         end;
      end loop;

      return To_String (Result);
   end Encode_Object_Header;

   function CRC32 (Content : String) return U32 is
      C : U32 := 16#FFFFFFFF#;
   begin
      for Ch of Content loop
         C := C xor U32 (Character'Pos (Ch));

         for Bit in 1 .. 8 loop
            if (C and 1) /= 0 then
               C := Interfaces.Shift_Right (C, 1) xor 16#EDB88320#;
            else
               C := Interfaces.Shift_Right (C, 1);
            end if;
         end loop;
      end loop;

      return C xor 16#FFFFFFFF#;
   end CRC32;

   function Sorted_Unique
     (Object_Ids : Version.Objects.Object_Id_Vectors.Vector)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result : Version.Objects.Object_Id_Vectors.Vector;
   begin
      if Object_Ids.Is_Empty then
         return Result;
      end if;

      for Id of Object_Ids loop
         if not Version.Objects.Is_Valid_Hex_Object_Id (To_String (Id)) then
            raise Ada.IO_Exceptions.Data_Error with
              "invalid object id for pack writing: " & To_String (Id);
         end if;

         declare
            Inserted : Boolean := False;
         begin
            if Result.Is_Empty then
               Result.Append (Id);
               Inserted := True;
            else
               for I in Result.First_Index .. Result.Last_Index loop
                  if Id = Result.Element (I) then
                     Inserted := True;
                     exit;
                  elsif Id < Result.Element (I) then
                     Result.Insert (Before => I, New_Item => Id);
                     Inserted := True;
                     exit;
                  end if;
               end loop;
            end if;

            if not Inserted then
               Result.Append (Id);
            end if;
         end;
      end loop;

      return Result;
   end Sorted_Unique;

   procedure Write_String
     (File    : in out Ada.Streams.Stream_IO.File_Type;
      Content : String)
   is
   begin
      if Content'Length = 0 then
         return;
      end if;

      declare
         Data : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
      begin
         for I in Content'Range loop
            Data (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (Content (I)));
         end loop;

         Ada.Streams.Stream_IO.Write (File, Data);
      end;
   end Write_String;

   procedure Write_Pack
     (Repo       : Version.Repository.Repository_Handle;
      Object_Ids : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Path  : String;
      Index_Path : String)
   is
      Sorted      : constant Version.Objects.Object_Id_Vectors.Vector := Sorted_Unique (Object_Ids);
      Infos       : Packed_Object_Info_Vectors.Vector;
      Object_Reads : Version.Object_Cache.Object_Cache;
      Pack_File   : Ada.Streams.Stream_IO.File_Type;
      Algo         : constant Version.Hash.Hash_Algorithm :=
        Version.Repository.Algorithm (Repo);
      Sha          : Version.Hash.Streaming_Context (Algo);
      Offset       : U64 := 0;

      procedure Write_Pack_Bytes (Content : String) is
      begin
         Write_String (Pack_File, Content);
         Version.Hash.Update (Sha, Content);
         Offset := Offset + U64 (Content'Length);
      end Write_Pack_Bytes;
   begin
      Ensure_Parent_Directory (Pack_Path);
      Ada.Streams.Stream_IO.Create
        (Pack_File,
         Ada.Streams.Stream_IO.Out_File,
         Version.Files.To_Native_Path (Pack_Path));

      Version.Hash.Initialize (Sha);

      Write_Pack_Bytes ("PACK");
      Write_Pack_Bytes (U32_BE (2));
      Write_Pack_Bytes (U32_BE (Object_Count_Field (Sorted.Length)));

      if not Sorted.Is_Empty then
         for Id of Sorted loop
            declare
               Obj        : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Object_Reads, Id);
               Payload    : constant String := Version.Objects.Content (Obj);
               Actual_Id  : constant Version.Objects.Hex_Object_Id :=
                 Canonical_Object_Id
                   (Version.Objects.Kind (Obj), Payload, Algo);
               Header     : constant String :=
                 Encode_Object_Header (Version.Objects.Kind (Obj), Payload'Length);
               Compressed : constant String := Version.Compression.Deflate_Zlib (Payload);
               Current_Entry      : constant String := Header & Compressed;
               Entry_Offset : constant U64 := Offset;
            begin
               if Actual_Id /= Id then
                  raise Ada.IO_Exceptions.Data_Error with
                    "object content does not match requested id: " & To_String (Id);
               end if;

               Write_Pack_Bytes (Current_Entry);
               Infos.Append
                 (Packed_Object_Info'(Id     => Id,
                   Offset => Entry_Offset,
                   Crc    => CRC32 (Current_Entry)));
            end;
         end loop;
      end if;

      declare
         Pack_Checksum : constant String := Version.Hash.Final_Raw (Sha);
         Index_Content : constant String :=
           Version.Pack_Index.Build
             (Entries       => Infos,
              Pack_Checksum => Pack_Checksum,
              Algorithm     => Version.Repository.Algorithm (Repo));
      begin
         Write_String (Pack_File, Pack_Checksum);
         Ada.Streams.Stream_IO.Close (Pack_File);
         Write_File (Index_Path, Index_Content);
      end;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (Pack_File) then
            Ada.Streams.Stream_IO.Close (Pack_File);
         end if;

         Version.Files.Delete_File_If_Exists (Pack_Path);
         Version.Files.Delete_File_If_Exists (Index_Path);
         raise;
   end Write_Pack;

end Version.Pack_Write;
