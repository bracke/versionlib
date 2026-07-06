with Ada.Containers.Vectors;
with Ada.Streams;

package Version.Pkt_Line is

   type Packet_Kind is
     (Data_Packet,
      Flush_Packet,
      Delimiter_Packet,
      Response_End_Packet);

   type Parse_Status is
     (Ok,
      Need_More_Data,
      Malformed_Input,
      Packet_Too_Large,
      Output_Buffer_Too_Small);

   type Parser is private;

   procedure Reset
     (Item : in out Parser);

   procedure Feed
     (Item : in out Parser;
      Data : Ada.Streams.Stream_Element_Array);

   function Next
     (Item            : in out Parser;
      Kind            : out Packet_Kind;
      Payload         : out Ada.Streams.Stream_Element_Array;
      Last            : out Ada.Streams.Stream_Element_Offset;
      Max_Packet_Size : Natural := 65_520)
      return Parse_Status;

   function Encode_Data
     (Payload : Ada.Streams.Stream_Element_Array)
      return Ada.Streams.Stream_Element_Array;

   function Encode_Flush
      return Ada.Streams.Stream_Element_Array;

   function Encode_Delimiter
      return Ada.Streams.Stream_Element_Array;

   function Encode_Response_End
      return Ada.Streams.Stream_Element_Array;

private

   use type Ada.Streams.Stream_Element;

   package Byte_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Ada.Streams.Stream_Element);

   type Parser is record
      Buffer : Byte_Vectors.Vector;
   end record;

end Version.Pkt_Line;
