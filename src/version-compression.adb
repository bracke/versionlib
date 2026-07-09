with Ada.IO_Exceptions;
with Zlib;

package body Version.Compression is

   use Zlib;

   function To_Byte_Array
     (Input : String)
      return Zlib.Byte_Array
   is
      Result : Zlib.Byte_Array (1 .. Input'Length);
   begin
      for I in Input'Range loop
         Result (I - Input'First + 1) :=
           Zlib.Byte (Character'Pos (Input (I)));
      end loop;

      return Result;
   end To_Byte_Array;

   function To_String
     (Input : Zlib.Byte_Array)
      return String
   is
      Result : String (1 .. Input'Length);
   begin
      for I in Input'Range loop
         Result (I - Input'First + 1) :=
           Character'Val (Input (I));
      end loop;

      return Result;
   end To_String;

   function Inflate_Zlib
     (Input : String)
      return String
   is
      Status : Zlib.Status_Code;
      Output : constant Zlib.Byte_Array :=
        Zlib.Inflate
          (Input  => To_Byte_Array (Input),
           Status => Status);
   begin
      if Status /= Zlib.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           "zlib inflate failed: " & Zlib.Status_Image (Status);
      end if;

      return To_String (Output);
   end Inflate_Zlib;

   function Deflate_Zlib
     (Input : String)
      return String
   is
      Status : Zlib.Status_Code;
      Output : constant Zlib.Byte_Array :=
        Zlib.Deflate_Stored
          (Input  => To_Byte_Array (Input),
           Status => Status);
   begin
      if Status /= Zlib.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           "zlib deflate failed: " & Zlib.Status_Image (Status);
      end if;

      return To_String (Output);
   end Deflate_Zlib;

   function Gzip
     (Input : String)
      return String
   is
      Status : Zlib.Status_Code;
      Output : constant Zlib.Byte_Array :=
        Zlib.GZip
          (Input  => To_Byte_Array (Input),
           Status => Status);
   begin
      if Status /= Zlib.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           "gzip compression failed: " & Zlib.Status_Image (Status);
      end if;

      return To_String (Output);
   end Gzip;

end Version.Compression;
