with Ada.Containers;
with Ada.IO_Exceptions;

package body Version.Pkt_Line is

   use type Ada.Containers.Count_Type;
   use type Ada.Streams.Stream_Element_Offset;

   function Hex_Value
     (Byte : Ada.Streams.Stream_Element)
      return Integer
   is
      Zero  : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('0'));
      Nine  : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('9'));
      Lower : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('a'));
      Upper : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('f'));
      Cap_A : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('A'));
      Cap_F : constant Ada.Streams.Stream_Element :=
        Ada.Streams.Stream_Element (Character'Pos ('F'));
   begin
      if Byte >= Zero and then Byte <= Nine then
         return Integer (Byte - Zero);
      elsif Byte >= Lower and then Byte <= Upper then
         return Integer (Byte - Lower) + 10;
      elsif Byte >= Cap_A and then Byte <= Cap_F then
         return Integer (Byte - Cap_A) + 10;
      else
         return -1;
      end if;
   end Hex_Value;

   function Header_Length
     (Item : Parser)
      return Integer
   is
      Result : Integer := 0;
      Digit  : Integer;
   begin
      for Index in 0 .. 3 loop
         Digit := Hex_Value (Item.Buffer.Element (Index));

         if Digit < 0 then
            return -1;
         end if;

         Result := Result * 16 + Digit;
      end loop;

      return Result;
   end Header_Length;

   function Header_Byte
     (Value : Natural)
      return Ada.Streams.Stream_Element
   is
   begin
      if Value < 10 then
         return Ada.Streams.Stream_Element (Character'Pos ('0') + Value);
      else
         return Ada.Streams.Stream_Element (Character'Pos ('a') + Value - 10);
      end if;
   end Header_Byte;

   function Encode_Special
     (Code : String)
      return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array (1 .. 4);
   begin
      for I in Code'Range loop
         Result (Ada.Streams.Stream_Element_Offset (I - Code'First + 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Code (I)));
      end loop;

      return Result;
   end Encode_Special;

   procedure Reset
     (Item : in out Parser)
   is
   begin
      Item.Buffer.Clear;
   end Reset;

   procedure Feed
     (Item : in out Parser;
      Data : Ada.Streams.Stream_Element_Array)
   is
   begin
      for I in Data'Range loop
         Item.Buffer.Append (Data (I));
      end loop;
   end Feed;

   function Next
     (Item            : in out Parser;
      Kind            : out Packet_Kind;
      Payload         : out Ada.Streams.Stream_Element_Array;
      Last            : out Ada.Streams.Stream_Element_Offset;
      Max_Packet_Size : Natural := 65_520)
      return Parse_Status
   is
      Length         : Integer;
      Payload_Length : Natural;
      Target         : Ada.Streams.Stream_Element_Offset;
   begin
      Kind := Flush_Packet;
      Last := Payload'First - 1;

      if Item.Buffer.Length < 4 then
         return Need_More_Data;
      end if;

      Length := Header_Length (Item);

      if Length < 0 then
         return Malformed_Input;
      end if;

      case Length is
         when 0 =>
            Item.Buffer.Delete_First (4);
            Kind := Flush_Packet;
            return Ok;
         when 1 =>
            Item.Buffer.Delete_First (4);
            Kind := Delimiter_Packet;
            return Ok;
         when 2 =>
            Item.Buffer.Delete_First (4);
            Kind := Response_End_Packet;
            return Ok;
         when 3 =>
            return Malformed_Input;
         when others =>
            null;
      end case;

      if Length > Max_Packet_Size then
         return Packet_Too_Large;
      end if;

      if Item.Buffer.Length < Ada.Containers.Count_Type (Length) then
         return Need_More_Data;
      end if;

      Payload_Length := Natural (Length - 4);

      if Payload_Length > Payload'Length then
         return Output_Buffer_Too_Small;
      end if;

      Target := Payload'First;
      for Source in 4 .. Length - 1 loop
         Payload (Target) := Item.Buffer.Element (Source);
         Target := Target + 1;
      end loop;

      if Payload_Length = 0 then
         Last := Payload'First - 1;
      else
         Last := Payload'First + Ada.Streams.Stream_Element_Offset (Payload_Length) - 1;
      end if;

      Item.Buffer.Delete_First (Ada.Containers.Count_Type (Length));
      Kind := Data_Packet;
      return Ok;
   end Next;

   function Encode_Data
     (Payload : Ada.Streams.Stream_Element_Array)
      return Ada.Streams.Stream_Element_Array
   is
      Length : constant Natural := Natural (Payload'Length) + 4;
   begin
      if Length > 16#FFFF# then
         raise Ada.IO_Exceptions.Data_Error
           with "pkt-line data packet exceeds 16-bit length field";
      end if;

      declare
         Result : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Length));
         Target : Ada.Streams.Stream_Element_Offset := 5;
      begin
         Result (1) := Header_Byte ((Length / 16#1000#) mod 16);
         Result (2) := Header_Byte ((Length / 16#0100#) mod 16);
         Result (3) := Header_Byte ((Length / 16#0010#) mod 16);
         Result (4) := Header_Byte (Length mod 16);

         for I in Payload'Range loop
            Result (Target) := Payload (I);
            Target := Target + 1;
         end loop;

         return Result;
      end;
   end Encode_Data;

   function Encode_Flush
      return Ada.Streams.Stream_Element_Array
   is
   begin
      return Encode_Special ("0000");
   end Encode_Flush;

   function Encode_Delimiter
      return Ada.Streams.Stream_Element_Array
   is
   begin
      return Encode_Special ("0001");
   end Encode_Delimiter;

   function Encode_Response_End
      return Ada.Streams.Stream_Element_Array
   is
   begin
      return Encode_Special ("0002");
   end Encode_Response_End;

end Version.Pkt_Line;
