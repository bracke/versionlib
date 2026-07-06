with Ada.Streams;
with Ada.IO_Exceptions;
with Ada.Exceptions;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Transport.Http;

package body Version.Pkt_Line.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Streams;

   LF  : constant Character := Character'Val (10);
   CR  : constant Character := Character'Val (13);
   NUL : constant Character := Character'Val (0);

   type Pkt_Line_Consumer is
     new Version.Transport.Http.Byte_Consumer with record
      Parser : Version.Pkt_Line.Parser;
   end record;

   overriding procedure Consume
     (Item : in out Pkt_Line_Consumer;
      Data : Stream_Element_Array)
   is
   begin
      Version.Pkt_Line.Feed (Item.Parser, Data);
   end Consume;

   function To_Stream
     (Text : String)
      return Stream_Element_Array
   is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Text'Length));
      J : Stream_Element_Offset := Result'First;
   begin
      for I in Text'Range loop
         Result (J) := Stream_Element (Character'Pos (Text (I)));
         J := J + 1;
      end loop;

      return Result;
   end To_Stream;

   function To_String
     (Data : Stream_Element_Array)
      return String
   is
      Result : String (1 .. Natural (Data'Length));
      J      : Natural := Result'First;
   begin
      for I in Data'Range loop
         Result (J) := Character'Val (Data (I));
         J := J + 1;
      end loop;

      return Result;
   end To_String;

   procedure Assert_No_Payload
     (Buffer : Stream_Element_Array;
      Last   : Stream_Element_Offset;
      Label  : String)
   is
   begin
      Assert (Last < Buffer'First, Label & " must not expose a payload");
   end Assert_No_Payload;

   procedure Assert_Stream_Equals
     (Actual   : Stream_Element_Array;
      Expected : Stream_Element_Array;
      Label    : String)
   is
   begin
      Assert
        (Actual'Length = Expected'Length,
         Label & " length mismatch: expected"
         & Stream_Element_Offset'Image (Stream_Element_Offset (Expected'Length))
         & " got"
         & Stream_Element_Offset'Image (Stream_Element_Offset (Actual'Length)));

      for I in Expected'Range loop
         Assert
           (Actual (Actual'First + (I - Expected'First)) = Expected (I),
            Label & " byte mismatch at offset"
            & Stream_Element_Offset'Image (I - Expected'First));
      end loop;
   end Assert_Stream_Equals;

   procedure Parse_Flush
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0000"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "flush packet should parse");
      Assert (Kind = Version.Pkt_Line.Flush_Packet, "kind should be flush");
      Assert_No_Payload (Payload, Last, "flush packet");
   end Parse_Flush;

   procedure Parse_Delimiter
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0001"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "delimiter packet should parse");
      Assert (Kind = Version.Pkt_Line.Delimiter_Packet, "kind should be delimiter");
      Assert_No_Payload (Payload, Last, "delimiter packet");
   end Parse_Delimiter;

   procedure Parse_Response_End
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0002"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "response-end packet should parse");
      Assert (Kind = Version.Pkt_Line.Response_End_Packet, "kind should be response-end");
      Assert_No_Payload (Payload, Last, "response-end packet");
   end Parse_Response_End;

   procedure Parse_Data_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0008NAK" & LF));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "data packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "kind should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "NAK" & LF,
              "payload should be preserved exactly");
   end Parse_Data_Packet;

   procedure Parse_Empty_Data_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0004"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "empty data packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet,
              "empty data packet should still be data");
      Assert_No_Payload (Payload, Last, "empty data packet");
   end Parse_Empty_Data_Packet;

   procedure Parse_Multiple_Packets_In_One_Feed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0008NAK" & LF & "0000"));

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "first packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "first packet should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "NAK" & LF,
              "first payload should match");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "second packet should parse");
      Assert (Kind = Version.Pkt_Line.Flush_Packet, "second packet should be flush");
   end Parse_Multiple_Packets_In_One_Feed;

   procedure Parse_Split_Header
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("00"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Need_More_Data,
              "split header should need more data");

      Version.Pkt_Line.Feed (Parser, To_Stream ("08NAK" & LF));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "completed split header should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "split header packet should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "NAK" & LF,
              "split header payload should match");
   end Parse_Split_Header;

   procedure Parse_Split_Payload
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0008NA"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Need_More_Data,
              "split payload should need more data");

      Version.Pkt_Line.Feed (Parser, To_Stream ("K" & LF));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "completed split payload should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "split payload packet should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "NAK" & LF,
              "split payload should match");
   end Parse_Split_Payload;

   procedure Preserve_Binary_Payload
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Binary : constant Stream_Element_Array :=
        [1 => Stream_Element (Character'Pos (NUL)),
         2 => Stream_Element (Character'Pos (LF)),
         3 => Stream_Element (Character'Pos (CR)),
         4 => Stream_Element (Character'Pos (CR)),
         5 => Stream_Element (Character'Pos (LF)),
         6 => 16#80#,
         7 => 16#FF#];
      Encoded : constant Stream_Element_Array := Version.Pkt_Line.Encode_Data (Binary);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Encoded);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "binary packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "binary packet should be data");
      Assert_Stream_Equals
        (Payload (Payload'First .. Last), Binary, "binary payload");
   end Preserve_Binary_Payload;

   procedure Reject_Invalid_Hex_Header
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("00xz"));
      Assert
        (Version.Pkt_Line.Next (Parser, Kind, Payload, Last)
         = Version.Pkt_Line.Malformed_Input,
         "invalid hex header must be rejected deterministically");
   end Reject_Invalid_Hex_Header;

   procedure Reject_Reserved_0003
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0003"));
      Assert
        (Version.Pkt_Line.Next (Parser, Kind, Payload, Last)
         = Version.Pkt_Line.Malformed_Input,
         "reserved 0003 packet must be rejected");
   end Reject_Reserved_0003;

   procedure Reject_Too_Large_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0010abcdefghijkl"));
      Assert
        (Version.Pkt_Line.Next
           (Parser, Kind, Payload, Last, Max_Packet_Size => 8)
         = Version.Pkt_Line.Packet_Too_Large,
         "packet exceeding configured maximum must be rejected");
   end Reject_Too_Large_Packet;

   procedure Reject_Output_Buffer_Too_Small
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 2);
      Last    : Stream_Element_Offset;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0008NAK" & LF));
      Assert
        (Version.Pkt_Line.Next (Parser, Kind, Payload, Last)
         = Version.Pkt_Line.Output_Buffer_Too_Small,
         "undersized caller payload buffer must be reported explicitly");
   end Reject_Output_Buffer_Too_Small;

   procedure Output_Buffer_Too_Small_Does_Not_Consume
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Small   : Stream_Element_Array (1 .. 2);
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("0008NAK" & LF));

      Status := Version.Pkt_Line.Next (Parser, Kind, Small, Last);
      Assert (Status = Version.Pkt_Line.Output_Buffer_Too_Small,
              "small output buffer should not consume packet");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok,
              "packet should parse after retry with larger buffer");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "retried packet should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "NAK" & LF,
              "retried packet payload should match");
   end Output_Buffer_Too_Small_Does_Not_Consume;

   procedure Reset_Clears_Buffer
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 16);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, To_Stream ("00xz"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Malformed_Input,
              "malformed header should be reported before reset");

      Version.Pkt_Line.Reset (Parser);
      Version.Pkt_Line.Feed (Parser, To_Stream ("0000"));
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "parser should recover after reset");
      Assert (Kind = Version.Pkt_Line.Flush_Packet,
              "parser should read new packet after reset");
   end Reset_Clears_Buffer;

   procedure Encode_Flush_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Stream_Equals
        (Version.Pkt_Line.Encode_Flush,
         To_Stream ("0000"),
         "encoded flush");
   end Encode_Flush_Packet;

   procedure Encode_Delimiter_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Stream_Equals
        (Version.Pkt_Line.Encode_Delimiter,
         To_Stream ("0001"),
         "encoded delimiter");
   end Encode_Delimiter_Packet;

   procedure Encode_Response_End_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Stream_Equals
        (Version.Pkt_Line.Encode_Response_End,
         To_Stream ("0002"),
         "encoded response-end");
   end Encode_Response_End_Packet;

   procedure Encode_Data_Packet
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Stream_Equals
        (Version.Pkt_Line.Encode_Data (To_Stream ("NAK" & LF)),
         To_Stream ("0008NAK" & LF),
         "encoded data packet");
   end Encode_Data_Packet;

   procedure Encode_Binary_Payload
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Binary : constant Stream_Element_Array :=
        [1 => Stream_Element (Character'Pos (NUL)),
         2 => Stream_Element (Character'Pos (LF)),
         3 => Stream_Element (Character'Pos (CR)),
         4 => 16#80#,
         5 => 16#FF#];
      Expected : constant Stream_Element_Array :=
        To_Stream ("0009") & Binary;
   begin
      Assert_Stream_Equals
        (Version.Pkt_Line.Encode_Data (Binary),
         Expected,
         "encoded binary packet");
   end Encode_Binary_Payload;

   procedure Reject_Oversized_Encode_Data
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Payload : constant Stream_Element_Array (1 .. 65_532) := [others => 0];
      Raised  : Boolean := False;
   begin
      begin
         declare
            Ignored : constant Stream_Element_Array :=
              Version.Pkt_Line.Encode_Data (Payload);
         begin
            pragma Unreferenced (Ignored);
         end;
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "pkt-line data packet exceeds 16-bit length field",
               "oversized pkt-line encode diagnostic must remain stable");
      end;

      Assert (Raised, "oversized pkt-line encode must raise Data_Error");
   end Reject_Oversized_Encode_Data;

   procedure Parse_Smart_Http_Discovery_Fixture
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Oid : constant String := "0123456789abcdef0123456789abcdef01234567";
      Service_Payload : constant Stream_Element_Array :=
        To_Stream ("# service=git-upload-pack" & LF);
      Ref_Payload : constant Stream_Element_Array :=
        To_Stream
          (Oid & " HEAD" & NUL
           & "multi_ack thin-pack side-band side-band-64k ofs-delta" & LF);
      Stream : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (Service_Payload)
        & Version.Pkt_Line.Encode_Flush
        & Version.Pkt_Line.Encode_Data (Ref_Payload)
        & Version.Pkt_Line.Encode_Flush;
      Consumer : Pkt_Line_Consumer;
      Kind     : Version.Pkt_Line.Packet_Kind;
      Payload  : Stream_Element_Array (1 .. 256);
      Last     : Stream_Element_Offset;
      Status   : Version.Pkt_Line.Parse_Status;
      Cut      : constant Stream_Element_Offset := Stream'First + 12;
   begin
      Consume (Consumer, Stream (Stream'First .. Cut));
      Consume (Consumer, Stream (Cut + 1 .. Stream'Last));

      Status := Version.Pkt_Line.Next (Consumer.Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "service advertisement should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "service packet should be data");
      Assert_Stream_Equals
        (Payload (Payload'First .. Last),
         Service_Payload,
         "service advertisement payload");

      Status := Version.Pkt_Line.Next (Consumer.Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "first flush should parse");
      Assert (Kind = Version.Pkt_Line.Flush_Packet, "first flush kind mismatch");

      Status := Version.Pkt_Line.Next (Consumer.Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "ref advertisement should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "ref packet should be data");
      Assert_Stream_Equals
        (Payload (Payload'First .. Last),
         Ref_Payload,
         "ref advertisement payload");

      Status := Version.Pkt_Line.Next (Consumer.Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "final flush should parse");
      Assert (Kind = Version.Pkt_Line.Flush_Packet, "final flush kind mismatch");

      Status := Version.Pkt_Line.Next (Consumer.Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Need_More_Data,
              "parser should be empty after discovery fixture");
   end Parse_Smart_Http_Discovery_Fixture;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine (T, Parse_Flush'Access, "PktLine: parse flush");
      Register_Routine (T, Parse_Delimiter'Access, "PktLine: parse delimiter");
      Register_Routine (T, Parse_Response_End'Access, "PktLine: parse response end");
      Register_Routine (T, Parse_Data_Packet'Access, "PktLine: parse data packet");
      Register_Routine (T, Parse_Empty_Data_Packet'Access,
                        "PktLine: parse empty data packet");
      Register_Routine (T, Parse_Multiple_Packets_In_One_Feed'Access,
                        "PktLine: parse multiple packets in one feed");
      Register_Routine (T, Parse_Split_Header'Access, "PktLine: parse split header");
      Register_Routine (T, Parse_Split_Payload'Access, "PktLine: parse split payload");
      Register_Routine (T, Preserve_Binary_Payload'Access, "PktLine: preserve binary payload");
      Register_Routine (T, Reject_Invalid_Hex_Header'Access,
                        "PktLine: reject invalid hex header");
      Register_Routine (T, Reject_Reserved_0003'Access, "PktLine: reject 0003");
      Register_Routine (T, Reject_Too_Large_Packet'Access,
                        "PktLine: reject too large packet");
      Register_Routine (T, Reject_Output_Buffer_Too_Small'Access,
                        "PktLine: reject undersized output buffer");
      Register_Routine (T, Output_Buffer_Too_Small_Does_Not_Consume'Access,
                        "PktLine: undersized output buffer does not consume");
      Register_Routine (T, Reset_Clears_Buffer'Access,
                        "PktLine: reset clears buffered input");
      Register_Routine (T, Encode_Flush_Packet'Access, "PktLine: encode flush");
      Register_Routine (T, Encode_Delimiter_Packet'Access, "PktLine: encode delimiter");
      Register_Routine (T, Encode_Response_End_Packet'Access,
                        "PktLine: encode response end");
      Register_Routine (T, Encode_Data_Packet'Access, "PktLine: encode data packet");
      Register_Routine (T, Encode_Binary_Payload'Access, "PktLine: encode binary payload");
      Register_Routine (T, Reject_Oversized_Encode_Data'Access,
                        "PktLine: reject oversized encode data");
      Register_Routine (T, Parse_Smart_Http_Discovery_Fixture'Access,
                        "PktLine: parse smart HTTP discovery fixture");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Pkt_Line");
   end Name;

end Version.Pkt_Line.Tests;
