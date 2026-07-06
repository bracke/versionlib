with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;

with AUnit.Assertions;
with AUnit.Test_Cases;

with GNAT.Sockets;

with Http_Client.HTTP2;
with Http_Client.Response_Streams;

package body Version.Transport.Http.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use type Http_Client.HTTP2.HTTP2_Mode;
   use type Http_Client.Response_Streams.Streaming_Protocol_Policy;

   CR : constant Character := Character'Val (13);
   LF : constant Character := Character'Val (10);

   type Collecting_Consumer is
     new Version.Transport.Http.Byte_Consumer with record
      Data : Stream_Element_Array (1 .. 512);
      Last : Natural := 0;
   end record;

   overriding procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Stream_Element_Array)
   is
      Target : Natural;
   begin
      for I in Data'Range loop
         Target := Item.Last + 1;
         Assert
           (Target <= Natural (Item.Data'Last),
            "collected HTTP response body exceeded test buffer");

         Item.Data (Stream_Element_Offset (Target)) := Data (I);
         Item.Last := Target;
      end loop;
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

   function Contains
     (Data    : Stream_Element_Array;
      Last    : Stream_Element_Offset;
      Pattern : String)
      return Boolean
   is
      Text : String (1 .. Natural (Last));
   begin
      if Last < Data'First then
         return False;
      end if;

      for I in 1 .. Natural (Last) loop
         Text (I) := Character'Val (Data (Stream_Element_Offset (I)));
      end loop;

      return Ada.Strings.Fixed.Index (Text, Pattern) /= 0;
   end Contains;

   Response_Body : constant Stream_Element_Array :=
     [1  => 0,
      2  => 10,
      3  => 13,
      4  => 10,
      5  => 16#80#,
      6  => 16#FF#,
      7  => Stream_Element (Character'Pos ('0')),
      8  => Stream_Element (Character'Pos ('0')),
      9  => Stream_Element (Character'Pos ('1')),
      10 => Stream_Element (Character'Pos ('e')),
      11 => Stream_Element (Character'Pos ('#')),
      12 => Stream_Element (Character'Pos (' ')),
      13 => Stream_Element (Character'Pos ('s')),
      14 => Stream_Element (Character'Pos ('e')),
      15 => Stream_Element (Character'Pos ('r')),
      16 => Stream_Element (Character'Pos ('v')),
      17 => Stream_Element (Character'Pos ('i')),
      18 => Stream_Element (Character'Pos ('c')),
      19 => Stream_Element (Character'Pos ('e')),
      20 => Stream_Element (Character'Pos ('=')),
      21 => Stream_Element (Character'Pos ('g')),
      22 => Stream_Element (Character'Pos ('i')),
      23 => Stream_Element (Character'Pos ('t')),
      24 => Stream_Element (Character'Pos ('-')),
      25 => Stream_Element (Character'Pos ('u')),
      26 => Stream_Element (Character'Pos ('p')),
      27 => Stream_Element (Character'Pos ('l')),
      28 => Stream_Element (Character'Pos ('o')),
      29 => Stream_Element (Character'Pos ('a')),
      30 => Stream_Element (Character'Pos ('d')),
      31 => Stream_Element (Character'Pos ('-')),
      32 => Stream_Element (Character'Pos ('p')),
      33 => Stream_Element (Character'Pos ('a')),
      34 => Stream_Element (Character'Pos ('c')),
      35 => Stream_Element (Character'Pos ('k')),
      36 => 10];

   type Fixture_Operation is
     (Upload_Discovery,
      Receive_Discovery,
      Upload_Post,
      Receive_Post);

   task type Fixture_Server
     (Operation : Fixture_Operation := Upload_Discovery) is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Fixture_Server;

   task body Fixture_Server is
      Server      : GNAT.Sockets.Socket_Type;
      Client      : GNAT.Sockets.Socket_Type;
      Address     : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Bound       : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 4096);
      Request_End : Stream_Element_Offset;
      Header_Text : constant String :=
        "HTTP/1.1 200 OK" & CR & LF
        & "Content-Type: application/x-git-upload-pack-advertisement" & CR & LF
        & "Content-Length: "
        & Ada.Strings.Fixed.Trim
            (Integer'Image (Response_Body'Length),
             Ada.Strings.Left)
        & CR & LF
        & "Connection: close" & CR & LF
        & CR & LF;
      Header_Data : constant Stream_Element_Array := To_Stream (Header_Text);
      Last_Sent   : Stream_Element_Offset;
      Good_Request : Boolean := False;
   begin
      GNAT.Sockets.Create_Socket (Server);
      GNAT.Sockets.Set_Socket_Option
        (Socket => Server,
         Level  => GNAT.Sockets.Socket_Level,
         Option => (Name => GNAT.Sockets.Reuse_Address,
                    Enabled => True));

      GNAT.Sockets.Bind_Socket (Server, Address);
      Bound := GNAT.Sockets.Get_Socket_Name (Server);
      GNAT.Sockets.Listen_Socket (Server);

      accept Ready (Port : out GNAT.Sockets.Port_Type) do
         Port := Bound.Port;
      end Ready;

      GNAT.Sockets.Accept_Socket (Server, Client, Peer);
      GNAT.Sockets.Receive_Socket (Client, Request, Request_End);

      case Operation is
         when Upload_Discovery =>
            Good_Request :=
              Contains
                (Request,
                 Request_End,
                 "GET /repo.git/info/refs?service=git-upload-pack HTTP/")
              and then Contains
                (Request,
                 Request_End,
                 "Accept: */*")
              and then not Contains
                (Request,
                 Request_End,
                 "Git-Protocol:");

         when Receive_Discovery =>
            Good_Request :=
              Contains
                (Request,
                 Request_End,
                 "GET /repo.git/info/refs?service=git-receive-pack HTTP/")
              and then Contains
                (Request,
                 Request_End,
                 "Accept: */*")
              and then not Contains
                (Request,
                 Request_End,
                 "Git-Protocol:");

         when Upload_Post =>
            Good_Request :=
              Contains
                (Request,
                 Request_End,
                 "POST /repo.git/git-upload-pack HTTP/")
              and then Contains
                (Request,
                 Request_End,
                 "Content-Type: application/x-git-upload-pack-request")
              and then Contains
                (Request,
                 Request_End,
                 "Accept: application/x-git-upload-pack-result")
              and then Contains
                (Request,
                 Request_End,
                 "client-upload-request");

         when Receive_Post =>
            Good_Request :=
              Contains
                (Request,
                 Request_End,
                 "POST /repo.git/git-receive-pack HTTP/")
              and then Contains
                (Request,
                 Request_End,
                 "Content-Type: application/x-git-receive-pack-request")
              and then Contains
                (Request,
                 Request_End,
                 "Accept: application/x-git-receive-pack-result")
              and then Contains
                (Request,
                 Request_End,
                 "client-receive-request");
      end case;

      Good_Request :=
        Good_Request
        and then Contains
          (Request,
           Request_End,
           "Host: 127.0.0.1:")
        and then Contains
          (Request,
           Request_End,
           "Accept-Encoding: identity")
        and then not Contains
          (Request,
           Request_End,
           "Upgrade:");

      if Good_Request then
         GNAT.Sockets.Send_Socket (Client, Header_Data, Last_Sent);
         GNAT.Sockets.Send_Socket (Client, Response_Body, Last_Sent);
      else
         declare
            Bad_Response : constant Stream_Element_Array :=
              To_Stream
                ("HTTP/1.1 400 Bad Request" & CR & LF
                 & "Content-Length: 0" & CR & LF
                 & "Connection: close" & CR & LF
                 & CR & LF);
         begin
            GNAT.Sockets.Send_Socket (Client, Bad_Response, Last_Sent);
         end;
      end if;

      GNAT.Sockets.Close_Socket (Client);
      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Client);
         exception
            when others =>
               null;
         end;

         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others =>
               null;
         end;

   end Fixture_Server;

   procedure Assert_Collected_Response
     (Consumer : Collecting_Consumer;
      Context  : String) is
   begin
      Assert
        (Consumer.Last = Response_Body'Length,
         Context & " must preserve exact binary response length");

      for I in Response_Body'Range loop
         Assert
           (Consumer.Data (I) = Response_Body (I),
            Context & " must preserve raw byte at offset"
            & Stream_Element_Offset'Image (I));
      end loop;
   end Assert_Collected_Response;

   procedure Git_Streaming_Options_Enable_Https_HTTP2
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Version.Transport.Http.Git_Streaming_Options;
   begin
      Assert
        (Options.Protocol_Policy
         = Http_Client.Response_Streams.Streaming_Prefer_HTTP_2,
         "Git HTTP transport must prefer HTTPS HTTP/2 with fallback");
      Assert
        (Options.TLS.HTTP2.Mode = Http_Client.HTTP2.HTTP2_Allowed,
         "Git HTTP transport must advertise h2 ALPN for HTTPS");
      Assert
        (Options.TLS.HTTP2.Enable_Public_Streaming,
         "Git HTTP transport must enable HTTP/2 response streaming");
      Assert
        (Options.TLS.HTTP2.Enable_Upload_Streaming,
         "Git HTTP transport must enable HTTP/2 upload streaming");
      Assert
        (not Options.Enable_Decompression,
         "Git HTTP transport must keep pack bytes content-encoded identity");
   end Git_Streaming_Options_Enable_Https_HTTP2;

   procedure Upload_Pack_Info_Refs_Url_Construction
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Http.Upload_Pack_Info_Refs_Url
           ("https://example.com/repo.git")
         = "https://example.com/repo.git/info/refs?service=git-upload-pack",
         "must append upload-pack discovery path to .git URL");

      Assert
        (Version.Transport.Http.Upload_Pack_Info_Refs_Url
           ("https://example.com/repo")
         = "https://example.com/repo/info/refs?service=git-upload-pack",
         "must append upload-pack discovery path to repository URL");

      Assert
        (Version.Transport.Http.Upload_Pack_Info_Refs_Url
           ("https://example.com/repo/")
         = "https://example.com/repo/info/refs?service=git-upload-pack",
         "must avoid a doubled slash before info/refs");

      Assert
        (Version.Transport.Http.Upload_Pack_Info_Refs_Url
           ("https://example.com/repo//")
         = "https://example.com/repo/info/refs?service=git-upload-pack",
         "must normalize repeated trailing slashes before info/refs");
   end Upload_Pack_Info_Refs_Url_Construction;

   procedure Receive_Pack_Info_Refs_Url_Construction
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Http.Receive_Pack_Info_Refs_Url
           ("https://example.com/repo.git/")
         = "https://example.com/repo.git/info/refs?service=git-receive-pack",
         "must append receive-pack discovery path without doubled slash");
   end Receive_Pack_Info_Refs_Url_Construction;

   procedure Classifies_Http_And_Https_Remotes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Transport.Detect_Transport ("https://example.com/repo.git")
         = Version.Transport.Http_Transport,
         "https remotes must be classified as HTTP transport");

      Assert
        (Version.Transport.Detect_Transport ("http://example.com/repo.git")
         = Version.Transport.Http_Transport,
         "explicit http remotes must be classified as HTTP transport");

      Assert
        (Version.Transport.Detect_Transport ("../repo.git")
         = Version.Transport.Local_Transport,
         "relative paths must remain local transport");
   end Classifies_Http_And_Https_Remotes;

   procedure Invalid_URI_Raises_Deterministic_Error
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Consumer : Collecting_Consumer;
      Raised   : Boolean := False;
   begin
      begin
         Version.Transport.Http.Discover_Upload_Pack
           (Url      => "https://exa mple.invalid/repo.git",
            Consumer => Consumer);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
        (Raised,
         "invalid HTTP URI must raise Ada.IO_Exceptions.Data_Error");
   end Invalid_URI_Raises_Deterministic_Error;

   procedure Streams_Binary_Response_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Server   : Fixture_Server (Upload_Discovery);
      Port     : GNAT.Sockets.Port_Type;
      Consumer : Collecting_Consumer;
   begin
      Server.Ready (Port);

      Version.Transport.Http.Discover_Upload_Pack
        (Url      => "http://127.0.0.1:"
                     & Ada.Strings.Fixed.Trim
                         (Integer'Image (Integer (Port)),
                          Ada.Strings.Left)
                     & "/repo.git",
         Consumer => Consumer);

      Assert_Collected_Response (Consumer, "HTTP discovery");
   end Streams_Binary_Response_Bytes;

   procedure Receive_Pack_Discovery_Streams_Binary_Response_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Server   : Fixture_Server (Receive_Discovery);
      Port     : GNAT.Sockets.Port_Type;
      Consumer : Collecting_Consumer;
   begin
      Server.Ready (Port);

      Version.Transport.Http.Discover_Receive_Pack
        (Url      => "http://127.0.0.1:"
                     & Ada.Strings.Fixed.Trim
                         (Integer'Image (Integer (Port)),
                          Ada.Strings.Left)
                     & "/repo.git/",
         Consumer => Consumer);

      Assert_Collected_Response (Consumer, "HTTP receive-pack discovery");
   end Receive_Pack_Discovery_Streams_Binary_Response_Bytes;

   procedure Upload_Pack_Post_Streams_Binary_Response_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Server   : Fixture_Server (Upload_Post);
      Port     : GNAT.Sockets.Port_Type;
      Consumer : Collecting_Consumer;
   begin
      Server.Ready (Port);

      Version.Transport.Http.Upload_Pack
        (Url      => "http://127.0.0.1:"
                     & Ada.Strings.Fixed.Trim
                         (Integer'Image (Integer (Port)),
                          Ada.Strings.Left)
                     & "/repo.git",
         Request  => To_Stream ("client-upload-request"),
         Consumer => Consumer);

      Assert_Collected_Response (Consumer, "HTTP upload-pack POST");
   end Upload_Pack_Post_Streams_Binary_Response_Bytes;

   procedure Receive_Pack_Post_Streams_Binary_Response_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Server   : Fixture_Server (Receive_Post);
      Port     : GNAT.Sockets.Port_Type;
      Consumer : Collecting_Consumer;
   begin
      Server.Ready (Port);

      Version.Transport.Http.Receive_Pack
        (Url      => "http://127.0.0.1:"
                     & Ada.Strings.Fixed.Trim
                         (Integer'Image (Integer (Port)),
                          Ada.Strings.Left)
                     & "/repo.git/",
         Request  => To_Stream ("client-receive-request"),
         Consumer => Consumer);

      Assert_Collected_Response (Consumer, "HTTP receive-pack POST");
   end Receive_Pack_Post_Streams_Binary_Response_Bytes;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Git_Streaming_Options_Enable_Https_HTTP2'Access,
         "Transport.Http: Git streaming options prefer HTTPS HTTP/2");

      Register_Routine
        (T,
         Upload_Pack_Info_Refs_Url_Construction'Access,
         "Transport.Http: upload-pack info refs URL construction");

      Register_Routine
        (T,
         Receive_Pack_Info_Refs_Url_Construction'Access,
         "Transport.Http: receive-pack info refs URL construction");

      Register_Routine
        (T,
         Classifies_Http_And_Https_Remotes'Access,
         "Transport: classifies HTTP and HTTPS remotes");

      Register_Routine
        (T,
         Invalid_URI_Raises_Deterministic_Error'Access,
         "Transport.Http: invalid URI maps to deterministic error");

      Register_Routine
        (T,
         Streams_Binary_Response_Bytes'Access,
         "Transport.Http: streams binary response bytes");

      Register_Routine
        (T,
         Receive_Pack_Discovery_Streams_Binary_Response_Bytes'Access,
         "Transport.Http: receive-pack discovery streams binary response bytes");

      Register_Routine
        (T,
         Upload_Pack_Post_Streams_Binary_Response_Bytes'Access,
         "Transport.Http: upload-pack POST streams binary response bytes");

      Register_Routine
        (T,
         Receive_Pack_Post_Streams_Binary_Response_Bytes'Access,
         "Transport.Http: receive-pack POST streams binary response bytes");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Transport.Http");
   end Name;

end Version.Transport.Http.Tests;
