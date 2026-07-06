with Ada.IO_Exceptions;

with Http_Client.Errors; use Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.HTTP2;
with Http_Client.Requests;
with Http_Client.Types;
with Http_Client.URI;

package body Version.Transport.Http is

   procedure Check
     (Status : Http_Client.Errors.Result_Status; Context : String);

   function Git_Discovery_Headers return Http_Client.Headers.Header_List;

   function Git_Upload_Pack_Headers return Http_Client.Headers.Header_List;

   function Git_Receive_Pack_Headers return Http_Client.Headers.Header_List;

   procedure Check
     (Status : Http_Client.Errors.Result_Status; Context : String) is
   begin
      if Status /= Http_Client.Errors.Ok then
         raise Ada.IO_Exceptions.Data_Error
           with
             Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
      end if;
   end Check;

   function Strip_Trailing_Slashes (Value : String) return String is
      Last : Natural := Value'Last;
   begin
      if Value'Length = 0 then
         return Value;
      end if;

      while Last >= Value'First and then Value (Last) = '/' loop
         if Last = Value'First then
            return "";
         end if;

         Last := Last - 1;
      end loop;

      return Value (Value'First .. Last);
   end Strip_Trailing_Slashes;

   function Upload_Pack_Info_Refs_Url (Base_Url : String) return String is
      Clean : constant String := Strip_Trailing_Slashes (Base_Url);
   begin
      return Clean & "/info/refs?service=git-upload-pack";
   end Upload_Pack_Info_Refs_Url;

   function Receive_Pack_Info_Refs_Url (Base_Url : String) return String is
      Clean : constant String := Strip_Trailing_Slashes (Base_Url);
   begin
      return Clean & "/info/refs?service=git-receive-pack";
   end Receive_Pack_Info_Refs_Url;

   function Git_Discovery_Headers return Http_Client.Headers.Header_List is
      Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
   begin
      Check
        (Http_Client.Headers.Set
           (List => Headers, Name => "Accept", Value => "*/*"),
         "set Accept header");

      Check
        (Http_Client.Headers.Set
           (List => Headers, Name => "Accept-Encoding", Value => "identity"),
         "set Accept-Encoding header");

      return Headers;
   end Git_Discovery_Headers;

   function Git_Upload_Pack_Headers return Http_Client.Headers.Header_List is
      Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
   begin
      Check
        (Http_Client.Headers.Set
           (List  => Headers,
            Name  => "Content-Type",
            Value => "application/x-git-upload-pack-request"),
         "set Content-Type header");

      Check
        (Http_Client.Headers.Set
           (List  => Headers,
            Name  => "Accept",
            Value => "application/x-git-upload-pack-result"),
         "set Accept header");

      Check
        (Http_Client.Headers.Set
           (List => Headers, Name => "Accept-Encoding", Value => "identity"),
         "set Accept-Encoding header");

      return Headers;
   end Git_Upload_Pack_Headers;

   function Git_Receive_Pack_Headers return Http_Client.Headers.Header_List is
      Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
   begin
      Check
        (Http_Client.Headers.Set
           (List  => Headers,
            Name  => "Content-Type",
            Value => "application/x-git-receive-pack-request"),
         "set Content-Type header");

      Check
        (Http_Client.Headers.Set
           (List  => Headers,
            Name  => "Accept",
            Value => "application/x-git-receive-pack-result"),
         "set Accept header");

      Check
        (Http_Client.Headers.Set
           (List => Headers, Name => "Accept-Encoding", Value => "identity"),
         "set Accept-Encoding header");

      return Headers;
   end Git_Receive_Pack_Headers;

   function Git_Streaming_Options
      return Http_Client.Response_Streams.Streaming_Options
   is
      Options : Http_Client.Response_Streams.Streaming_Options :=
        Http_Client.Response_Streams.Default_Streaming_Options;
   begin
      Options.Protocol_Policy :=
        Http_Client.Response_Streams.Streaming_Prefer_HTTP_2;
      Options.TLS.HTTP2.Mode := Http_Client.HTTP2.HTTP2_Allowed;
      Options.TLS.HTTP2.Enable_Public_Streaming := True;
      Options.TLS.HTTP2.Enable_Upload_Streaming := True;
      Options.Enable_Decompression := False;

      return Options;
   end Git_Streaming_Options;

   procedure Discover_Upload_Pack
     (Url : String; Consumer : in out Byte_Consumer'Class)
   is
      use Ada.Streams;

      Discovery_Url : constant String := Upload_Pack_Info_Refs_Url (Url);

      URI     : Http_Client.URI.URI_Reference;
      Request : Http_Client.Requests.Request;
      Stream  : Http_Client.Response_Streams.Streaming_Response;

      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Git_Streaming_Options;

      Buffer : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Status : Http_Client.Errors.Result_Status;
      Opened : Boolean := False;
   begin
      Check
        (Http_Client.URI.Parse (Text => Discovery_Url, Item => URI),
         "parse HTTP discovery URI");

      Check
        (Http_Client.Requests.Create
           (Method    => Http_Client.Types.Method_Name'Value ("GET"),
            URI       => URI,
            Item      => Request,
            Headers   => Git_Discovery_Headers,
            Payload   => "",
            Auto_Host => True),
         "create HTTP discovery request");

      Check
        (Http_Client.Response_Streams.Open
           (Request => Request, Stream => Stream, Options => Options),
         "open HTTP discovery response stream");

      Opened := True;

      while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
         Status :=
           Http_Client.Response_Streams.Read_Some
             (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Status = Http_Client.Errors.End_Of_Stream;

         Check (Status, "read HTTP discovery response body");

         if Last >= Buffer'First then
            Consumer.Consume (Buffer (Buffer'First .. Last));
         end if;
      end loop;

      Check
        (Http_Client.Response_Streams.Close (Stream),
         "close HTTP discovery response stream");

   exception
      when others =>
         if Opened then
            declare
               Close_Status : constant Http_Client.Errors.Result_Status :=
                 Http_Client.Response_Streams.Close (Stream);
               pragma Unreferenced (Close_Status);
            begin
               null;
            end;
         end if;

         raise;
   end Discover_Upload_Pack;

   function To_String (Data : Ada.Streams.Stream_Element_Array) return String
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

   procedure Upload_Pack
     (Url      : String;
      Request  : Ada.Streams.Stream_Element_Array;
      Consumer : in out Byte_Consumer'Class)
   is
      use Ada.Streams;

      Upload_Url : constant String :=
        Strip_Trailing_Slashes (Url) & "/git-upload-pack";

      URI      : Http_Client.URI.URI_Reference;
      Http_Req : Http_Client.Requests.Request;
      Stream   : Http_Client.Response_Streams.Streaming_Response;

      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Git_Streaming_Options;

      Buffer : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Status : Http_Client.Errors.Result_Status;
      Opened : Boolean := False;
   begin
      Check
        (Http_Client.URI.Parse (Text => Upload_Url, Item => URI),
         "parse HTTP upload-pack URI");

      Check
        (Http_Client.Requests.Create
           (Method    => Http_Client.Types.Method_Name'Value ("POST"),
            URI       => URI,
            Item      => Http_Req,
            Headers   => Git_Upload_Pack_Headers,
            Payload   => To_String (Request),
            Auto_Host => True),
         "create HTTP upload-pack request");

      Check
        (Http_Client.Response_Streams.Open
           (Request => Http_Req, Stream => Stream, Options => Options),
         "open HTTP upload-pack response stream");

      Opened := True;

      while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
         Status :=
           Http_Client.Response_Streams.Read_Some
             (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Status = Http_Client.Errors.End_Of_Stream;

         Check (Status, "read HTTP upload-pack response body");

         if Last >= Buffer'First then
            Consumer.Consume (Buffer (Buffer'First .. Last));
         end if;
      end loop;

      Check
        (Http_Client.Response_Streams.Close (Stream),
         "close HTTP upload-pack response stream");

   exception
      when others =>
         if Opened then
            declare
               Close_Status : constant Http_Client.Errors.Result_Status :=
                 Http_Client.Response_Streams.Close (Stream);
               pragma Unreferenced (Close_Status);
            begin
               null;
            end;
         end if;

         raise;
   end Upload_Pack;

   procedure Discover_Receive_Pack
     (Url : String; Consumer : in out Byte_Consumer'Class)
   is
      use Ada.Streams;

      Discovery_Url : constant String := Receive_Pack_Info_Refs_Url (Url);

      URI     : Http_Client.URI.URI_Reference;
      Request : Http_Client.Requests.Request;
      Stream  : Http_Client.Response_Streams.Streaming_Response;

      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Git_Streaming_Options;

      Buffer : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Status : Http_Client.Errors.Result_Status;
      Opened : Boolean := False;
   begin
      Check
        (Http_Client.URI.Parse (Text => Discovery_Url, Item => URI),
         "parse HTTP receive-pack discovery URI");

      Check
        (Http_Client.Requests.Create
           (Method    => Http_Client.Types.Method_Name'Value ("GET"),
            URI       => URI,
            Item      => Request,
            Headers   => Git_Discovery_Headers,
            Payload   => "",
            Auto_Host => True),
         "create HTTP receive-pack discovery request");

      Check
        (Http_Client.Response_Streams.Open
           (Request => Request, Stream => Stream, Options => Options),
         "open HTTP receive-pack discovery response stream");

      Opened := True;

      while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
         Status :=
           Http_Client.Response_Streams.Read_Some
             (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Status = Http_Client.Errors.End_Of_Stream;

         Check (Status, "read HTTP receive-pack discovery response body");

         if Last >= Buffer'First then
            Consumer.Consume (Buffer (Buffer'First .. Last));
         end if;
      end loop;

      Check
        (Http_Client.Response_Streams.Close (Stream),
         "close HTTP receive-pack discovery response stream");

   exception
      when others =>
         if Opened then
            declare
               Close_Status : constant Http_Client.Errors.Result_Status :=
                 Http_Client.Response_Streams.Close (Stream);
               pragma Unreferenced (Close_Status);
            begin
               null;
            end;
         end if;

         raise;
   end Discover_Receive_Pack;

   procedure Receive_Pack
     (Url      : String;
      Request  : Ada.Streams.Stream_Element_Array;
      Consumer : in out Byte_Consumer'Class)
   is
      use Ada.Streams;

      Upload_Url : constant String :=
        Strip_Trailing_Slashes (Url) & "/git-receive-pack";

      URI      : Http_Client.URI.URI_Reference;
      Http_Req : Http_Client.Requests.Request;
      Stream   : Http_Client.Response_Streams.Streaming_Response;

      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Git_Streaming_Options;

      Buffer : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Status : Http_Client.Errors.Result_Status;
      Opened : Boolean := False;
   begin
      Check
        (Http_Client.URI.Parse (Text => Upload_Url, Item => URI),
         "parse HTTP receive-pack URI");

      Check
        (Http_Client.Requests.Create
           (Method    => Http_Client.Types.Method_Name'Value ("POST"),
            URI       => URI,
            Item      => Http_Req,
            Headers   => Git_Receive_Pack_Headers,
            Payload   => To_String (Request),
            Auto_Host => True),
         "create HTTP receive-pack request");

      Check
        (Http_Client.Response_Streams.Open
           (Request => Http_Req, Stream => Stream, Options => Options),
         "open HTTP receive-pack response stream");

      Opened := True;

      while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
         Status :=
           Http_Client.Response_Streams.Read_Some
             (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Status = Http_Client.Errors.End_Of_Stream;

         Check (Status, "read HTTP receive-pack response body");

         if Last >= Buffer'First then
            Consumer.Consume (Buffer (Buffer'First .. Last));
         end if;
      end loop;

      Check
        (Http_Client.Response_Streams.Close (Stream),
         "close HTTP receive-pack response stream");

   exception
      when others =>
         if Opened then
            declare
               Close_Status : constant Http_Client.Errors.Result_Status :=
                 Http_Client.Response_Streams.Close (Stream);
               pragma Unreferenced (Close_Status);
            begin
               null;
            end;
         end if;

         raise;
   end Receive_Pack;

end Version.Transport.Http;
