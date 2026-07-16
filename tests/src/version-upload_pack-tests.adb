with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Objects;
with Version.Pkt_Line;
with Version.Transport.Http;

package body Version.Upload_Pack.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Streams;

   use type Version.Pkt_Line.Packet_Kind;
   use type Version.Pkt_Line.Parse_Status;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

   Main_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("1111111111111111111111111111111111111111");

   Tag_Id : constant Version.Objects.Hex_Object_Id :=
     Version.Objects.To_Object_Id ("2222222222222222222222222222222222222222");

   type Collecting_Consumer is new Version.Transport.Http.Byte_Consumer with record
      Data : Stream_Element_Array (1 .. 1024) := [others => 0];
      Last : Stream_Element_Offset := 0;
   end record;

   overriding procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Stream_Element_Array)
   is
   begin
      for I in Data'Range loop
         Item.Last := Item.Last + 1;
         Item.Data (Item.Last) := Data (I);
      end loop;
   end Consume;

   function To_Stream
     (Text : String)
      return Stream_Element_Array
   is
      Result : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
      J      : Stream_Element_Offset := Result'First;
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

   function Concat
     (A : Stream_Element_Array;
      B : Stream_Element_Array)
      return Stream_Element_Array
   is
      Result : Stream_Element_Array (1 .. Stream_Element_Offset (A'Length + B'Length));
      Pos    : Stream_Element_Offset := Result'First;
   begin
      for I in A'Range loop
         Result (Pos) := A (I);
         Pos := Pos + 1;
      end loop;

      for I in B'Range loop
         Result (Pos) := B (I);
         Pos := Pos + 1;
      end loop;

      return Result;
   end Concat;

   function Advertisement_Stream
      return Stream_Element_Array
   is
      Head : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (To_String (Main_Id) & " HEAD" & NUL
              & "multi_ack side-band-64k ofs-delta symref=HEAD:refs/heads/main" & LF));
      Main : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (To_String (Main_Id) & " refs/heads/main" & LF));
      Tag : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (To_String (Tag_Id) & " refs/tags/v1" & LF));
      Flush : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
   begin
      return Concat (Concat (Concat (Head, Main), Tag), Flush);
   end Advertisement_Stream;

   function Discovery_Stream
      return Stream_Element_Array
   is
      Service : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-upload-pack" & LF));
      Flush_1 : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Head    : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (To_String (Main_Id) & " HEAD" & NUL
              & "multi_ack thin-pack side-band side-band-64k ofs-delta symref=HEAD:refs/heads/main" & LF));
      Main    : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (To_String (Main_Id) & " refs/heads/main" & LF));
      Tag     : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (To_String (Tag_Id) & " refs/tags/v1" & LF));
      Flush_2 : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
   begin
      return Concat
        (Concat
           (Concat
              (Concat
                 (Concat (Service, Flush_1),
                  Head),
               Main),
            Tag),
         Flush_2);
   end Discovery_Stream;

   procedure Parses_Discovery_Header_Refs_And_Capabilities
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Result : constant Version.Upload_Pack.Discovery_Result :=
        Version.Upload_Pack.Parse_Discovery (Discovery_Stream);
   begin
      Assert (Natural (Result.Refs.Length) = 3,
              "discovery should expose advertised refs");
      Assert (To_String (Result.Refs.Element (0).Name) = "HEAD",
              "first advertised ref should be HEAD");
      Assert (Result.Refs.Element (0).Id = Main_Id,
              "HEAD id should be preserved");
      Assert (To_String (Result.Refs.Element (1).Name) = "refs/heads/main",
              "branch ref should be parsed");
      Assert (To_String (Result.Refs.Element (2).Name) = "refs/tags/v1",
              "tag ref should be parsed");
      Assert (To_String (Result.Head_Target) = "refs/heads/main",
              "symref HEAD target should be extracted");
      Assert (Ada.Strings.Unbounded.Index (Result.Capabilities, "side-band-64k") /= 0,
              "first-ref capabilities should be preserved");
   end Parses_Discovery_Header_Refs_And_Capabilities;

   procedure Parses_Raw_Ssh_Advertisement
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Result : constant Version.Upload_Pack.Discovery_Result :=
        Version.Upload_Pack.Parse_Advertisement (Advertisement_Stream);
   begin
      Assert (Natural (Result.Refs.Length) = 3,
              "raw SSH advertisement should expose advertised refs");
      Assert (To_String (Result.Refs.Element (0).Name) = "HEAD",
              "raw SSH advertisement should start with HEAD");
      Assert (Result.Refs.Element (0).Id = Main_Id,
              "raw SSH HEAD id should be preserved");
      Assert (To_String (Result.Refs.Element (1).Name) = "refs/heads/main",
              "raw SSH branch ref should be parsed");
      Assert (To_String (Result.Head_Target) = "refs/heads/main",
              "raw SSH symref HEAD target should be extracted");
      Assert (Ada.Strings.Unbounded.Index (Result.Capabilities, "side-band-64k") /= 0,
              "raw SSH first-ref capabilities should be preserved");
   end Parses_Raw_Ssh_Advertisement;

   procedure Builds_Minimal_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Upload_Pack.Build_Want_Request (Main_Id);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "want packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "first packet should be data");
      Assert
        (To_String (Payload (Payload'First .. Last))
         = "want " & To_String (Main_Id) & " side-band-64k ofs-delta agent=version" & LF,
         "want payload should request conservative Phase 4 capabilities");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "flush should parse");
      Assert (Kind = Version.Pkt_Line.Flush_Packet, "second packet should be flush");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "done should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "third packet should be done");
      Assert (To_String (Payload (Payload'First .. Last)) = "done" & LF,
              "done payload should be emitted");
   end Builds_Minimal_Want_Request;

   procedure Builds_Include_Tag_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Upload_Pack.Build_Want_Request
          (Want_Id => Main_Id, Include_Tag => True);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "want packet should parse");
      Assert
        (To_String (Payload (Payload'First .. Last))
         = "want " & To_String (Main_Id)
           & " side-band-64k ofs-delta include-tag agent=version" & LF,
         "want payload should request include-tag when enabled");
   end Builds_Include_Tag_Want_Request;


   procedure Builds_Filtered_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Upload_Pack.Build_Want_Request
          (Want_Id     => Main_Id,
           Filter_Spec => "blob:none");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "filtered want packet should parse");
      --  The `filter` capability must be advertised in the want line, else
      --  upload-pack rejects the following `filter` command and sends no pack.
      Assert
        (To_String (Payload (Payload'First .. Last))
         = "want " & To_String (Main_Id)
           & " side-band-64k ofs-delta filter agent=version" & LF,
         "filtered want line must advertise the filter capability");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "filter packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet,
              "filter packet should be data");
      Assert (To_String (Payload (Payload'First .. Last))
              = "filter blob:none" & LF,
              "filtered request should ask for blob:none");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "flush should parse after filter");
      Assert (Kind = Version.Pkt_Line.Flush_Packet,
              "filtered request should flush after filter");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "done should parse after filter");
      Assert (To_String (Payload (Payload'First .. Last)) = "done" & LF,
              "filtered request should end with done");
   end Builds_Filtered_Want_Request;

   procedure Builds_Arbitrary_Filtered_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Upload_Pack.Build_Want_Request
          (Want_Id     => Main_Id,
           Filter_Spec => "blob:limit=1024");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "want should parse");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "filter packet should parse");
      Assert
        (To_String (Payload (Payload'First .. Last))
         = "filter blob:limit=1024" & LF,
         "an arbitrary filter spec must be emitted verbatim");
   end Builds_Arbitrary_Filtered_Want_Request;

   procedure Demuxes_Nak_And_Sideband_Pack_Data
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Nak  : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream ("NAK" & LF));
      Ack  : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("ACK " & To_String (Main_Id) & " ready" & LF));
      Pack : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          ([1 => 1,
            2 => Stream_Element (Character'Pos ('P')),
            3 => Stream_Element (Character'Pos ('A')),
            4 => Stream_Element (Character'Pos ('C')),
            5 => Stream_Element (Character'Pos ('K'))]);
      Response : constant Stream_Element_Array := Concat (Concat (Nak, Ack), Pack);
      Consumer : Collecting_Consumer;
   begin
      Version.Upload_Pack.Demux_Response
        (Data     => Response,
         Consumer => Consumer);

      Assert (Consumer.Last = 4,
              "sideband channel 1 payload should be forwarded without channel byte");
      Assert (To_String (Consumer.Data (1 .. Consumer.Last)) = "PACK",
              "pack bytes should be preserved");
   end Demuxes_Nak_And_Sideband_Pack_Data;

   procedure Sideband_Fatal_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Fatal : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          ([1 => 3,
            2 => Stream_Element (Character'Pos ('b')),
            3 => Stream_Element (Character'Pos ('a')),
            4 => Stream_Element (Character'Pos ('d'))]);
      Consumer : Collecting_Consumer;
      Raised   : Boolean := False;
   begin
      begin
         Version.Upload_Pack.Demux_Response
           (Data     => Fatal,
            Consumer => Consumer);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "sideband channel 3 must raise Data_Error");
   end Sideband_Fatal_Raises;

   procedure Selects_Default_Branch_From_Unique_Head_Match
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Refs : Version.Upload_Pack.Advertised_Ref_Vectors.Vector;
   begin
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("HEAD"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/main"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/trunk"),
          Id   => Tag_Id));

      Assert
        (Version.Upload_Pack.Default_Branch_From_Advertisements (Refs) = "main",
         "unique HEAD object-id match should select that branch");
   end Selects_Default_Branch_From_Unique_Head_Match;

   procedure Selects_Default_Branch_From_Tied_Head_Matches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Refs : Version.Upload_Pack.Advertised_Ref_Vectors.Vector;
   begin
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("HEAD"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/trunk"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/master"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/main"),
          Id   => Main_Id));

      Assert
        (Version.Upload_Pack.Default_Branch_From_Advertisements (Refs) = "main",
         "tied HEAD matches should prefer main over master and sorted fallback");
   end Selects_Default_Branch_From_Tied_Head_Matches;

   procedure Selects_Default_Branch_Without_Head
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Refs : Version.Upload_Pack.Advertised_Ref_Vectors.Vector;
   begin
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/zeta"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/heads/alpha"),
          Id   => Tag_Id));

      Assert
        (Version.Upload_Pack.Default_Branch_From_Advertisements (Refs) = "alpha",
         "without HEAD, helper should choose main/master/lexicographic fallback");
   end Selects_Default_Branch_Without_Head;

   procedure Default_Branch_Raises_Without_Branches
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Refs   : Version.Upload_Pack.Advertised_Ref_Vectors.Vector;
      Raised : Boolean := False;
   begin
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("HEAD"),
          Id   => Main_Id));
      Refs.Append
        (Advertised_Ref'(Name => To_Unbounded_String ("refs/tags/v1"),
          Id   => Tag_Id));

      begin
         declare
            Branch : constant String :=
              Version.Upload_Pack.Default_Branch_From_Advertisements (Refs);
            pragma Unreferenced (Branch);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "advertisements without branch refs must raise Data_Error");
   end Default_Branch_Raises_Without_Branches;

   procedure Detects_Shallow_Capability
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Version.Upload_Pack.Has_Capability
                ("multi_ack shallow side-band-64k ofs-delta", "shallow"),
              "shallow capability should be detected as a token");
      Assert (not Version.Upload_Pack.Has_Capability
                ("multi_ack side-band-64k ofs-delta", "shallow"),
              "missing shallow capability should be false");
      Assert (not Version.Upload_Pack.Has_Capability
                ("multi_ack not-shallow side-band-64k", "shallow"),
              "capability detection should not use substring matching");
   end Detects_Shallow_Capability;

   procedure Builds_Depth_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Upload_Pack.Build_Want_Request (Main_Id, 1);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "want packet should parse");
      Assert (To_String (Payload (Payload'First .. Last))
              = "want " & To_String (Main_Id) & " side-band-64k ofs-delta agent=version" & LF,
              "depth request should still start with want");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "deepen packet should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet,
              "deepen packet should be data");
      Assert (To_String (Payload (Payload'First .. Last)) = "deepen 1" & LF,
              "depth request should include deepen line before flush");

      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok, "flush should parse after deepen");
      Assert (Kind = Version.Pkt_Line.Flush_Packet,
              "deepen request should flush after deepen");
   end Builds_Depth_Want_Request;

   procedure Builds_Deepen_Relative_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Boundary : Version.Objects.Object_Id_Vectors.Vector;
   begin
      Boundary.Append (Tag_Id);
      declare
         Request : constant Stream_Element_Array :=
           Version.Upload_Pack.Build_Want_Request
             (Want_Id      => Main_Id,
              Depth        => 2,
              Include_Tag  => False,
              Relative     => True,
              Have_Shallow => Boundary);
         Parser  : Version.Pkt_Line.Parser;
         Kind    : Version.Pkt_Line.Packet_Kind;
         Payload : Stream_Element_Array (1 .. 256);
         Last    : Stream_Element_Offset;
         Status  : Version.Pkt_Line.Parse_Status;
      begin
         Version.Pkt_Line.Feed (Parser, Request);

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "want packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last))
            = "want " & To_String (Main_Id)
              & " side-band-64k ofs-delta deepen-relative agent=version" & LF,
            "deepen-relative want advertises the deepen-relative capability");

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "shallow packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last))
            = "shallow " & To_String (Tag_Id) & LF,
            "the existing shallow boundary is echoed to the server");

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "deepen packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last)) = "deepen 2" & LF,
            "the relative deepen count follows the shallow line");
      end;
   end Builds_Deepen_Relative_Want_Request;

   procedure Builds_Unshallow_Want_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Boundary : Version.Objects.Object_Id_Vectors.Vector;
   begin
      Boundary.Append (Main_Id);
      declare
         Request : constant Stream_Element_Array :=
           Version.Upload_Pack.Build_Want_Request
             (Want_Id      => Main_Id,
              Depth        => Positive'Last,
              Have_Shallow => Boundary);
         Parser  : Version.Pkt_Line.Parser;
         Kind    : Version.Pkt_Line.Packet_Kind;
         Payload : Stream_Element_Array (1 .. 256);
         Last    : Stream_Element_Offset;
         Status  : Version.Pkt_Line.Parse_Status;
      begin
         Version.Pkt_Line.Feed (Parser, Request);

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "want packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last))
            = "want " & To_String (Main_Id)
              & " side-band-64k ofs-delta agent=version" & LF,
            "unshallow does not request deepen-relative");

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "shallow packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last))
            = "shallow " & To_String (Main_Id) & LF,
            "unshallow echoes the current shallow boundary");

         Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
         Assert (Status = Version.Pkt_Line.Ok, "deepen packet should parse");
         Assert
           (To_String (Payload (Payload'First .. Last))
            = "deepen 2147483647" & LF,
            "unshallow requests the maximum depth");
      end;
   end Builds_Unshallow_Want_Request;

   procedure Parses_Shallow_And_Unshallow_Response
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Shallow_Line : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream ("shallow " & To_String (Main_Id) & LF));
      Unshallow_Line : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream ("unshallow " & To_String (Tag_Id) & LF));
      Flush : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Response : constant Stream_Element_Array :=
        Concat (Concat (Shallow_Line, Unshallow_Line), Flush);
      Update : constant Version.Upload_Pack.Shallow_Update :=
        Version.Upload_Pack.Parse_Shallow_Update (Response);
   begin
      Assert (Natural (Update.Shallow.Length) = 1,
              "one shallow id should be parsed");
      Assert (Update.Shallow.Element (0) = Main_Id,
              "shallow id should be preserved");
      Assert (Natural (Update.Unshallow.Length) = 1,
              "one unshallow id should be parsed");
      Assert (Update.Unshallow.Element (0) = Tag_Id,
              "unshallow id should be preserved");
   end Parses_Shallow_And_Unshallow_Response;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Parses_Discovery_Header_Refs_And_Capabilities'Access,
         "Upload_Pack: parses discovery header, refs, and capabilities");

      Register_Routine
        (T,
         Parses_Raw_Ssh_Advertisement'Access,
         "Upload_Pack: parses raw SSH advertisement refs and capabilities");

      Register_Routine
        (T,
         Selects_Default_Branch_From_Unique_Head_Match'Access,
         "Upload_Pack: selects default branch from unique HEAD match");

      Register_Routine
        (T,
         Selects_Default_Branch_From_Tied_Head_Matches'Access,
         "Upload_Pack: selects default branch from tied HEAD matches");

      Register_Routine
        (T,
         Selects_Default_Branch_Without_Head'Access,
         "Upload_Pack: selects default branch without HEAD");

      Register_Routine
        (T,
         Default_Branch_Raises_Without_Branches'Access,
         "Upload_Pack: default branch raises without branches");

      Register_Routine
        (T,
         Builds_Minimal_Want_Request'Access,
         "Upload_Pack: builds minimal want request");

      Register_Routine
        (T,
         Builds_Include_Tag_Want_Request'Access,
         "Upload_Pack: builds include-tag want request");

      Register_Routine
        (T,
         Builds_Filtered_Want_Request'Access,
         "Upload_Pack: builds filtered want request");

      Register_Routine
        (T,
         Builds_Arbitrary_Filtered_Want_Request'Access,
         "Upload_Pack: emits an arbitrary filter spec verbatim");

      Register_Routine
        (T,
         Detects_Shallow_Capability'Access,
         "Upload_Pack: detects shallow capability token");

      Register_Routine
        (T,
         Builds_Depth_Want_Request'Access,
         "Upload_Pack: builds depth want request");

      Register_Routine
        (T,
         Builds_Deepen_Relative_Want_Request'Access,
         "Upload_Pack: deepen-relative want request (fetch --deepen)");

      Register_Routine
        (T,
         Builds_Unshallow_Want_Request'Access,
         "Upload_Pack: unshallow want request (fetch --unshallow)");

      Register_Routine
        (T,
         Parses_Shallow_And_Unshallow_Response'Access,
         "Upload_Pack: parses shallow and unshallow response");

      Register_Routine
        (T,
         Demuxes_Nak_And_Sideband_Pack_Data'Access,
         "Upload_Pack: demuxes NAK/ACK and sideband pack data");

      Register_Routine
        (T,
         Sideband_Fatal_Raises'Access,
         "Upload_Pack: sideband fatal raises");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Upload_Pack");
   end Name;

end Version.Upload_Pack.Tests;
