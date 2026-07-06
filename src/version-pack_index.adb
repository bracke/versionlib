with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

package body Version.Pack_Index is
   use Version.Objects;

   use Ada.Strings.Unbounded;
   use Interfaces;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   Max_Normal_Offset : constant U64 := 16#7FFF_FFFF#;

   function Byte (Value : Natural) return Character is
   begin
      return Character'Val (Value);
   end Byte;

   function U32_BE (Value : U32) return String is
      Result : String (1 .. 4);
   begin
      Result (1) := Byte (Natural (Shift_Right (Value, 24) and 16#FF#));
      Result (2) := Byte (Natural (Shift_Right (Value, 16) and 16#FF#));
      Result (3) := Byte (Natural (Shift_Right (Value, 8) and 16#FF#));
      Result (4) := Byte (Natural (Value and 16#FF#));
      return Result;
   end U32_BE;

   function U64_BE (Value : U64) return String is
      Result : String (1 .. 8);
      V      : U64 := Value;
   begin
      for I in reverse Result'Range loop
         Result (I) := Byte (Natural (V and 16#FF#));
         V := Shift_Right (V, 8);
      end loop;

      return Result;
   end U64_BE;

   function Id_First_Byte (Id : Version.Objects.Hex_Object_Id) return Natural is
      Raw : constant String := To_Raw (Id);
   begin
      return Character'Pos (Raw (Raw'First));
   end Id_First_Byte;

   function Sorted_Entries (Entries : Entry_Vectors.Vector) return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector := Entries;

      function Before (Left, Right : Index_Entry) return Boolean is
      begin
         return Left.Id < Right.Id;
      end Before;

      package Sorting is new Entry_Vectors.Generic_Sorting ("<" => Before);
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted_Entries;

   function Build
     (Entries       : Entry_Vectors.Vector;
      Pack_Checksum : String;
      Algorithm     : Version.Hash.Hash_Algorithm := Version.Hash.Sha1)
      return String
   is
      Raw_Length    : constant Natural := Version.Hash.Raw_Length (Algorithm);
      Sorted        : constant Entry_Vectors.Vector := Sorted_Entries (Entries);
      Payload       : Unbounded_String;
      Large_Offsets : Unbounded_String;
      Fanout        : array (Natural range 0 .. 255) of Natural := [others => 0];
      Large_Index   : U32 := 0;
   begin
      if Pack_Checksum'Length /= Raw_Length then
         raise Ada.IO_Exceptions.Data_Error
           with "pack checksum width does not match object format";
      end if;

      if not Sorted.Is_Empty then
         for I in Sorted.First_Index .. Sorted.Last_Index loop
            declare
               First_Byte : constant Natural := Id_First_Byte (Sorted.Element (I).Id);
            begin
               for B in First_Byte .. 255 loop
                  Fanout (B) := Fanout (B) + 1;
               end loop;
            end;
         end loop;
      end if;

      Append (Payload, U32_BE (16#FF74_4F63#));
      Append (Payload, U32_BE (2));

      for B in Fanout'Range loop
         Append (Payload, U32_BE (U32 (Fanout (B))));
      end loop;

      if not Sorted.Is_Empty then
         for Obj of Sorted loop
            Append (Payload, To_Raw (Obj.Id));
         end loop;

         for Obj of Sorted loop
            Append (Payload, U32_BE (Obj.Crc));
         end loop;

         for Obj of Sorted loop
            if Obj.Offset <= Max_Normal_Offset then
               Append (Payload, U32_BE (U32 (Obj.Offset)));
            else
               Append (Payload, U32_BE (16#8000_0000# or Large_Index));
               Append (Large_Offsets, U64_BE (Obj.Offset));
               Large_Index := Large_Index + 1;
            end if;
         end loop;
      end if;

      Append (Payload, To_String (Large_Offsets));
      Append (Payload, Pack_Checksum);

      declare
         Without_Checksum : constant String := To_String (Payload);
      begin
         return Without_Checksum
           & Version.Hash.Object_Hash_Raw (Algorithm, Without_Checksum);
      end;
   end Build;

end Version.Pack_Index;
