with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Http_Client.Auth;
with Http_Client.Errors; use Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.HTTP2;
with Http_Client.Requests;
with Http_Client.Types;
with Http_Client.URI;

with Version.Credential;
with Version.Repository;

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
      Options.TLS.HTTP2.Enable_Multiplexing := True;
      Options.TLS.HTTP2.Enable_Public_Streaming := True;
      Options.TLS.HTTP2.Enable_Upload_Streaming := True;
      Options.Enable_Decompression := False;

      return Options;
   end Git_Streaming_Options;

   --  Extract "user[:pass]@" userinfo from an HTTP URL's authority.
   procedure Parse_Userinfo
     (Url : String; User, Pass : out Unbounded_String; Has_Pass : out Boolean)
   is
      Scheme_End : Natural := 0;
      Auth_Start : Natural;
      Auth_End   : Natural;
      At_Sign    : Natural := 0;
   begin
      User := Null_Unbounded_String;
      Pass := Null_Unbounded_String;
      Has_Pass := False;
      if Url'Length < 3 then
         return;
      end if;
      for I in Url'First .. Url'Last - 2 loop
         if Url (I .. I + 2) = "://" then
            Scheme_End := I + 2;
            exit;
         end if;
      end loop;
      if Scheme_End = 0 or else Scheme_End >= Url'Last then
         return;
      end if;
      Auth_Start := Scheme_End + 1;
      Auth_End := Url'Last;
      for I in Auth_Start .. Url'Last loop
         if Url (I) = '/' or else Url (I) = '?' or else Url (I) = '#' then
            Auth_End := I - 1;
            exit;
         end if;
      end loop;
      for I in Auth_Start .. Auth_End loop
         if Url (I) = '@' then
            At_Sign := I;
         end if;
      end loop;
      if At_Sign = 0 then
         return;
      end if;
      declare
         UI    : constant String := Url (Auth_Start .. At_Sign - 1);
         Colon : Natural := 0;
      begin
         for I in UI'Range loop
            if UI (I) = ':' then
               Colon := I;
               exit;
            end if;
         end loop;
         if Colon = 0 then
            User := To_Unbounded_String (UI);
         else
            User := To_Unbounded_String (UI (UI'First .. Colon - 1));
            Pass := To_Unbounded_String (UI (Colon + 1 .. UI'Last));
            Has_Pass := True;
         end if;
      end;
   end Parse_Userinfo;

   --  Return Url with any "user[:pass]@" userinfo removed from the authority
   --  (httpclient's URI parser rejects userinfo; git also strips it).
   function Strip_Userinfo (Url : String) return String is
      Scheme_End : Natural := 0;
      Auth_End   : Natural;
      At_Sign    : Natural := 0;
   begin
      if Url'Length < 3 then
         return Url;
      end if;
      for I in Url'First .. Url'Last - 2 loop
         if Url (I .. I + 2) = "://" then
            Scheme_End := I + 2;
            exit;
         end if;
      end loop;
      if Scheme_End = 0 or else Scheme_End >= Url'Last then
         return Url;
      end if;
      Auth_End := Url'Last;
      for I in Scheme_End + 1 .. Url'Last loop
         if Url (I) = '/' or else Url (I) = '?' or else Url (I) = '#' then
            Auth_End := I - 1;
            exit;
         end if;
      end loop;
      for I in Scheme_End + 1 .. Auth_End loop
         if Url (I) = '@' then
            At_Sign := I;
         end if;
      end loop;
      if At_Sign = 0 then
         return Url;
      end if;
      return Url (Url'First .. Scheme_End) & Url (At_Sign + 1 .. Url'Last);
   end Strip_Userinfo;

   --  Issue Method Url with Headers/Payload, streaming the body to Consumer.
   --  On an HTTP 401 the request is retried once with credentials from
   --  `credential fill`; a successful retry is `approve`d, a failed one
   --  `reject`ed (git's smart-HTTP authentication handshake).
   --  The status the last request came back with, so a caller that cares
   --  (the dumb protocol's GET, which reads a 404 as "not here") can see it.
   Last_Status : Natural := 0;

   procedure Request_With_Auth
     (Method   : String;
      Url      : String;
      Headers  : Http_Client.Headers.Header_List;
      Payload  : String;
      Consumer : in out Byte_Consumer'Class)
   is
      use Ada.Streams;

      Clean_Url : constant String := Strip_Userinfo (Url);

      URI     : Http_Client.URI.URI_Reference;
      Stream  : Http_Client.Response_Streams.Streaming_Response;
      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        Git_Streaming_Options;
      Opened  : Boolean := False;
      Code    : Http_Client.Types.Status_Code := 200;

      URL_User, URL_Pass : Unbounded_String;
      Has_URL_Pass       : Boolean;

      procedure Close_Stream is
      begin
         if Opened then
            declare
               S : constant Http_Client.Errors.Result_Status :=
                 Http_Client.Response_Streams.Close (Stream);
               pragma Unreferenced (S);
            begin
               null;
            end;
            Opened := False;
         end if;
      end Close_Stream;

      --  (Re)issue the request, optionally with HTTP Basic auth; sets Code.
      procedure Do_Open (Use_Auth : Boolean; U, P : String) is
         Req : Http_Client.Requests.Request;
      begin
         Check
           (Http_Client.Requests.Create
              (Method    => Http_Client.Types.Method_Name'Value (Method),
               URI       => URI,
               Item      => Req,
               Headers   => Headers,
               Payload   => Payload,
               Auto_Host => True),
            "create HTTP request");
         if Use_Auth then
            declare
               Req2 : Http_Client.Requests.Request;
            begin
               Check
                 (Http_Client.Auth.Set_Basic_Authorization (Req, U, P, Req2),
                  "set HTTP Basic authorization");
               Req := Req2;
            end;
         end if;
         Check
           (Http_Client.Response_Streams.Open
              (Request => Req, Stream => Stream, Options => Options),
            "open HTTP response stream");
         Opened := True;
         Code := Http_Client.Response_Streams.Status_Code (Stream);
         Last_Status := Natural (Code);
      end Do_Open;

      procedure Consume_Body is
         Buffer : Stream_Element_Array (1 .. 16 * 1024);
         Last   : Stream_Element_Offset;
         Status : Http_Client.Errors.Result_Status;
      begin
         while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
            Status :=
              Http_Client.Response_Streams.Read_Some
                (Stream => Stream, Buffer => Buffer, Last => Last);
            exit when Status = Http_Client.Errors.End_Of_Stream;
            Check (Status, "read HTTP response body");
            if Last >= Buffer'First then
               Consumer.Consume (Buffer (Buffer'First .. Last));
            end if;
         end loop;
      end Consume_Body;
   begin
      Check
        (Http_Client.URI.Parse (Text => Clean_Url, Item => URI),
         "parse HTTP URI");
      Parse_Userinfo (Url, URL_User, URL_Pass, Has_URL_Pass);

      --  Preemptive auth when the URL embeds a password; else try anonymous.
      Do_Open (Has_URL_Pass, To_String (URL_User), To_String (URL_Pass));

      if Code = 401 then
         Close_Stream;
         declare
            Cred      : Version.Credential.Credential;
            Repo      : Version.Repository.Repository_Handle;
            Have_Repo : Boolean := True;
         begin
            --  Credentials come from the current repository's config (git's
            --  helpers). When there is no repository (e.g. clone before init),
            --  only URL-embedded userinfo is available.
            begin
               Repo := Version.Repository.Open;
            exception
               when others => Have_Repo := False;
            end;
            Cred.Protocol :=
              To_Unbounded_String (Http_Client.URI.Scheme (URI));
            Cred.Host := To_Unbounded_String (Http_Client.URI.Host (URI));
            if Length (URL_User) > 0 then
               Cred.Username := URL_User;
            end if;
            if Have_Repo then
               Version.Credential.Fill (Repo, Cred);
            end if;
            if Length (Cred.Username) > 0 and then Length (Cred.Password) > 0
            then
               Do_Open (True, To_String (Cred.Username),
                        To_String (Cred.Password));
               if Code in 200 .. 299 then
                  if Have_Repo then
                     Version.Credential.Approve (Repo, Cred);
                  end if;
               elsif Code = 401 then
                  if Have_Repo then
                     Version.Credential.Reject (Repo, Cred);
                  end if;
                  Close_Stream;
                  raise Ada.IO_Exceptions.Data_Error
                    with "HTTP authentication failed (401)";
               end if;
            else
               Close_Stream;
               raise Ada.IO_Exceptions.Data_Error
                 with "HTTP 401: no credentials available";
            end if;
         end;
      end if;

      Consume_Body;
      Check
        (Http_Client.Response_Streams.Close (Stream), "close HTTP stream");
   exception
      when others =>
         Close_Stream;
         raise;
   end Request_With_Auth;

   procedure Get
     (Url      : String;
      Consumer : in out Byte_Consumer'Class;
      Found    : out Boolean) is
   begin
      Last_Status := 0;
      Request_With_Auth ("GET", Url, Git_Discovery_Headers, "", Consumer);
      Found := Last_Status in 200 .. 299;
   exception
      when others =>
         Found := False;
   end Get;

   procedure Discover_Upload_Pack
     (Url      : String;
      Consumer : in out Byte_Consumer'Class) is
   begin
      Request_With_Auth
        ("GET", Upload_Pack_Info_Refs_Url (Url),
         Git_Discovery_Headers, "", Consumer);
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
      Consumer : in out Byte_Consumer'Class) is
   begin
      Request_With_Auth
        ("POST", Strip_Trailing_Slashes (Url) & "/git-upload-pack",
         Git_Upload_Pack_Headers, To_String (Request), Consumer);
   end Upload_Pack;

   procedure Discover_Receive_Pack
     (Url      : String;
      Consumer : in out Byte_Consumer'Class) is
   begin
      Request_With_Auth
        ("GET", Receive_Pack_Info_Refs_Url (Url),
         Git_Discovery_Headers, "", Consumer);
   end Discover_Receive_Pack;

   procedure Receive_Pack
     (Url      : String;
      Request  : Ada.Streams.Stream_Element_Array;
      Consumer : in out Byte_Consumer'Class) is
   begin
      Request_With_Auth
        ("POST", Strip_Trailing_Slashes (Url) & "/git-receive-pack",
         Git_Receive_Pack_Headers, To_String (Request), Consumer);
   end Receive_Pack;

end Version.Transport.Http;
