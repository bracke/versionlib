with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Http_Client.Auth;
with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.HTTP2;
with Http_Client.Requests;
with Http_Client.Response_Streams;
with Http_Client.Types;
with Http_Client.URI;

with Version.Config;
with Version.Credential;
with Version.Files;
with Version.Hash;
with Version.History;
with Version.Pkt_Line;
with Version.Refs;
with Version.Staging;
with Version.Tags;
with Version.Transport;
with Version.Transport.Local;
with Version.Transport.Ssh;
with Version.Write;

package body Version.LFS is

   use type Http_Client.Errors.Result_Status;
   use type Version.Transport.Transport_Kind;
   use type Version.Objects.Object_Kind;

   function Join (Left, Right : String) return String
   renames Version.Files.Join;

   function Is_Hex (Text : String) return Boolean is
   begin
      for C of Text loop
         if not ((C >= '0' and then C <= '9')
                 or else (C >= 'a' and then C <= 'f')
                 or else (C >= 'A' and then C <= 'F'))
         then
            return False;
         end if;
      end loop;

      return True;
   end Is_Hex;

   function Pointer_Line (Text : String; Prefix : String) return String is
      Start : Natural := Text'First;
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= Character'Val (10) loop
               Stop := Stop + 1;
            end loop;

            declare
               Line : constant String :=
                 (if Stop > Start and then Text (Stop - 1) = Character'Val (13)
                  then Text (Start .. Stop - 2)
                  elsif Stop > Start
                  then Text (Start .. Stop - 1)
                  else "");
            begin
               if Line'Length >= Prefix'Length
                 and then Line (Line'First .. Line'First + Prefix'Length - 1) = Prefix
               then
                  return Line (Line'First + Prefix'Length .. Line'Last);
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      return "";
   end Pointer_Line;

   function Has_LFS_Version (Text : String) return Boolean is
      Version_Line : constant String :=
        "version https://git-lfs.github.com/spec/v1";
   begin
      return Text'Length >= Version_Line'Length
        and then Text (Text'First .. Text'First + Version_Line'Length - 1)
          = Version_Line
        and then
          (Text'Length = Version_Line'Length
           or else Text (Text'First + Version_Line'Length) = Character'Val (10)
           or else Text (Text'First + Version_Line'Length) = Character'Val (13));
   end Has_LFS_Version;

   function Ends_With (Value, Suffix : String) return Boolean;

   function Starts_With (Value, Prefix : String) return Boolean;

   function Is_LFS_Pointer (Content : String) return Boolean is
      Oid  : constant String := Pointer_Line (Content, "oid sha256:");
      Size : constant String := Pointer_Line (Content, "size ");
   begin
      return Has_LFS_Version (Content)
        and then Oid'Length = 64
        and then Is_Hex (Oid)
        and then Size'Length > 0;
   end Is_LFS_Pointer;

   function Attribute_Filter_LFS
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String) return Boolean
   is
      function Basename (Path : String) return String is
      begin
         for I in reverse Path'Range loop
            if Path (I) = '/' then
               return Path (I + 1 .. Path'Last);
            end if;
         end loop;

         return Path;
      end Basename;

      function Matches (Pattern, Path : String) return Boolean is
         Name : constant String := Basename (Path);
      begin
         if Pattern'Length = 0 then
            return False;
         elsif Pattern = Path or else Pattern = Name then
            return True;
         elsif Pattern'Length > 2
           and then Pattern (Pattern'First) = '*'
           and then Pattern (Pattern'First + 1) = '.'
         then
            declare
               Suffix : constant String := Pattern (Pattern'First + 1 .. Pattern'Last);
            begin
               return Ends_With (Name, Suffix);
            end;
         else
            return False;
         end if;
      end Matches;

      function File_Has_Filter (Path : String) return Boolean is
      begin
         if not Ada.Directories.Exists (Path)
           or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
         then
            return False;
         end if;

         declare
            Text  : constant String := Version.Files.Read_Binary_File (Path);
            Start : Natural := Text'First;
         begin
            while Start <= Text'Last loop
               declare
                  Stop : Natural := Start;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String :=
                       (if Stop > Start
                        and then Text (Stop - 1) = Character'Val (13)
                        then Text (Start .. Stop - 2)
                        elsif Stop > Start
                        then Text (Start .. Stop - 1)
                        else "");
                     Sep : Natural := 0;
                  begin
                     for I in Line'Range loop
                        if Line (I) = ' ' or else Line (I) = Character'Val (9) then
                           Sep := I;
                           exit;
                        end if;
                     end loop;

                     if Sep /= 0 then
                        declare
                           Pattern : constant String := Line (Line'First .. Sep - 1);
                           Attrs   : constant String := Line (Sep + 1 .. Line'Last);
                        begin
                           if Pattern'Length > 0
                             and then Pattern (Pattern'First) /= '#'
                             and then Matches (Pattern, Relative_Path)
                             and then Starts_With (Attrs, "filter=lfs")
                           then
                              return True;
                           elsif Pattern'Length > 0
                             and then Pattern (Pattern'First) /= '#'
                             and then Matches (Pattern, Relative_Path)
                             and then Ada.Strings.Fixed.Index (Attrs, " filter=lfs") /= 0
                           then
                              return True;
                           end if;
                        end;
                     end if;
                  end;

                  Start := Stop + 1;
               end;
            end loop;
         end;

         return False;
      end File_Has_Filter;

      Root_Attr : constant String :=
        Join (Version.Repository.Root_Path (Repo), ".gitattributes");
      Info_Attr : constant String :=
        Join (Join (Version.Repository.Common_Git_Dir (Repo), "info"), "attributes");
   begin
      return File_Has_Filter (Root_Attr) or else File_Has_Filter (Info_Attr);
   end Attribute_Filter_LFS;

   function Clean_Pointer (Oid : String; Size : Natural) return String is
   begin
      return "version https://git-lfs.github.com/spec/v1" & Character'Val (10)
        & "oid sha256:" & Oid & Character'Val (10)
        & "size" & Natural'Image (Size) & Character'Val (10);
   end Clean_Pointer;

   function Parse_Size (Text : String) return Natural is
      Result : Natural := 0;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with "invalid LFS pointer size";
      end if;

      for C of Text loop
         if C not in '0' .. '9' then
            raise Ada.IO_Exceptions.Data_Error with "invalid LFS pointer size";
         end if;

         Result := Result * 10 + Character'Pos (C) - Character'Pos ('0');
      end loop;

      return Result;
   end Parse_Size;

   function Ends_With (Value, Suffix : String) return Boolean is
   begin
      return Value'Length >= Suffix'Length
        and then Value (Value'Last - Suffix'Length + 1 .. Value'Last) = Suffix;
   end Ends_With;

   function Starts_With (Value, Prefix : String) return Boolean is
   begin
      return Value'Length >= Prefix'Length
        and then Value (Value'First .. Value'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

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

   --  Reduce a remote/LFS URL to its LFS endpoint base (the ".../info/lfs"
   --  root under which /objects/batch and /locks live). Empty for an empty URL.
   function LFS_Base_Url (Url : String; Is_LFS_Url : Boolean) return String is
      Batch : constant String := "/objects/batch";
      Clean : constant String := Strip_Trailing_Slashes (Url);
   begin
      if Clean'Length = 0 then
         return "";
      elsif Ends_With (Clean, Batch) then
         return Clean (Clean'First .. Clean'Last - Batch'Length);
      elsif Is_LFS_Url or else Ends_With (Clean, "/info/lfs") then
         return Clean;
      else
         return Clean & "/info/lfs";
      end if;
   end LFS_Base_Url;

   function LFS_Batch_Url (Url : String; Is_LFS_Url : Boolean) return String is
      Base : constant String := LFS_Base_Url (Url, Is_LFS_Url);
   begin
      return (if Base'Length = 0 then "" else Base & "/objects/batch");
   end LFS_Batch_Url;

   function LFS_Locks_Url (Url : String; Is_LFS_Url : Boolean) return String is
      Base : constant String := LFS_Base_Url (Url, Is_LFS_Url);
   begin
      return (if Base'Length = 0 then "" else Base & "/locks");
   end LFS_Locks_Url;

   function LFS_Headers (Content_Type : Boolean) return Http_Client.Headers.Header_List is
      Headers : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;

      procedure Set (Name, Value : String) is
      begin
         if Http_Client.Headers.Set (Headers, Name, Value) /= Http_Client.Errors.Ok then
            raise Ada.IO_Exceptions.Data_Error with "set LFS HTTP header";
         end if;
      end Set;
   begin
      Set ("Accept", "application/vnd.git-lfs+json");
      Set ("Accept-Encoding", "identity");

      if Content_Type then
         Set ("Content-Type", "application/vnd.git-lfs+json");
      end if;

      return Headers;
   end LFS_Headers;

   function LFS_HTTP_Options (Max_Body : Natural)
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
      Options.Max_Body_Size := Max_Body;
      return Options;
   end LFS_HTTP_Options;

   --  Extract "user[:pass]@" userinfo from an HTTP URL's authority.
   procedure LFS_Userinfo
     (Url : String;
      User, Pass : out Ada.Strings.Unbounded.Unbounded_String;
      Has_Pass   : out Boolean)
   is
      use Ada.Strings.Unbounded;
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
   end LFS_Userinfo;

   --  Return Url with any "user[:pass]@" userinfo removed (httpclient's URI
   --  parser rejects userinfo).
   function LFS_Strip_Userinfo (Url : String) return String is
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
   end LFS_Strip_Userinfo;

   --  Host (without userinfo/port) of an http(s) URL, or "".
   function LFS_Host (Url : String) return String is
      Scheme_End : Natural := 0;
      Start      : Natural;
   begin
      if Url'Length < 3 then
         return "";
      end if;
      for I in Url'First .. Url'Last - 2 loop
         if Url (I .. I + 2) = "://" then
            Scheme_End := I + 2;
            exit;
         end if;
      end loop;
      if Scheme_End = 0 or else Scheme_End >= Url'Last then
         return "";
      end if;
      Start := Scheme_End + 1;
      --  skip any userinfo
      for I in Start .. Url'Last loop
         exit when Url (I) = '/' or else Url (I) = '?' or else Url (I) = '#';
         if Url (I) = '@' then
            Start := I + 1;
         end if;
      end loop;
      declare
         Stop : Natural := Url'Last;
      begin
         for I in Start .. Url'Last loop
            if Url (I) = ':' or else Url (I) = '/'
              or else Url (I) = '?' or else Url (I) = '#'
            then
               Stop := I - 1;
               exit;
            end if;
         end loop;
         return Url (Start .. Stop);
      end;
   end LFS_Host;

   --  When Endpoint carries "user[:pass]@" userinfo and Target is on the same
   --  host without its own userinfo, inject the userinfo into Target so a
   --  same-server object transfer reuses the batch endpoint's credentials
   --  (git-lfs behaviour). Otherwise Target is returned unchanged.
   function Propagate_Userinfo (Endpoint, Target : String) return String is
      use Ada.Strings.Unbounded;
      E_User, E_Pass : Unbounded_String;
      E_Has_Pass     : Boolean;
      T_User, T_Pass : Unbounded_String;
      T_Has_Pass     : Boolean;
      Scheme_End     : Natural := 0;
   begin
      LFS_Userinfo (Endpoint, E_User, E_Pass, E_Has_Pass);
      if Length (E_User) = 0 then
         return Target;
      end if;
      LFS_Userinfo (Target, T_User, T_Pass, T_Has_Pass);
      if Length (T_User) > 0 then
         return Target;   --  Target already has its own userinfo
      end if;
      if LFS_Host (Endpoint) /= LFS_Host (Target)
        or else LFS_Host (Target) = ""
      then
         return Target;   --  never leak credentials to a different host
      end if;
      for I in Target'First .. Target'Last - 2 loop
         if Target (I .. I + 2) = "://" then
            Scheme_End := I + 2;
            exit;
         end if;
      end loop;
      if Scheme_End = 0 then
         return Target;
      end if;
      declare
         Userinfo : constant String :=
           To_String (E_User)
           & (if E_Has_Pass then ":" & To_String (E_Pass) else "");
      begin
         return Target (Target'First .. Scheme_End) & Userinfo & "@"
           & Target (Scheme_End + 1 .. Target'Last);
      end;
   end Propagate_Userinfo;

   --  Issue an LFS HTTP request and return the response body. On an HTTP 401
   --  the request is retried once with credentials from `credential fill`
   --  (git's LFS auth over the batch/object endpoints); URL userinfo is used
   --  for pre-emptive authentication.
   procedure Read_HTTP_Request
     (Url          : String;
      Method       : Http_Client.Types.Method_Name;
      Headers      : Http_Client.Headers.Header_List;
      Payload      : String;
      Max_Body     : Natural;
      Context      : String;
      Tolerate     : Boolean;
      Body_Out     : out Ada.Strings.Unbounded.Unbounded_String;
      Code_Out     : out Http_Client.Types.Status_Code)
   is
      use Ada.Strings.Unbounded;
      use Ada.Streams;

      Clean_Url : constant String := LFS_Strip_Userinfo (Url);
      URI     : Http_Client.URI.URI_Reference;
      Stream  : Http_Client.Response_Streams.Streaming_Response;
      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        LFS_HTTP_Options (Max_Body);
      Buffer  : Stream_Element_Array (1 .. 16 * 1024);
      Last    : Stream_Element_Offset;
      Status  : Http_Client.Errors.Result_Status;
      Result_Body : Unbounded_String;
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

      procedure Do_Open (Use_Auth : Boolean; U, P : String) is
         Request : Http_Client.Requests.Request;
      begin
         if Http_Client.URI.Parse (Clean_Url, URI) /= Http_Client.Errors.Ok then
            raise Ada.IO_Exceptions.Data_Error with "parse LFS HTTP URI";
         end if;
         if Http_Client.Requests.Create
           (Method    => Method,
            URI       => URI,
            Item      => Request,
            Headers   => Headers,
            Payload   => Payload,
            Auto_Host => True) /= Http_Client.Errors.Ok
         then
            raise Ada.IO_Exceptions.Data_Error with "create LFS HTTP request";
         end if;
         if Use_Auth then
            declare
               Req2 : Http_Client.Requests.Request;
            begin
               if Http_Client.Auth.Set_Basic_Authorization (Request, U, P, Req2)
                 /= Http_Client.Errors.Ok
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "set LFS Basic authorization";
               end if;
               Request := Req2;
            end;
         end if;
         Status := Http_Client.Response_Streams.Open (Request, Stream, Options);
         if Status /= Http_Client.Errors.Ok then
            raise Ada.IO_Exceptions.Data_Error with
              Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
         end if;
         Opened := True;
         Code := Http_Client.Response_Streams.Status_Code (Stream);
      end Do_Open;
   begin
      LFS_Userinfo (Url, URL_User, URL_Pass, Has_URL_Pass);
      Do_Open (Has_URL_Pass, To_String (URL_User), To_String (URL_Pass));

      if Code = 401 then
         Close_Stream;
         declare
            Cred      : Version.Credential.Credential;
            Repo      : Version.Repository.Repository_Handle;
            Have_Repo : Boolean := True;
         begin
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
               if Code in 200 .. 299 or else Code = 409 then
                  if Have_Repo then
                     Version.Credential.Approve (Repo, Cred);
                  end if;
               elsif Code = 401 then
                  if Have_Repo then
                     Version.Credential.Reject (Repo, Cred);
                  end if;
                  if not Tolerate then
                     Close_Stream;
                     raise Ada.IO_Exceptions.Data_Error
                       with Context & ": HTTP 401 (authentication failed)";
                  end if;
               end if;
            elsif not Tolerate then
               Close_Stream;
               raise Ada.IO_Exceptions.Data_Error
                 with Context & ": HTTP 401 (no credentials available)";
            end if;
         end;
      end if;

      if not Tolerate and then (Code < 200 or else Code > 299) then
         Close_Stream;
         raise Ada.IO_Exceptions.Data_Error with
           Context & ": HTTP" & Integer'Image (Code);
      end if;

      --  Tolerated error whose stream was already closed (e.g. a 401 with no
      --  credentials available): report the status with no body.
      if not Opened then
         Body_Out := Null_Unbounded_String;
         Code_Out := Code;
         return;
      end if;

      while not Http_Client.Response_Streams.End_Of_Body (Stream) loop
         Status := Http_Client.Response_Streams.Read_Some (Stream, Buffer, Last);
         exit when Status = Http_Client.Errors.End_Of_Stream;

         if Status /= Http_Client.Errors.Ok then
            raise Ada.IO_Exceptions.Data_Error with
              Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
         end if;

         if Last >= Buffer'First then
            declare
               Chunk : String (1 .. Natural (Last - Buffer'First + 1));
               J     : Natural := Chunk'First;
            begin
               for I in Buffer'First .. Last loop
                  Chunk (J) := Character'Val (Buffer (I));
                  J := J + 1;
               end loop;

               Append (Result_Body, Chunk);
            end;
         end if;
      end loop;

      Status := Http_Client.Response_Streams.Close (Stream);
      Opened := False;
      if Status /= Http_Client.Errors.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
      end if;

      Body_Out := Result_Body;
      Code_Out := Code;

   exception
      when others =>
         Close_Stream;
         raise;
   end Read_HTTP_Request;

   --  Convenience wrapper: issue an LFS HTTP request that must succeed (2xx),
   --  returning the response body (raises on any error status).
   function Read_HTTP_Body
     (Url          : String;
      Method       : Http_Client.Types.Method_Name;
      Headers      : Http_Client.Headers.Header_List;
      Payload      : String;
      Max_Body     : Natural;
      Context      : String) return String
   is
      Body_Text : Ada.Strings.Unbounded.Unbounded_String;
      Code      : Http_Client.Types.Status_Code;
   begin
      Read_HTTP_Request
        (Url      => Url,
         Method   => Method,
         Headers  => Headers,
         Payload  => Payload,
         Max_Body => Max_Body,
         Context  => Context,
         Tolerate => False,
         Body_Out => Body_Text,
         Code_Out => Code);
      return Ada.Strings.Unbounded.To_String (Body_Text);
   end Read_HTTP_Body;

   function Json_String_After (Text : String; Marker : String) return String is
      Pos : Natural := 0;
   begin
      if Text'Length < Marker'Length then
         return "";
      end if;

      for I in Text'First .. Text'Last - Marker'Length + 1 loop
         if Text (I .. I + Marker'Length - 1) = Marker then
            Pos := I + Marker'Length;
            exit;
         end if;
      end loop;

      if Pos = 0 then
         return "";
      end if;

      while Pos <= Text'Last
        and then Text (Pos) in ' ' | Character'Val (9) | Character'Val (10) | Character'Val (13)
      loop
         Pos := Pos + 1;
      end loop;

      if Pos > Text'Last or else Text (Pos) /= ':' then
         return "";
      end if;

      Pos := Pos + 1;
      while Pos <= Text'Last
        and then Text (Pos) in ' ' | Character'Val (9) | Character'Val (10) | Character'Val (13)
      loop
         Pos := Pos + 1;
      end loop;

      if Pos > Text'Last or else Text (Pos) /= '"' then
         return "";
      end if;

      Pos := Pos + 1;

      declare
         use Ada.Strings.Unbounded;
         Result : Unbounded_String;
      begin
         while Pos <= Text'Last loop
            if Text (Pos) = '"' then
               return To_String (Result);
            elsif Text (Pos) = Character'Val (92) then
               Pos := Pos + 1;
               if Pos > Text'Last then
                  return "";
               end if;

               case Text (Pos) is
                  when '"' | '/' => Append (Result, Text (Pos));
                  when 'n' => Append (Result, Character'Val (10));
                  when 'r' => Append (Result, Character'Val (13));
                  when 't' => Append (Result, Character'Val (9));
                  when others => return "";
               end case;
            else
               Append (Result, Text (Pos));
            end if;

            Pos := Pos + 1;
         end loop;
      end;

      return "";
   end Json_String_After;

   function Download_Href (Batch_Response : String) return String is
   begin
      return Json_String_After (Batch_Response, """href""");
   end Download_Href;

   function LFS_Object_Path
     (Repo : Version.Repository.Repository_Handle; Oid : String) return String;

   function Fetch_From_HTTP_LFS
     (Repo          : Version.Repository.Repository_Handle;
      Url           : String;
      Is_LFS_Url    : Boolean;
      Oid           : String;
      Expected_Size : Natural) return Boolean
   is
      Batch_Url : constant String := LFS_Batch_Url (Url, Is_LFS_Url);
      Payload   : constant String :=
        "{""operation"":""download"",""transfers"":[""basic""],""objects"":[{""oid"":"""
        & Oid & """,""size"":" & Natural'Image (Expected_Size) & "}]}";
   begin
      if Batch_Url'Length = 0 then
         return False;
      end if;

      declare
         Batch_Response : constant String :=
           Read_HTTP_Body
             (Url      => Batch_Url,
              Method   => Http_Client.Types.POST,
              Headers  => LFS_Headers (Content_Type => True),
              Payload  => Payload,
              Max_Body => 1_048_576,
              Context  => "LFS batch download");
         Href : constant String := Download_Href (Batch_Response);
      begin
         if Href'Length = 0 then
            return False;
         end if;

         declare
            Media : constant String :=
              Read_HTTP_Body
                (Url      => Propagate_Userinfo (Url, Href),
                 Method   => Http_Client.Types.GET,
                 Headers  => LFS_Headers (Content_Type => False),
                 Payload  => "",
                 Max_Body => Expected_Size,
                 Context  => "LFS media download");
         begin
            if Media'Length /= Expected_Size then
               raise Ada.IO_Exceptions.Data_Error with
                 "LFS object size does not match pointer";
            end if;

            Version.Files.Write_Binary_File_Atomic
              (LFS_Object_Path (Repo, Oid), Media);
            return True;
         end;
      end;
   end Fetch_From_HTTP_LFS;

   function Read_SSH_Stream (Stream : in out Version.Transport.Ssh.Ssh_Stream) return String is
      use Ada.Strings.Unbounded;
      use Ada.Streams;

      Buffer : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Result : Unbounded_String;
   begin
      loop
         Version.Transport.Ssh.Read_Some (Stream, Buffer, Last);
         exit when Last < Buffer'First;

         declare
            Chunk : String (1 .. Natural (Last - Buffer'First + 1));
            J     : Natural := Chunk'First;
         begin
            for I in Buffer'First .. Last loop
               Chunk (J) := Character'Val (Buffer (I));
               J := J + 1;
            end loop;

            Append (Result, Chunk);
         end;
      end loop;

      return To_String (Result);
   end Read_SSH_Stream;

   function Fetch_From_SSH_LFS
     (Repo          : Version.Repository.Repository_Handle;
      Url           : String;
      Oid           : String;
      Expected_Size : Natural) return Boolean
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Opened : Boolean := False;
   begin
      Version.Transport.Ssh.Open_LFS_Authenticate
        (Url => Url, Operation => "download", Stream => Stream);
      Opened := True;

      declare
         Auth_Response : constant String := Read_SSH_Stream (Stream);
      begin
         Version.Transport.Ssh.Close (Stream);
         Opened := False;

         declare
            Href : constant String := Json_String_After (Auth_Response, """href""");
         begin
            if Href'Length = 0 then
               return False;
            end if;

            return Fetch_From_HTTP_LFS
              (Repo          => Repo,
               Url           => Href,
               Is_LFS_Url    => True,
               Oid           => Oid,
               Expected_Size => Expected_Size);
         end;
      end;

   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others =>
                  null;
            end;
         end if;

         raise;
   end Fetch_From_SSH_LFS;

   --------------------------------------------------------------------------
   --  git-lfs-transfer: the pure-SSH LFS protocol (pkt-line framed; media
   --  bytes travel over the SSH channel, no HTTP handoff).
   --------------------------------------------------------------------------

   function To_SEA (S : String) return Ada.Streams.Stream_Element_Array is
      use Ada.Streams;
      R : Stream_Element_Array (1 .. Stream_Element_Offset (S'Length));
      J : Stream_Element_Offset := R'First;
   begin
      for I in S'Range loop
         R (J) := Stream_Element (Character'Pos (S (I)));
         J := J + 1;
      end loop;
      return R;
   end To_SEA;

   procedure Send_Data
     (Stream : in out Version.Transport.Ssh.Ssh_Stream; S : String) is
   begin
      Version.Transport.Ssh.Write
        (Stream, Version.Pkt_Line.Encode_Data (To_SEA (S)));
   end Send_Data;

   procedure Send_Flush (Stream : in out Version.Transport.Ssh.Ssh_Stream) is
   begin
      Version.Transport.Ssh.Write (Stream, Version.Pkt_Line.Encode_Flush);
   end Send_Flush;

   procedure Send_Delim (Stream : in out Version.Transport.Ssh.Ssh_Stream) is
   begin
      Version.Transport.Ssh.Write (Stream, Version.Pkt_Line.Encode_Delimiter);
   end Send_Delim;

   --  Read the next pkt-line, pulling more bytes from the SSH channel via the
   --  parser as needed. Payload is the (text) content of a data packet.
   procedure Next_Packet
     (Stream  : in out Version.Transport.Ssh.Ssh_Stream;
      Parser  : in out Version.Pkt_Line.Parser;
      Kind    : out Version.Pkt_Line.Packet_Kind;
      Payload : out Ada.Strings.Unbounded.Unbounded_String)
   is
      use Ada.Streams;
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Parse_Status;
      use type Version.Pkt_Line.Packet_Kind;
      Buf    : Stream_Element_Array (1 .. 16 * 1024);
      Last   : Stream_Element_Offset;
      Pkt    : Stream_Element_Array (1 .. 65_520);
      P_Last : Stream_Element_Offset;
      Status : Version.Pkt_Line.Parse_Status;
   begin
      Payload := Null_Unbounded_String;
      loop
         Status := Version.Pkt_Line.Next (Parser, Kind, Pkt, P_Last);
         if Status = Version.Pkt_Line.Ok then
            if Kind = Version.Pkt_Line.Data_Packet
              and then P_Last >= Pkt'First
            then
               declare
                  S : String (1 .. Natural (P_Last - Pkt'First + 1));
                  J : Natural := S'First;
               begin
                  for I in Pkt'First .. P_Last loop
                     S (J) := Character'Val (Pkt (I));
                     J := J + 1;
                  end loop;
                  Payload := To_Unbounded_String (S);
               end;
            end if;
            return;
         elsif Status = Version.Pkt_Line.Need_More_Data then
            Version.Transport.Ssh.Read_Some (Stream, Buf, Last);
            if Last < Buf'First then
               raise Ada.IO_Exceptions.Data_Error with
                 "LFS SSH transfer: unexpected end of stream";
            end if;
            Version.Pkt_Line.Feed (Parser, Buf (Buf'First .. Last));
         else
            raise Ada.IO_Exceptions.Data_Error with
              "LFS SSH transfer: malformed pkt-line";
         end if;
      end loop;
   end Next_Packet;

   function Trim_LF (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First
        and then (S (Last) = Character'Val (10) or else S (Last) = Character'Val (13))
      loop
         Last := Last - 1;
      end loop;
      return S (S'First .. Last);
   end Trim_LF;

   function Status_Code_Of (Line : String) return Natural is
      use Ada.Strings;
      T  : constant String := Trim_LF (Line);
      Sp : constant Natural := Fixed.Index (T, " ");
   begin
      if Sp = 0 or else Sp >= T'Last then
         return 0;
      end if;
      return Natural'Value (Fixed.Trim (T (Sp + 1 .. T'Last), Both));
   exception
      when others => return 0;
   end Status_Code_Of;

   procedure Skip_To_Flush
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser)
   is
      use type Version.Pkt_Line.Packet_Kind;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Ada.Strings.Unbounded.Unbounded_String;
   begin
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
      end loop;
   end Skip_To_Flush;

   --  Read a simple "status <code>" response (status packet then flush).
   function Read_Status
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser)
      return Natural
   is
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Packet_Kind;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Unbounded_String;
      Code    : Natural := 0;
      First   : Boolean := True;
   begin
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
         if First and then Kind = Version.Pkt_Line.Data_Packet then
            Code := Status_Code_Of (To_String (Payload));
            First := False;
         end if;
      end loop;
      return Code;
   end Read_Status;

   --  Read a batch response and return the action for Oid ("upload"/"download"
   --  /"noop"/…), or "" on a non-200 status or missing entry.
   function Read_Batch_Action
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser;
      Oid    : String)
      return String
   is
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Packet_Kind;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Unbounded_String;
      First   : Boolean := True;
      Action  : Unbounded_String;
   begin
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
         if Kind = Version.Pkt_Line.Data_Packet then
            declare
               Line : constant String := Trim_LF (To_String (Payload));
            begin
               if First then
                  if Status_Code_Of (Line) /= 200 then
                     return "";
                  end if;
                  First := False;
               elsif Line'Length > Oid'Length
                 and then Line (Line'First .. Line'First + Oid'Length - 1) = Oid
               then
                  --  "<oid> <size> <action> [id=...]" -> third token.
                  declare
                     use Ada.Strings;
                     P2 : constant Natural :=
                       Fixed.Index (Line, " ", Line'First + Oid'Length);
                     P3 : constant Natural :=
                       (if P2 = 0 then 0 else Fixed.Index (Line, " ", P2 + 1));
                  begin
                     if P3 /= 0 then
                        declare
                           P4 : constant Natural := Fixed.Index (Line, " ", P3 + 1);
                           Stop : constant Natural :=
                             (if P4 = 0 then Line'Last else P4 - 1);
                        begin
                           Action := To_Unbounded_String (Line (P3 + 1 .. Stop));
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      return To_String (Action);
   end Read_Batch_Action;

   --  Read a get-object response: status, optional headers, delim, object data.
   procedure Read_Object_Response
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser;
      Code   : out Natural;
      Data   : out Ada.Strings.Unbounded.Unbounded_String)
   is
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Packet_Kind;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Unbounded_String;
      First   : Boolean := True;
      In_Data : Boolean := False;
   begin
      Code := 0;
      Data := Null_Unbounded_String;
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
         if Kind = Version.Pkt_Line.Delimiter_Packet then
            In_Data := True;
         elsif Kind = Version.Pkt_Line.Data_Packet then
            if First then
               Code := Status_Code_Of (To_String (Payload));
               First := False;
            elsif In_Data then
               Append (Data, To_String (Payload));
            end if;   --  header lines before the delimiter are ignored
         end if;
      end loop;
   end Read_Object_Response;

   --  Perform the version handshake (read caps, select version 1).
   function Handshake
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser)
      return Boolean
   is
      LF : constant Character := Character'Val (10);
   begin
      Skip_To_Flush (Stream, Parser);              --  capability advertisement
      Send_Data (Stream, "version 1" & LF);
      Send_Flush (Stream);
      return Read_Status (Stream, Parser) = 200;
   end Handshake;

   function Fetch_From_SSH_Transfer
     (Repo          : Version.Repository.Repository_Handle;
      Url           : String;
      Oid           : String;
      Expected_Size : Natural)
      return Boolean
   is
      use Ada.Strings;
      LF       : constant Character := Character'Val (10);
      Size_Img : constant String := Fixed.Trim (Natural'Image (Expected_Size), Both);
      Stream   : Version.Transport.Ssh.Ssh_Stream;
      Parser   : Version.Pkt_Line.Parser;
      Opened   : Boolean := False;
   begin
      Version.Transport.Ssh.Open_LFS_Transfer (Url, "download", Stream);
      Opened := True;
      if not Handshake (Stream, Parser) then
         Version.Transport.Ssh.Close (Stream);
         return False;
      end if;

      Send_Data (Stream, "batch" & LF);
      Send_Data (Stream, "transfer=ssh" & LF);
      Send_Data (Stream, "hash-algo=sha256" & LF);
      Send_Delim (Stream);
      Send_Data (Stream, Oid & " " & Size_Img & LF);
      Send_Flush (Stream);
      if Read_Batch_Action (Stream, Parser, Oid) /= "download" then
         Send_Data (Stream, "quit" & LF);
         Send_Flush (Stream);
         Version.Transport.Ssh.Close (Stream);
         return False;
      end if;

      Send_Data (Stream, "get-object " & Oid & LF);
      Send_Data (Stream, "size=" & Size_Img & LF);
      Send_Flush (Stream);
      declare
         use Ada.Strings.Unbounded;
         Code : Natural;
         Data : Unbounded_String;
      begin
         Read_Object_Response (Stream, Parser, Code, Data);
         if Code /= 200 or else Length (Data) /= Expected_Size then
            Version.Transport.Ssh.Close (Stream);
            return False;
         end if;
         Version.Files.Write_Binary_File_Atomic
           (LFS_Object_Path (Repo, Oid), To_String (Data));
      end;

      Send_Data (Stream, "quit" & LF);
      Send_Flush (Stream);
      Version.Transport.Ssh.Close (Stream);
      return True;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         return False;
   end Fetch_From_SSH_Transfer;

   function Upload_To_SSH_Transfer
     (Repo : Version.Repository.Repository_Handle;
      Url  : String;
      Oid  : String)
      return Boolean
   is
      use Ada.Strings;
      LF         : constant Character := Character'Val (10);
      Local_Path : constant String := LFS_Object_Path (Repo, Oid);
      Stream     : Version.Transport.Ssh.Ssh_Stream;
      Parser     : Version.Pkt_Line.Parser;
      Opened     : Boolean := False;
   begin
      if not Ada.Directories.Exists (Local_Path)
        or else Ada.Directories.Kind (Local_Path)
                /= Ada.Directories.Ordinary_File
      then
         return False;
      end if;

      declare
         Content  : constant String := Version.Files.Read_Binary_File (Local_Path);
         Size_Img : constant String :=
           Fixed.Trim (Natural'Image (Content'Length), Both);
      begin
         Version.Transport.Ssh.Open_LFS_Transfer (Url, "upload", Stream);
         Opened := True;
         if not Handshake (Stream, Parser) then
            Version.Transport.Ssh.Close (Stream);
            return False;
         end if;

         Send_Data (Stream, "batch" & LF);
         Send_Data (Stream, "transfer=ssh" & LF);
         Send_Data (Stream, "hash-algo=sha256" & LF);
         Send_Delim (Stream);
         Send_Data (Stream, Oid & " " & Size_Img & LF);
         Send_Flush (Stream);
         declare
            Action : constant String := Read_Batch_Action (Stream, Parser, Oid);
         begin
            if Action = "noop" then
               Send_Data (Stream, "quit" & LF);
               Send_Flush (Stream);
               Version.Transport.Ssh.Close (Stream);
               return True;      --  already present on the server
            elsif Action /= "upload" then
               Version.Transport.Ssh.Close (Stream);
               return False;
            end if;
         end;

         --  put-object: header, delimiter, then the media bytes in chunks.
         Send_Data (Stream, "put-object " & Oid & LF);
         Send_Data (Stream, "size=" & Size_Img & LF);
         Send_Delim (Stream);
         declare
            Pos : Natural := Content'First;
         begin
            while Pos <= Content'Last loop
               declare
                  Stop : constant Natural :=
                    Natural'Min (Content'Last, Pos + 60_000 - 1);
               begin
                  Send_Data (Stream, Content (Pos .. Stop));
                  Pos := Stop + 1;
               end;
            end loop;
         end;
         Send_Flush (Stream);
         if Read_Status (Stream, Parser) /= 200 then
            Version.Transport.Ssh.Close (Stream);
            return False;
         end if;

         --  verify-object (best effort; the object is already stored).
         Send_Data (Stream, "verify-object " & Oid & LF);
         Send_Data (Stream, "size=" & Size_Img & LF);
         Send_Flush (Stream);
         declare
            Ignored : constant Natural := Read_Status (Stream, Parser);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;

         Send_Data (Stream, "quit" & LF);
         Send_Flush (Stream);
         Version.Transport.Ssh.Close (Stream);
         return True;
      end;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         return False;
   end Upload_To_SSH_Transfer;

   function LFS_Object_Path_Under (Base : String; Oid : String) return String is
   begin
      return
        Join
          (Join
             (Join
                (Join (Base, "objects"),
                 Oid (Oid'First .. Oid'First + 1)),
              Oid (Oid'First + 2 .. Oid'First + 3)),
           Oid);
   end LFS_Object_Path_Under;

   function LFS_Object_Path_In_Git_Dir (Git_Dir : String; Oid : String) return String is
   begin
      return LFS_Object_Path_Under (Join (Git_Dir, "lfs"), Oid);
   end LFS_Object_Path_In_Git_Dir;

   function Existing_LFS_Object_Path (Base : String; Oid : String) return String is
      Info_LFS : constant String := "/info/lfs";
      Clean    : constant String :=
        (if Ends_With (Base, Info_LFS)
         then Base (Base'First .. Base'Last - Info_LFS'Length)
         else Base);

      function Ordinary (Path : String) return Boolean is
      begin
         return Ada.Directories.Exists (Path)
           and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File;
      end Ordinary;
   begin
      declare
         Path : constant String := LFS_Object_Path_Under (Clean, Oid);
      begin
         if Ordinary (Path) then
            return Path;
         end if;
      end;

      declare
         Path : constant String := LFS_Object_Path_In_Git_Dir (Clean, Oid);
      begin
         if Ordinary (Path) then
            return Path;
         end if;
      end;

      declare
         Path : constant String := LFS_Object_Path_In_Git_Dir (Join (Clean, ".git"), Oid);
      begin
         if Ordinary (Path) then
            return Path;
         end if;
      end;

      begin
         declare
            Git_Dir : constant String := Version.Transport.Local.Resolve_Git_Dir (Clean);
            Path    : constant String := LFS_Object_Path_In_Git_Dir (Git_Dir, Oid);
         begin
            if Ordinary (Path) then
               return Path;
            end if;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error |
              Ada.IO_Exceptions.Use_Error =>
            null;
      end;

      return "";
   end Existing_LFS_Object_Path;

   function Local_Source_From_Url (Url : String) return String is
   begin
      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            return Version.Transport.Strip_File_Scheme (Url);
         when others =>
            return "";
      end case;
   end Local_Source_From_Url;

   function Config_Value_Or_Empty
     (Repo : Version.Repository.Repository_Handle;
      Name : String) return String
   is
   begin
      if Version.Config.Has_Key (Repo, Name) then
         return Version.Config.Get_Value (Repo, Name);
      end if;

      return "";
   end Config_Value_Or_Empty;

   function Fetch_From_Local_Source
     (Repo          : Version.Repository.Repository_Handle;
      Source        : String;
      Oid           : String;
      Expected_Size : Natural) return Boolean
   is
      Source_Path : constant String := Existing_LFS_Object_Path (Source, Oid);
   begin
      if Source_Path'Length = 0 then
         return False;
      end if;

      declare
         Media : constant String := Version.Files.Read_Binary_File (Source_Path);
      begin
         if Media'Length /= Expected_Size then
            raise Ada.IO_Exceptions.Data_Error with
              "LFS object size does not match pointer";
         end if;

         Version.Files.Write_Binary_File_Atomic
           (LFS_Object_Path (Repo, Oid), Media);
         return True;
      end;
   end Fetch_From_Local_Source;

   function Fetch_LFS_Object
     (Repo          : Version.Repository.Repository_Handle;
      Oid           : String;
      Expected_Size : Natural) return Boolean
   is
      LFS_Url : constant String := Config_Value_Or_Empty (Repo, "lfs.url");
      Origin  : constant String := Config_Value_Or_Empty (Repo, "remote.origin.url");
   begin
      if LFS_Url'Length > 0 then
         declare
            Source : constant String := Local_Source_From_Url (LFS_Url);
         begin
            if Source'Length > 0
              and then Fetch_From_Local_Source (Repo, Source, Oid, Expected_Size)
            then
               return True;
            elsif Version.Transport.Detect_Transport (LFS_Url) = Version.Transport.Http_Transport
              and then Fetch_From_HTTP_LFS
                (Repo          => Repo,
                 Url           => LFS_Url,
                 Is_LFS_Url    => True,
                 Oid           => Oid,
                 Expected_Size => Expected_Size)
            then
               return True;
            elsif Version.Transport.Detect_Transport (LFS_Url) = Version.Transport.Ssh_Transport
              and then (Fetch_From_SSH_Transfer
                          (Repo, LFS_Url, Oid, Expected_Size)
                        or else Fetch_From_SSH_LFS
                          (Repo          => Repo,
                           Url           => LFS_Url,
                           Oid           => Oid,
                           Expected_Size => Expected_Size))
            then
               return True;
            end if;
         end;
      end if;

      if Origin'Length > 0 then
         declare
            Source : constant String := Local_Source_From_Url (Origin);
         begin
            if Source'Length > 0
              and then Fetch_From_Local_Source (Repo, Source, Oid, Expected_Size)
            then
               return True;
            elsif Version.Transport.Detect_Transport (Origin) = Version.Transport.Http_Transport
              and then Fetch_From_HTTP_LFS
                (Repo          => Repo,
                 Url           => Origin,
                 Is_LFS_Url    => False,
                 Oid           => Oid,
                 Expected_Size => Expected_Size)
            then
               return True;
            elsif Version.Transport.Detect_Transport (Origin) = Version.Transport.Ssh_Transport
              and then (Fetch_From_SSH_Transfer
                          (Repo, Origin, Oid, Expected_Size)
                        or else Fetch_From_SSH_LFS
                          (Repo          => Repo,
                           Url           => Origin,
                           Oid           => Oid,
                           Expected_Size => Expected_Size))
            then
               return True;
            end if;
         end;
      end if;

      return False;
   end Fetch_LFS_Object;

   function LFS_Object_Path
     (Repo : Version.Repository.Repository_Handle; Oid : String) return String
   is
   begin
      return
        Join
          (Join
             (Join
                (Join
                   (Join (Version.Repository.Common_Git_Dir (Repo), "lfs"),
                    "objects"),
                 Oid (Oid'First .. Oid'First + 1)),
              Oid (Oid'First + 2 .. Oid'First + 3)),
           Oid);
   end LFS_Object_Path;

   function Clean_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
   begin
      if not Attribute_Filter_LFS (Repo, Relative_Path) or else Is_LFS_Pointer (Content) then
         return Content;
      end if;

      declare
         Oid : constant String := Version.Hash.Sha256_Hex (Content);
         Path : constant String := LFS_Object_Path (Repo, Oid);
      begin
         if not Ada.Directories.Exists (Path) then
            Version.Files.Write_Binary_File_Atomic (Path, Content);
         elsif Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
           or else Version.Files.Read_Binary_File (Path) /= Content
         then
            raise Ada.IO_Exceptions.Data_Error with
              "conflicting LFS object storage path";
         end if;

         return Clean_Pointer (Oid, Content'Length);
      end;
   end Clean_Content;

   function Worktree_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
   begin
      --  Smudge whenever the path is attributed filter=lfs OR the content is
      --  itself an LFS pointer (content-sniffing), matching how merge writes
      --  worktree files; Smudge_Content returns non-pointer content unchanged.
      if Attribute_Filter_LFS (Repo, Relative_Path)
        or else Has_LFS_Version (Content)
      then
         return Smudge_Content
           (Repo          => Repo,
            Relative_Path => Relative_Path,
            Content       => Content);
      else
         return Content;
      end if;
   end Worktree_Content;

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
      pragma Unreferenced (Relative_Path);
   begin
      if not Has_LFS_Version (Content) then
         return Content;
      end if;

      declare
         Oid  : constant String := Pointer_Line (Content, "oid sha256:");
         Size : constant String := Pointer_Line (Content, "size ");
      begin
         if Oid'Length /= 64 or else not Is_Hex (Oid) or else Size'Length = 0 then
            return Content;
         end if;

         declare
            Path          : constant String := LFS_Object_Path (Repo, Oid);
            Expected_Size : constant Natural := Parse_Size (Size);
         begin
            if not Ada.Directories.Exists (Path)
              or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
            then
               if not Fetch_LFS_Object (Repo, Oid, Expected_Size) then
                  return Content;
               end if;
            end if;

            declare
               Media : constant String := Version.Files.Read_Binary_File (Path);
            begin
               if Media'Length /= Expected_Size then
                  raise Ada.IO_Exceptions.Data_Error with
                    "LFS object size does not match pointer";
               end if;

               return Media;
            end;
         end;
      end;
   end Smudge_Content;

   function Upload_To_Local_Source
     (Repo   : Version.Repository.Repository_Handle;
      Source : String;
      Oid    : String)
      return Boolean
   is
      Local_Path : constant String := LFS_Object_Path (Repo, Oid);
      Dest_Path  : constant String := LFS_Object_Path_Under (Source, Oid);
   begin
      if Ada.Directories.Exists (Dest_Path)
        and then Ada.Directories.Kind (Dest_Path) = Ada.Directories.Ordinary_File
      then
         return True;   --  already present on the remote store
      end if;

      if not Ada.Directories.Exists (Local_Path)
        or else Ada.Directories.Kind (Local_Path)
                /= Ada.Directories.Ordinary_File
      then
         return False;  --  nothing cached locally to upload
      end if;

      Version.Files.Write_Binary_File_Atomic
        (Dest_Path, Version.Files.Read_Binary_File (Local_Path));
      return True;
   end Upload_To_Local_Source;

   --  Read a JSON string literal starting at Text (Pos) = '"'; advance Pos to
   --  just past the closing quote and return the unescaped content.
   function Read_Json_String (Text : String; Pos : in out Natural) return String
   is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
   begin
      if Pos > Text'Last or else Text (Pos) /= '"' then
         return "";
      end if;
      Pos := Pos + 1;
      while Pos <= Text'Last loop
         if Text (Pos) = '"' then
            Pos := Pos + 1;
            return To_String (Result);
         elsif Text (Pos) = Character'Val (92) then
            Pos := Pos + 1;
            exit when Pos > Text'Last;
            case Text (Pos) is
               when 'n' => Append (Result, Character'Val (10));
               when 'r' => Append (Result, Character'Val (13));
               when 't' => Append (Result, Character'Val (9));
               when others => Append (Result, Text (Pos));
            end case;
         else
            Append (Result, Text (Pos));
         end if;
         Pos := Pos + 1;
      end loop;
      return To_String (Result);
   end Read_Json_String;

   --  The first "href" string appearing after Section (e.g. """upload""") in a
   --  batch response object, or "" when the section/href is absent.
   function Href_In_Section (Text, Section : String) return String is
      Pos : Natural := 0;
   begin
      if Text'Length < Section'Length then
         return "";
      end if;
      for I in Text'First .. Text'Last - Section'Length + 1 loop
         if Text (I .. I + Section'Length - 1) = Section then
            Pos := I;
            exit;
         end if;
      end loop;
      if Pos = 0 then
         return "";
      end if;
      return Json_String_After (Text (Pos .. Text'Last), """href""");
   end Href_In_Section;

   --  Apply the "header" object of a batch-response action (Section) as request
   --  headers (e.g. an Authorization token the LFS server requires on the PUT).
   procedure Apply_Action_Headers
     (Text    : String;
      Section : String;
      Headers : in out Http_Client.Headers.Header_List)
   is
      Marker  : constant String := """header""";
      Sec_Pos : Natural := 0;
      Pos     : Natural := 0;
   begin
      if Text'Length < Section'Length then
         return;
      end if;
      for I in Text'First .. Text'Last - Section'Length + 1 loop
         if Text (I .. I + Section'Length - 1) = Section then
            Sec_Pos := I;
            exit;
         end if;
      end loop;
      if Sec_Pos = 0 then
         return;
      end if;
      for I in Sec_Pos .. Text'Last - Marker'Length + 1 loop
         if Text (I .. I + Marker'Length - 1) = Marker then
            Pos := I + Marker'Length;
            exit;
         end if;
      end loop;
      if Pos = 0 then
         return;
      end if;
      while Pos <= Text'Last and then Text (Pos) /= '{' loop
         exit when Text (Pos) = ',' or else Text (Pos) = '}';
         Pos := Pos + 1;
      end loop;
      if Pos > Text'Last or else Text (Pos) /= '{' then
         return;
      end if;
      Pos := Pos + 1;
      loop
         while Pos <= Text'Last
           and then Text (Pos) in ' ' | ',' | Character'Val (9)
                                 | Character'Val (10) | Character'Val (13)
         loop
            Pos := Pos + 1;
         end loop;
         exit when Pos > Text'Last or else Text (Pos) /= '"';
         declare
            Key : constant String := Read_Json_String (Text, Pos);
         begin
            while Pos <= Text'Last and then Text (Pos) /= ':' loop
               Pos := Pos + 1;
            end loop;
            Pos := Pos + 1;
            while Pos <= Text'Last
              and then Text (Pos) in ' ' | Character'Val (9)
            loop
               Pos := Pos + 1;
            end loop;
            exit when Pos > Text'Last or else Text (Pos) /= '"';
            declare
               Val : constant String := Read_Json_String (Text, Pos);
            begin
               if Key'Length > 0
                 and then Http_Client.Headers.Set (Headers, Key, Val)
                          /= Http_Client.Errors.Ok
               then
                  null;
               end if;
            end;
         end;
      end loop;
   end Apply_Action_Headers;

   --  Upload the local cached LFS object to an HTTP LFS store: batch POST with
   --  operation=upload, PUT the bytes to the returned action href (applying its
   --  header), then POST the verify action when present. Mirrors the download
   --  path (Fetch_From_HTTP_LFS).
   function Upload_To_HTTP_LFS
     (Repo       : Version.Repository.Repository_Handle;
      Url        : String;
      Is_LFS_Url : Boolean;
      Oid        : String)
      return Boolean
   is
      Local_Path : constant String := LFS_Object_Path (Repo, Oid);
      Batch_Url  : constant String := LFS_Batch_Url (Url, Is_LFS_Url);
   begin
      if Batch_Url'Length = 0
        or else not Ada.Directories.Exists (Local_Path)
        or else Ada.Directories.Kind (Local_Path)
                /= Ada.Directories.Ordinary_File
      then
         return False;
      end if;

      declare
         Content : constant String :=
           Version.Files.Read_Binary_File (Local_Path);
         Payload : constant String :=
           "{""operation"":""upload"",""transfers"":[""basic""],""objects"":[{""oid"":"""
           & Oid & """,""size"":" & Natural'Image (Content'Length) & "}]}";
         Batch_Response : constant String :=
           Read_HTTP_Body
             (Url      => Batch_Url,
              Method   => Http_Client.Types.POST,
              Headers  => LFS_Headers (Content_Type => True),
              Payload  => Payload,
              Max_Body => 1_048_576,
              Context  => "LFS batch upload");
         Upload_Href : constant String :=
           Href_In_Section (Batch_Response, """upload""");
         Verify_Href : constant String :=
           Href_In_Section (Batch_Response, """verify""");
      begin
         if Upload_Href'Length = 0 then
            --  No upload action: the object is already present, unless the
            --  server reported an error for it.
            return Ada.Strings.Fixed.Index (Batch_Response, """error""") = 0;
         end if;

         declare
            Put_Headers : Http_Client.Headers.Header_List :=
              Http_Client.Headers.Empty;
         begin
            if Http_Client.Headers.Set
                 (Put_Headers, "Accept-Encoding", "identity")
               /= Http_Client.Errors.Ok
            then
               raise Ada.IO_Exceptions.Data_Error with "set LFS upload header";
            end if;
            Apply_Action_Headers (Batch_Response, """upload""", Put_Headers);
            declare
               Ignored : constant String :=
                 Read_HTTP_Body
                   (Url      => Propagate_Userinfo (Url, Upload_Href),
                    Method   => Http_Client.Types.PUT,
                    Headers  => Put_Headers,
                    Payload  => Content,
                    Max_Body => 4096,
                    Context  => "LFS media upload");
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end;

         if Verify_Href'Length > 0 then
            declare
               V_Headers : Http_Client.Headers.Header_List :=
                 LFS_Headers (Content_Type => True);
               V_Payload : constant String :=
                 "{""oid"":""" & Oid & """,""size"":"
                 & Natural'Image (Content'Length) & "}";
            begin
               Apply_Action_Headers (Batch_Response, """verify""", V_Headers);
               declare
                  Ignored : constant String :=
                    Read_HTTP_Body
                      (Url      => Propagate_Userinfo (Url, Verify_Href),
                       Method   => Http_Client.Types.POST,
                       Headers  => V_Headers,
                       Payload  => V_Payload,
                       Max_Body => 4096,
                       Context  => "LFS verify");
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
            end;
         end if;
         return True;
      end;
   end Upload_To_HTTP_LFS;

   --  Upload over SSH: `git-lfs-authenticate <path> upload` yields an HTTP LFS
   --  endpoint href, then the HTTP batch/PUT flow runs against it. Mirrors
   --  Fetch_From_SSH_LFS.
   function Upload_To_SSH_LFS
     (Repo : Version.Repository.Repository_Handle;
      Url  : String;
      Oid  : String)
      return Boolean
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Opened : Boolean := False;
   begin
      Version.Transport.Ssh.Open_LFS_Authenticate
        (Url => Url, Operation => "upload", Stream => Stream);
      Opened := True;

      declare
         Auth_Response : constant String := Read_SSH_Stream (Stream);
      begin
         Version.Transport.Ssh.Close (Stream);
         Opened := False;

         declare
            Href : constant String :=
              Json_String_After (Auth_Response, """href""");
         begin
            if Href'Length = 0 then
               return False;
            end if;
            return Upload_To_HTTP_LFS
              (Repo => Repo, Url => Href, Is_LFS_Url => True, Oid => Oid);
         end;
      end;

   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others =>
                  null;
            end;
         end if;
         raise;
   end Upload_To_SSH_LFS;

   function Upload_Object
     (Repo        : Version.Repository.Repository_Handle;
      Oid         : String;
      Remote_Name : String)
      return Boolean
   is
      LFS_Url : constant String := Config_Value_Or_Empty (Repo, "lfs.url");
      Origin  : constant String :=
        Config_Value_Or_Empty (Repo, "remote." & Remote_Name & ".url");

      --  Try one candidate store URL (Is_LFS marks a bare LFS endpoint vs a
      --  git remote URL whose /info/lfs endpoint is derived).
      function Try (Candidate : String; Is_LFS : Boolean) return Boolean is
      begin
         if Candidate'Length = 0 then
            return False;
         end if;
         declare
            Source : constant String := Local_Source_From_Url (Candidate);
         begin
            if Source'Length > 0
              and then Upload_To_Local_Source (Repo, Source, Oid)
            then
               return True;
            end if;
         end;
         case Version.Transport.Detect_Transport (Candidate) is
            when Version.Transport.Http_Transport =>
               return Upload_To_HTTP_LFS (Repo, Candidate, Is_LFS, Oid);
            when Version.Transport.Ssh_Transport =>
               return Upload_To_SSH_Transfer (Repo, Candidate, Oid)
                 or else Upload_To_SSH_LFS (Repo, Candidate, Oid);
            when others =>
               return False;
         end case;
      end Try;
   begin
      if Oid'Length /= 64 or else not Is_Hex (Oid) then
         return False;
      end if;
      return Try (LFS_Url, Is_LFS => True)
        or else Try (Origin, Is_LFS => False);
   end Upload_Object;

   procedure Upload_Referenced_Objects
     (Repo        : Version.Repository.Repository_Handle;
      Commit_Id   : Version.Objects.Hex_Object_Id;
      Remote_Name : String)
   is
      Ignored : Boolean;
      pragma Unreferenced (Ignored);
   begin
      for Obj_Id of Version.History.Reachable_Objects (Repo, Commit_Id) loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Obj_Id);
         begin
            if Version.Objects.Kind (Obj) = Version.Objects.Blob_Object then
               declare
                  Content : constant String := Version.Objects.Content (Obj);
               begin
                  if Is_LFS_Pointer (Content) then
                     declare
                        Oid : constant String :=
                          Pointer_Line (Content, "oid sha256:");
                     begin
                        if Oid'Length = 64 and then Is_Hex (Oid) then
                           Ignored := Upload_Object (Repo, Oid, Remote_Name);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Upload_Referenced_Objects;

   --------------------------------------------------------------------------
   --  File locking (git-lfs lock / unlock / locks)
   --------------------------------------------------------------------------

   LF : constant Character := Character'Val (10);

   function Json_Escape (S : String) return String is
      use Ada.Strings.Unbounded;
      R : Unbounded_String;
   begin
      for C of S loop
         case C is
            when '"'              => Append (R, "\""");
            when '\'              => Append (R, "\\");
            when Character'Val (10) => Append (R, "\n");
            when Character'Val (13) => Append (R, "\r");
            when Character'Val (9)  => Append (R, "\t");
            when others           => Append (R, C);
         end case;
      end loop;
      return To_String (R);
   end Json_Escape;

   function Url_Query_Escape (S : String) return String is
      use Ada.Strings.Unbounded;
      Hex : constant String := "0123456789ABCDEF";
      R   : Unbounded_String;
   begin
      for C of S loop
         if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~'
         then
            Append (R, C);
         else
            Append (R, '%');
            Append (R, Hex (Character'Pos (C) / 16 + 1));
            Append (R, Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return To_String (R);
   end Url_Query_Escape;

   --  Return the first JSON object ("{...}") appearing after Marker, or "".
   function Json_Object_After (Text : String; Marker : String) return String is
      Pos    : Natural := 0;
      Start  : Natural;
      Depth  : Natural := 0;
      In_Str : Boolean := False;
      I      : Natural;
   begin
      if Text'Length < Marker'Length then
         return "";
      end if;
      for P in Text'First .. Text'Last - Marker'Length + 1 loop
         if Text (P .. P + Marker'Length - 1) = Marker then
            Pos := P + Marker'Length;
            exit;
         end if;
      end loop;
      if Pos = 0 then
         return "";
      end if;
      I := Pos;
      while I <= Text'Last and then Text (I) /= '{' loop
         I := I + 1;
      end loop;
      if I > Text'Last then
         return "";
      end if;
      Start := I;
      while I <= Text'Last loop
         declare
            C : constant Character := Text (I);
         begin
            if In_Str then
               if C = '\' then
                  I := I + 1;
               elsif C = '"' then
                  In_Str := False;
               end if;
            elsif C = '"' then
               In_Str := True;
            elsif C = '{' then
               Depth := Depth + 1;
            elsif C = '}' then
               Depth := Depth - 1;
               if Depth = 0 then
                  return Text (Start .. I);
               end if;
            end if;
         end;
         I := I + 1;
      end loop;
      return "";
   end Json_Object_After;

   function Parse_Lock_Object
     (Obj : String; Owned : Boolean) return Lock_Info
   is
      use Ada.Strings.Unbounded;
      Owner_Obj : constant String := Json_Object_After (Obj, """owner""");
   begin
      return
        (Id        => To_Unbounded_String (Json_String_After (Obj, """id""")),
         Path      => To_Unbounded_String (Json_String_After (Obj, """path""")),
         Owner     => To_Unbounded_String
                        (Json_String_After (Owner_Obj, """name""")),
         Locked_At => To_Unbounded_String
                        (Json_String_After (Obj, """locked_at""")),
         Owned     => Owned);
   end Parse_Lock_Object;

   --  Append every lock object inside the JSON array following Array_Key
   --  (e.g. """locks""", """ours""") to Vec, marked with Owned.
   procedure Collect_Locks
     (Text      : String;
      Array_Key : String;
      Owned     : Boolean;
      Vec       : in out Lock_Vectors.Vector)
   is
      Pos : Natural := 0;
      I   : Natural;
   begin
      if Text'Length < Array_Key'Length then
         return;
      end if;
      for P in Text'First .. Text'Last - Array_Key'Length + 1 loop
         if Text (P .. P + Array_Key'Length - 1) = Array_Key then
            Pos := P + Array_Key'Length;
            exit;
         end if;
      end loop;
      if Pos = 0 then
         return;
      end if;
      I := Pos;
      while I <= Text'Last and then Text (I) /= '[' loop
         exit when Text (I) = '{';
         I := I + 1;
      end loop;
      if I > Text'Last or else Text (I) /= '[' then
         return;
      end if;
      I := I + 1;
      loop
         while I <= Text'Last
           and then Text (I) in ' ' | ',' | Character'Val (9)
                              | Character'Val (10) | Character'Val (13)
         loop
            I := I + 1;
         end loop;
         exit when I > Text'Last or else Text (I) = ']';
         if Text (I) = '{' then
            declare
               Start  : constant Natural := I;
               Depth  : Natural := 0;
               In_Str : Boolean := False;
               Done   : Boolean := False;
            begin
               while I <= Text'Last and then not Done loop
                  declare
                     C : constant Character := Text (I);
                  begin
                     if In_Str then
                        if C = '\' then
                           I := I + 1;
                        elsif C = '"' then
                           In_Str := False;
                        end if;
                     elsif C = '"' then
                        In_Str := True;
                     elsif C = '{' then
                        Depth := Depth + 1;
                     elsif C = '}' then
                        Depth := Depth - 1;
                        if Depth = 0 then
                           Vec.Append
                             (Parse_Lock_Object (Text (Start .. I), Owned));
                           Done := True;
                        end if;
                     end if;
                  end;
                  I := I + 1;
               end loop;
            end;
         else
            I := I + 1;
         end if;
      end loop;
   end Collect_Locks;

   function Message_Suffix
     (Body_Text : Ada.Strings.Unbounded.Unbounded_String) return String
   is
      Msg : constant String :=
        Json_String_After
          (Ada.Strings.Unbounded.To_String (Body_Text), """message""");
   begin
      return (if Msg'Length > 0 then " (" & Msg & ")" else "");
   end Message_Suffix;

   function Current_Ref
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      declare
         Branch : constant String := Version.Refs.Current_Branch_Name (Repo);
      begin
         return (if Branch'Length = 0 then "" else "refs/heads/" & Branch);
      end;
   exception
      when others =>
         return "";   --  detached HEAD / unborn branch: no ref filter
   end Current_Ref;

   procedure Resolve_Lock_Endpoint
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : out Ada.Strings.Unbounded.Unbounded_String;
      Is_LFS      : out Boolean)
   is
      use Ada.Strings.Unbounded;
      LFS_Url : constant String := Config_Value_Or_Empty (Repo, "lfs.url");
   begin
      if LFS_Url'Length > 0 then
         Url := To_Unbounded_String (LFS_Url);
         Is_LFS := True;
      else
         Url := To_Unbounded_String
           (Config_Value_Or_Empty (Repo, "remote." & Remote_Name & ".url"));
         Is_LFS := False;
      end if;
   end Resolve_Lock_Endpoint;

   function Locks_Headers
     (Content_Type : Boolean; Auth : String)
      return Http_Client.Headers.Header_List
   is
      Headers : Http_Client.Headers.Header_List := LFS_Headers (Content_Type);
   begin
      if Auth'Length > 0
        and then Http_Client.Headers.Set (Headers, "Authorization", Auth)
                   /= Http_Client.Errors.Ok
      then
         raise Ada.IO_Exceptions.Data_Error with "set LFS Authorization header";
      end if;
      return Headers;
   end Locks_Headers;

   ----------------------------  HTTP lock routes  --------------------------

   function Create_Lock_HTTP
     (Route : String; Path, Ref, Auth : String) return Lock_Info
   is
      use Ada.Strings.Unbounded;
      Payload : constant String :=
        "{""path"":""" & Json_Escape (Path) & """"
        & (if Ref'Length > 0
           then ",""ref"":{""name"":""" & Json_Escape (Ref) & """}"
           else "")
        & "}";
      Body_Text : Unbounded_String;
      Code      : Http_Client.Types.Status_Code;
   begin
      Read_HTTP_Request
        (Url      => Route,
         Method   => Http_Client.Types.POST,
         Headers  => Locks_Headers (True, Auth),
         Payload  => Payload,
         Max_Body => 1_000_000,
         Context  => "LFS lock",
         Tolerate => True,
         Body_Out => Body_Text,
         Code_Out => Code);
      if Code in 200 .. 299 then
         return Parse_Lock_Object
           (Json_Object_After (To_String (Body_Text), """lock"""), False);
      elsif Code = 409 then
         declare
            Existing : constant Lock_Info :=
              Parse_Lock_Object
                (Json_Object_After (To_String (Body_Text), """lock"""), False);
         begin
            raise Ada.IO_Exceptions.Use_Error with
              Path & " already locked"
              & (if Length (Existing.Owner) > 0
                 then " by " & To_String (Existing.Owner) else "");
         end;
      else
         raise Ada.IO_Exceptions.Use_Error with
           "LFS lock failed: HTTP" & Http_Client.Types.Status_Code'Image (Code)
           & Message_Suffix (Body_Text);
      end if;
   end Create_Lock_HTTP;

   procedure List_Locks_HTTP
     (Locks_Base : String;
      Path, Id, Ref, Auth : String;
      Verify     : Boolean;
      Vec        : in out Lock_Vectors.Vector)
   is
      use Ada.Strings.Unbounded;
      Body_Text : Unbounded_String;
      Code      : Http_Client.Types.Status_Code;
   begin
      if Verify then
         declare
            Payload : constant String :=
              "{" & (if Ref'Length > 0
                     then """ref"":{""name"":""" & Json_Escape (Ref) & """}"
                     else "") & "}";
         begin
            Read_HTTP_Request
              (Url      => Locks_Base & "/verify",
               Method   => Http_Client.Types.POST,
               Headers  => Locks_Headers (True, Auth),
               Payload  => Payload,
               Max_Body => 4_000_000,
               Context  => "LFS locks",
               Tolerate => True,
               Body_Out => Body_Text,
               Code_Out => Code);
            if Code not in 200 .. 299 then
               raise Ada.IO_Exceptions.Use_Error with
                 "LFS locks failed: HTTP"
                 & Http_Client.Types.Status_Code'Image (Code)
                 & Message_Suffix (Body_Text);
            end if;
            Collect_Locks (To_String (Body_Text), """ours""", True, Vec);
            Collect_Locks (To_String (Body_Text), """theirs""", False, Vec);
         end;
      else
         declare
            Query : Unbounded_String;
            procedure Add (Name, Value : String) is
            begin
               if Value'Length > 0 then
                  if Length (Query) > 0 then
                     Append (Query, "&");
                  end if;
                  Append (Query, Name & "=" & Url_Query_Escape (Value));
               end if;
            end Add;
         begin
            Add ("path", Path);
            Add ("id", Id);
            --  git-lfs scopes an unfiltered listing by refspec, but omits it
            --  once a path/id filter is present (so an unlock-by-path finds a
            --  lock created on another branch). Match that.
            if Path'Length = 0 and then Id'Length = 0 then
               Add ("refspec", Ref);
            end if;
            Read_HTTP_Request
              (Url      => Locks_Base
                 & (if Length (Query) > 0 then "?" & To_String (Query) else ""),
               Method   => Http_Client.Types.GET,
               Headers  => Locks_Headers (False, Auth),
               Payload  => "",
               Max_Body => 4_000_000,
               Context  => "LFS locks",
               Tolerate => True,
               Body_Out => Body_Text,
               Code_Out => Code);
            if Code not in 200 .. 299 then
               raise Ada.IO_Exceptions.Use_Error with
                 "LFS locks failed: HTTP"
                 & Http_Client.Types.Status_Code'Image (Code)
                 & Message_Suffix (Body_Text);
            end if;
            Collect_Locks (To_String (Body_Text), """locks""", False, Vec);
         end;
      end if;
   end List_Locks_HTTP;

   procedure Delete_Lock_HTTP
     (Locks_Base : String;
      Id         : String;
      Force      : Boolean;
      Ref, Auth  : String)
   is
      use Ada.Strings.Unbounded;
      Payload : constant String :=
        "{""force"":" & (if Force then "true" else "false")
        & (if Ref'Length > 0
           then ",""ref"":{""name"":""" & Json_Escape (Ref) & """}"
           else "") & "}";
      Body_Text : Unbounded_String;
      Code      : Http_Client.Types.Status_Code;
   begin
      Read_HTTP_Request
        (Url      => Locks_Base & "/" & Id & "/unlock",
         Method   => Http_Client.Types.POST,
         Headers  => Locks_Headers (True, Auth),
         Payload  => Payload,
         Max_Body => 1_000_000,
         Context  => "LFS unlock",
         Tolerate => True,
         Body_Out => Body_Text,
         Code_Out => Code);
      if Code not in 200 .. 299 then
         raise Ada.IO_Exceptions.Use_Error with
           "LFS unlock failed: HTTP"
           & Http_Client.Types.Status_Code'Image (Code)
           & Message_Suffix (Body_Text);
      end if;
   end Delete_Lock_HTTP;

   ------------------------  pure-SSH git-lfs-transfer  ---------------------

   --  Read a "status <code>" + key=value args response (lock / unlock),
   --  filling Result from id / path / locked-at / ownername / owner args.
   function Read_Lock_Response
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser;
      Result : out Lock_Info)
      return Natural
   is
      use Ada.Strings;
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Packet_Kind;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Unbounded_String;
      Code    : Natural := 0;
      First   : Boolean := True;
   begin
      Result := (others => <>);
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
         if Kind = Version.Pkt_Line.Data_Packet then
            declare
               L  : constant String := Trim_LF (To_String (Payload));
               Eq : constant Natural := Fixed.Index (L, "=");
            begin
               if First then
                  Code := Status_Code_Of (L);
                  First := False;
               elsif Eq > L'First then
                  declare
                     Key : constant String := L (L'First .. Eq - 1);
                     Val : constant String := L (Eq + 1 .. L'Last);
                  begin
                     if Key = "id" then
                        Result.Id := To_Unbounded_String (Val);
                     elsif Key = "path" then
                        Result.Path := To_Unbounded_String (Val);
                     elsif Key = "locked-at" then
                        Result.Locked_At := To_Unbounded_String (Val);
                     elsif Key = "ownername" then
                        Result.Owner := To_Unbounded_String (Val);
                     elsif Key = "owner" then
                        Result.Owned := Val = "ours";
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      return Code;
   end Read_Lock_Response;

   --  Read a list-lock response: "status 200", delim, then per-lock spec lines
   --  of the form "<key> <lock-id> <value>" ("lock <id>" opens each entry).
   function Read_List_Lock_Response
     (Stream : in out Version.Transport.Ssh.Ssh_Stream;
      Parser : in out Version.Pkt_Line.Parser;
      Vec    : in out Lock_Vectors.Vector)
      return Natural
   is
      use Ada.Strings;
      use Ada.Strings.Unbounded;
      use type Version.Pkt_Line.Packet_Kind;
      Kind     : Version.Pkt_Line.Packet_Kind;
      Payload  : Unbounded_String;
      Code     : Natural := 0;
      First    : Boolean := True;
      In_Data  : Boolean := False;
      Cur      : Lock_Info;
      Have_Cur : Boolean := False;

      procedure Flush_Cur is
      begin
         if Have_Cur then
            Vec.Append (Cur);
            Have_Cur := False;
         end if;
      end Flush_Cur;
   begin
      loop
         Next_Packet (Stream, Parser, Kind, Payload);
         exit when Kind = Version.Pkt_Line.Flush_Packet;
         if Kind = Version.Pkt_Line.Delimiter_Packet then
            In_Data := True;
         elsif Kind = Version.Pkt_Line.Data_Packet then
            declare
               L  : constant String := Trim_LF (To_String (Payload));
               Sp : constant Natural := Fixed.Index (L, " ");
            begin
               if First then
                  Code := Status_Code_Of (L);
                  First := False;
               elsif In_Data and then Sp > L'First then
                  declare
                     Key  : constant String := L (L'First .. Sp - 1);
                     Rest : constant String := L (Sp + 1 .. L'Last);
                  begin
                     if Key = "lock" then
                        Flush_Cur;
                        Cur := (others => <>);
                        Cur.Id := To_Unbounded_String (Rest);
                        Have_Cur := True;
                     else
                        declare
                           Sp2 : constant Natural := Fixed.Index (Rest, " ");
                           Val : constant String :=
                             (if Sp2 = 0 then "" else Rest (Sp2 + 1 .. Rest'Last));
                        begin
                           if Key = "path" then
                              Cur.Path := To_Unbounded_String (Val);
                           elsif Key = "locked-at" then
                              Cur.Locked_At := To_Unbounded_String (Val);
                           elsif Key = "ownername" then
                              Cur.Owner := To_Unbounded_String (Val);
                           elsif Key = "owner" then
                              Cur.Owned := Val = "ours";
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      Flush_Cur;
      return Code;
   end Read_List_Lock_Response;

   procedure Try_SSH_Lock
     (Url, Path, Ref : String;
      Result         : out Lock_Info;
      Available      : out Boolean)
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Parser : Version.Pkt_Line.Parser;
      Opened : Boolean := False;
   begin
      Available := False;
      Result := (others => <>);
      Version.Transport.Ssh.Open_LFS_Transfer (Url, "upload", Stream);
      Opened := True;
      if not Handshake (Stream, Parser) then
         Version.Transport.Ssh.Close (Stream);
         return;
      end if;
      Available := True;
      Send_Data (Stream, "lock" & LF);
      Send_Data (Stream, "path=" & Path & LF);
      if Ref'Length > 0 then
         Send_Data (Stream, "refname=" & Ref & LF);
      end if;
      Send_Flush (Stream);
      declare
         use Ada.Strings.Unbounded;
         Code : constant Natural := Read_Lock_Response (Stream, Parser, Result);
      begin
         Send_Data (Stream, "quit" & LF);
         Send_Flush (Stream);
         Version.Transport.Ssh.Close (Stream);
         Opened := False;
         if Code in 200 | 201 then
            return;
         elsif Code = 409 then
            raise Ada.IO_Exceptions.Use_Error with
              Path & " already locked"
              & (if Length (Result.Owner) > 0
                 then " by " & To_String (Result.Owner) else "");
         else
            raise Ada.IO_Exceptions.Use_Error with
              "LFS lock failed (status" & Natural'Image (Code) & ")";
         end if;
      end;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         if Available then
            raise;                --  genuine protocol/lock error: surface it
         end if;
         Available := False;      --  connect/handshake failure: fall back
   end Try_SSH_Lock;

   procedure Try_SSH_Unlock
     (Url, Id, Ref : String;
      Force        : Boolean;
      Available    : out Boolean)
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Parser : Version.Pkt_Line.Parser;
      Opened : Boolean := False;
   begin
      Available := False;
      Version.Transport.Ssh.Open_LFS_Transfer (Url, "upload", Stream);
      Opened := True;
      if not Handshake (Stream, Parser) then
         Version.Transport.Ssh.Close (Stream);
         return;
      end if;
      Available := True;
      Send_Data (Stream, "unlock " & Id & LF);
      if Force then
         Send_Data (Stream, "force=true" & LF);
      end if;
      if Ref'Length > 0 then
         Send_Data (Stream, "refname=" & Ref & LF);
      end if;
      Send_Flush (Stream);
      declare
         Dummy : Lock_Info;
         Code  : constant Natural := Read_Lock_Response (Stream, Parser, Dummy);
      begin
         Send_Data (Stream, "quit" & LF);
         Send_Flush (Stream);
         Version.Transport.Ssh.Close (Stream);
         Opened := False;
         if Code not in 200 | 201 then
            raise Ada.IO_Exceptions.Use_Error with
              "LFS unlock failed (status" & Natural'Image (Code) & ")";
         end if;
      end;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         if Available then
            raise;
         end if;
         Available := False;
   end Try_SSH_Unlock;

   procedure Try_SSH_List_Locks
     (Url, Path, Id, Ref : String;
      Vec                : in out Lock_Vectors.Vector;
      Available          : out Boolean)
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Parser : Version.Pkt_Line.Parser;
      Opened : Boolean := False;
   begin
      Available := False;
      Version.Transport.Ssh.Open_LFS_Transfer (Url, "download", Stream);
      Opened := True;
      if not Handshake (Stream, Parser) then
         Version.Transport.Ssh.Close (Stream);
         return;
      end if;
      Available := True;
      Send_Data (Stream, "list-lock" & LF);
      if Path'Length > 0 then
         Send_Data (Stream, "path=" & Path & LF);
      end if;
      if Id'Length > 0 then
         Send_Data (Stream, "id=" & Id & LF);
      end if;
      if Ref'Length > 0 and then Path'Length = 0 and then Id'Length = 0 then
         Send_Data (Stream, "refspec=" & Ref & LF);
      end if;
      Send_Flush (Stream);
      declare
         Code : constant Natural :=
           Read_List_Lock_Response (Stream, Parser, Vec);
      begin
         Send_Data (Stream, "quit" & LF);
         Send_Flush (Stream);
         Version.Transport.Ssh.Close (Stream);
         Opened := False;
         if Code /= 200 then
            raise Ada.IO_Exceptions.Use_Error with
              "LFS list-lock failed (status" & Natural'Image (Code) & ")";
         end if;
      end;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         if Available then
            raise;
         end if;
         Available := False;
   end Try_SSH_List_Locks;

   --  Run git-lfs-authenticate over SSH; return the HTTP LFS href and any
   --  Authorization header the server hands back (for the SSH -> HTTP path).
   procedure SSH_Authenticate
     (Url, Operation : String;
      Href, Auth     : out Ada.Strings.Unbounded.Unbounded_String)
   is
      use Ada.Strings.Unbounded;
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Opened : Boolean := False;
   begin
      Href := Null_Unbounded_String;
      Auth := Null_Unbounded_String;
      Version.Transport.Ssh.Open_LFS_Authenticate (Url, Operation, Stream);
      Opened := True;
      declare
         Resp : constant String := Read_SSH_Stream (Stream);
      begin
         Version.Transport.Ssh.Close (Stream);
         Opened := False;
         Href := To_Unbounded_String (Json_String_After (Resp, """href"""));
         Auth := To_Unbounded_String
           (Json_String_After
              (Json_Object_After (Resp, """header"""), """Authorization"""));
      end;
   exception
      when others =>
         if Opened then
            begin
               Version.Transport.Ssh.Close (Stream);
            exception
               when others => null;
            end;
         end if;
         raise;
   end SSH_Authenticate;

   ------------------------------  public API  ------------------------------

   function Create_Lock
     (Repo        : Version.Repository.Repository_Handle;
      Path        : String;
      Remote_Name : String := "origin")
      return Lock_Info
   is
      use Ada.Strings.Unbounded;
      Url    : Unbounded_String;
      Is_LFS : Boolean;
      Ref    : constant String := Current_Ref (Repo);
   begin
      Resolve_Lock_Endpoint (Repo, Remote_Name, Url, Is_LFS);
      if Length (Url) = 0 then
         raise Ada.IO_Exceptions.Use_Error with
           "LFS lock: no LFS server configured (set lfs.url or a remote)";
      end if;
      case Version.Transport.Detect_Transport (To_String (Url)) is
         when Version.Transport.Http_Transport =>
            return Create_Lock_HTTP
              (LFS_Locks_Url (To_String (Url), Is_LFS), Path, Ref, "");
         when Version.Transport.Ssh_Transport =>
            declare
               Result : Lock_Info;
               Avail  : Boolean;
            begin
               Try_SSH_Lock (To_String (Url), Path, Ref, Result, Avail);
               if Avail then
                  return Result;
               end if;
               declare
                  Href, Auth : Unbounded_String;
               begin
                  SSH_Authenticate (To_String (Url), "upload", Href, Auth);
                  if Length (Href) = 0 then
                     raise Ada.IO_Exceptions.Use_Error with
                       "LFS lock: SSH remote offers no lock service";
                  end if;
                  return Create_Lock_HTTP
                    (LFS_Locks_Url (To_String (Href), True),
                     Path, Ref, To_String (Auth));
               end;
            end;
         when others =>
            raise Ada.IO_Exceptions.Use_Error with
              "LFS locking requires an HTTP or SSH remote";
      end case;
   end Create_Lock;

   function List_Locks
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String := "origin";
      Path        : String := "";
      Id          : String := "";
      Verify      : Boolean := False)
      return Lock_Array
   is
      use Ada.Strings.Unbounded;
      Url    : Unbounded_String;
      Is_LFS : Boolean;
      Ref    : constant String := Current_Ref (Repo);
      Vec    : Lock_Vectors.Vector;
   begin
      Resolve_Lock_Endpoint (Repo, Remote_Name, Url, Is_LFS);
      if Length (Url) = 0 then
         raise Ada.IO_Exceptions.Use_Error with
           "LFS locks: no LFS server configured (set lfs.url or a remote)";
      end if;
      case Version.Transport.Detect_Transport (To_String (Url)) is
         when Version.Transport.Http_Transport =>
            List_Locks_HTTP
              (LFS_Locks_Url (To_String (Url), Is_LFS),
               Path, Id, Ref, "", Verify, Vec);
         when Version.Transport.Ssh_Transport =>
            declare
               Avail : Boolean;
            begin
               Try_SSH_List_Locks (To_String (Url), Path, Id, Ref, Vec, Avail);
               if not Avail then
                  declare
                     Href, Auth : Unbounded_String;
                  begin
                     SSH_Authenticate
                       (To_String (Url), "download", Href, Auth);
                     if Length (Href) = 0 then
                        raise Ada.IO_Exceptions.Use_Error with
                          "LFS locks: SSH remote offers no lock service";
                     end if;
                     List_Locks_HTTP
                       (LFS_Locks_Url (To_String (Href), True),
                        Path, Id, Ref, To_String (Auth), Verify, Vec);
                  end;
               end if;
            end;
         when others =>
            raise Ada.IO_Exceptions.Use_Error with
              "LFS locking requires an HTTP or SSH remote";
      end case;

      return R : Lock_Array (1 .. Natural (Vec.Length)) do
         for I in R'Range loop
            R (I) := Vec (I);
         end loop;
      end return;
   end List_Locks;

   procedure Delete_Lock
     (Repo        : Version.Repository.Repository_Handle;
      Id          : String := "";
      Path        : String := "";
      Force       : Boolean := False;
      Remote_Name : String := "origin")
   is
      use Ada.Strings.Unbounded;
      Url       : Unbounded_String;
      Is_LFS    : Boolean;
      Ref       : constant String := Current_Ref (Repo);
      Target_Id : Unbounded_String := To_Unbounded_String (Id);
   begin
      if Id'Length = 0 then
         if Path'Length = 0 then
            raise Ada.IO_Exceptions.Use_Error with
              "LFS unlock requires a lock id or path";
         end if;
         declare
            Found : constant Lock_Array :=
              List_Locks (Repo, Remote_Name, Path => Path);
         begin
            if Found'Length = 0 then
               raise Ada.IO_Exceptions.Use_Error with
                 "no lock found for " & Path;
            end if;
            Target_Id := Found (Found'First).Id;
         end;
      end if;

      Resolve_Lock_Endpoint (Repo, Remote_Name, Url, Is_LFS);
      if Length (Url) = 0 then
         raise Ada.IO_Exceptions.Use_Error with
           "LFS unlock: no LFS server configured (set lfs.url or a remote)";
      end if;
      case Version.Transport.Detect_Transport (To_String (Url)) is
         when Version.Transport.Http_Transport =>
            Delete_Lock_HTTP
              (LFS_Locks_Url (To_String (Url), Is_LFS),
               To_String (Target_Id), Force, Ref, "");
         when Version.Transport.Ssh_Transport =>
            declare
               Avail : Boolean;
            begin
               Try_SSH_Unlock
                 (To_String (Url), To_String (Target_Id), Ref, Force, Avail);
               if not Avail then
                  declare
                     Href, Auth : Unbounded_String;
                  begin
                     SSH_Authenticate (To_String (Url), "upload", Href, Auth);
                     if Length (Href) = 0 then
                        raise Ada.IO_Exceptions.Use_Error with
                          "LFS unlock: SSH remote offers no lock service";
                     end if;
                     Delete_Lock_HTTP
                       (LFS_Locks_Url (To_String (Href), True),
                        To_String (Target_Id), Force, Ref, To_String (Auth));
                  end;
               end if;
            end;
         when others =>
            raise Ada.IO_Exceptions.Use_Error with
              "LFS locking requires an HTTP or SSH remote";
      end case;
   end Delete_Lock;

   --------------------------------------------------------------------------
   --  Porcelain support (git-lfs track / ls-files / status / fetch / pointer)
   --------------------------------------------------------------------------

   CR : constant Character := Character'Val (13);
   HT : constant Character := Character'Val (9);

   function Parse_Pointer (Content : String) return Pointer_Info is
      use Ada.Strings.Unbounded;
   begin
      if not Is_LFS_Pointer (Content) then
         return (Is_Pointer => False, Oid => Null_Unbounded_String, Size => 0);
      end if;
      return
        (Is_Pointer => True,
         Oid  => To_Unbounded_String (Pointer_Line (Content, "oid sha256:")),
         Size => Parse_Size (Pointer_Line (Content, "size ")));
   end Parse_Pointer;

   function Build_Pointer (Content : String) return String is
   begin
      return Clean_Pointer (Version.Hash.Sha256_Hex (Content), Content'Length);
   end Build_Pointer;

   function Is_Tracked
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String) return Boolean is
   begin
      return Attribute_Filter_LFS (Repo, Relative_Path);
   end Is_Tracked;

   function Object_Cached
     (Repo : Version.Repository.Repository_Handle;
      Oid  : String) return Boolean is
   begin
      if Oid'Length < 4 then
         return False;
      end if;
      declare
         Path : constant String := LFS_Object_Path (Repo, Oid);
      begin
         return Ada.Directories.Exists (Path)
           and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File;
      end;
   end Object_Cached;

   function Fetch_Object
     (Repo          : Version.Repository.Repository_Handle;
      Oid           : String;
      Expected_Size : Natural) return Boolean is
   begin
      if Object_Cached (Repo, Oid) then
         return True;
      end if;
      return Fetch_LFS_Object (Repo, Oid, Expected_Size);
   end Fetch_Object;

   function Object_Corrupt
     (Repo : Version.Repository.Repository_Handle;
      Oid  : String) return Boolean is
   begin
      if not Object_Cached (Repo, Oid) then
         return False;
      end if;
      declare
         Data : constant String :=
           Version.Files.Read_Binary_File (LFS_Object_Path (Repo, Oid));
      begin
         return Version.Hash.Sha256_Hex (Data) /= Oid;
      end;
   exception
      when others =>
         return True;    --  unreadable cache file: treat as corrupt
   end Object_Corrupt;

   --  Attributes-file line parser shared by the pattern helpers: splits Line
   --  into its pattern and attribute text, reporting whether it declares an
   --  LFS filter for that pattern.
   procedure Split_Attr_Line
     (Line        : String;
      Pattern     : out Ada.Strings.Unbounded.Unbounded_String;
      Is_LFS_Rule : out Boolean)
   is
      use Ada.Strings.Unbounded;
      Sep : Natural := 0;
   begin
      Pattern := Null_Unbounded_String;
      Is_LFS_Rule := False;
      for I in Line'Range loop
         if Line (I) = ' ' or else Line (I) = HT then
            Sep := I;
            exit;
         end if;
      end loop;
      if Sep = 0 then
         return;
      end if;
      declare
         Pat   : constant String := Line (Line'First .. Sep - 1);
         Attrs : constant String := Line (Sep + 1 .. Line'Last);
      begin
         if Pat'Length = 0 or else Pat (Pat'First) = '#' then
            return;
         end if;
         Pattern := To_Unbounded_String (Pat);
         Is_LFS_Rule :=
           Starts_With (Attrs, "filter=lfs")
           or else Ada.Strings.Fixed.Index (Attrs, " filter=lfs") /= 0;
      end;
   end Split_Attr_Line;

   --  Strip a trailing CR (so both LF and CRLF terminated lines parse).
   function Chomp_CR (Line : String) return String is
   begin
      if Line'Length > 0 and then Line (Line'Last) = CR then
         return Line (Line'First .. Line'Last - 1);
      end if;
      return Line;
   end Chomp_CR;

   package Pattern_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Pattern_Entry);

   procedure Collect_Patterns_From
     (File, Source : String; Vec : in out Pattern_Vectors.Vector)
   is
      use Ada.Strings.Unbounded;
   begin
      if not Ada.Directories.Exists (File)
        or else Ada.Directories.Kind (File) /= Ada.Directories.Ordinary_File
      then
         return;
      end if;
      declare
         Text  : constant String := Version.Files.Read_Binary_File (File);
         Start : Natural := Text'First;
      begin
         while Start <= Text'Last loop
            declare
               Stop : Natural := Start;
            begin
               while Stop <= Text'Last
                 and then Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;
               declare
                  Line        : constant String :=
                    Chomp_CR (Text (Start .. Stop - 1));
                  Pat         : Unbounded_String;
                  Is_LFS_Rule : Boolean;
               begin
                  Split_Attr_Line (Line, Pat, Is_LFS_Rule);
                  if Is_LFS_Rule then
                     Vec.Append
                       (Pattern_Entry'
                          (Pattern => Pat,
                           Source  => To_Unbounded_String (Source)));
                  end if;
               end;
               Start := Stop + 1;
            end;
         end loop;
      end;
   end Collect_Patterns_From;

   function Root_Attributes_Path
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return Join (Version.Repository.Root_Path (Repo), ".gitattributes");
   end Root_Attributes_Path;

   function Tracked_Patterns
     (Repo : Version.Repository.Repository_Handle) return Pattern_Array
   is
      Vec : Pattern_Vectors.Vector;
   begin
      Collect_Patterns_From (Root_Attributes_Path (Repo), ".gitattributes", Vec);
      Collect_Patterns_From
        (Join (Join (Version.Repository.Common_Git_Dir (Repo), "info"),
               "attributes"),
         ".git/info/attributes", Vec);
      return R : Pattern_Array (1 .. Natural (Vec.Length)) do
         for I in R'Range loop
            R (I) := Vec (I);
         end loop;
      end return;
   end Tracked_Patterns;

   function Track_Pattern
     (Repo : Version.Repository.Repository_Handle; Pattern : String)
      return Boolean
   is
      use Ada.Strings.Unbounded;
      Attr     : constant String := Root_Attributes_Path (Repo);
      Existing : constant Pattern_Array := Tracked_Patterns (Repo);
   begin
      for E of Existing loop
         if To_String (E.Pattern) = Pattern then
            return False;
         end if;
      end loop;
      declare
         Old : constant String :=
           (if Ada.Directories.Exists (Attr)
            then Version.Files.Read_Binary_File (Attr) else "");
         Base : constant String :=
           (if Old'Length = 0 or else Old (Old'Last) = Character'Val (10)
            then Old else Old & Character'Val (10));
      begin
         Version.Files.Write_Binary_File_Atomic
           (Attr,
            Base & Pattern & " filter=lfs diff=lfs merge=lfs -text"
            & Character'Val (10));
      end;
      return True;
   end Track_Pattern;

   function Untrack_Pattern
     (Repo : Version.Repository.Repository_Handle; Pattern : String)
      return Boolean
   is
      use Ada.Strings.Unbounded;
      Attr    : constant String := Root_Attributes_Path (Repo);
      Removed : Boolean := False;
   begin
      if not Ada.Directories.Exists (Attr) then
         return False;
      end if;
      declare
         Text   : constant String := Version.Files.Read_Binary_File (Attr);
         Result : Unbounded_String;
         Start  : Natural := Text'First;
      begin
         while Start <= Text'Last loop
            declare
               Stop   : Natural := Start;
               Has_LF : Boolean;
            begin
               while Stop <= Text'Last
                 and then Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;
               Has_LF := Stop <= Text'Last;
               declare
                  Line        : constant String :=
                    Chomp_CR (Text (Start .. Stop - 1));
                  Pat         : Unbounded_String;
                  Is_LFS_Rule : Boolean;
               begin
                  Split_Attr_Line (Line, Pat, Is_LFS_Rule);
                  if Is_LFS_Rule and then To_String (Pat) = Pattern then
                     Removed := True;    --  drop this line
                  else
                     Append
                       (Result,
                        Text (Start .. (if Has_LF then Stop else Stop - 1)));
                  end if;
               end;
               Start := Stop + 1;
            end;
         end loop;
         if Removed then
            Version.Files.Write_Binary_File_Atomic (Attr, To_String (Result));
         end if;
      end;
      return Removed;
   end Untrack_Pattern;

   package LFS_Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => LFS_Entry);

   --  Append (Path, Blob_Id) as an LFS entry when the blob is an LFS pointer.
   --  Reads are bounded to LFS-tracked paths so large ordinary blobs are never
   --  loaded just to be rejected.
   procedure Add_LFS_Entry
     (Repo    : Version.Repository.Repository_Handle;
      Path    : String;
      Blob_Id : String;
      Vec     : in out LFS_Entry_Vectors.Vector)
   is
      use Ada.Strings.Unbounded;
   begin
      if not Is_Tracked (Repo, Path) then
         return;
      end if;
      declare
         Blob : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object
             (Repo, Version.Objects.To_Object_Id (Blob_Id));
         Info : constant Pointer_Info :=
           Parse_Pointer (Version.Objects.Content (Blob));
      begin
         if Info.Is_Pointer then
            Vec.Append
              (LFS_Entry'
                 (Path   => To_Unbounded_String (Path),
                  Oid    => Info.Oid,
                  Size   => Info.Size,
                  Cached => Object_Cached (Repo, To_String (Info.Oid))));
         end if;
      end;
   exception
      when others =>
         null;    --  unreadable/missing blob: skip
   end Add_LFS_Entry;

   function To_Entry_Array (Vec : LFS_Entry_Vectors.Vector) return LFS_Entry_Array
   is
   begin
      return R : LFS_Entry_Array (1 .. Natural (Vec.Length)) do
         for I in R'Range loop
            R (I) := Vec (I);
         end loop;
      end return;
   end To_Entry_Array;

   function LFS_Entries_In_Index
     (Repo : Version.Repository.Repository_Handle) return LFS_Entry_Array
   is
      use Ada.Strings.Unbounded;
      Idx : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Vec : LFS_Entry_Vectors.Vector;
   begin
      for E of Idx loop
         Add_LFS_Entry
           (Repo, To_String (E.Path), Version.Objects.To_String (E.Id), Vec);
      end loop;
      return To_Entry_Array (Vec);
   end LFS_Entries_In_Index;

   function LFS_Entries_In_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return LFS_Entry_Array
   is
      use Ada.Strings.Unbounded;
      use type Version.Objects.Tree_Entry_Kind;
      Tree_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.Commit_Tree_Id
          (Version.Objects.Read_Object (Repo, Commit_Id));
      Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo, Tree_Id);
      Vec : LFS_Entry_Vectors.Vector;
   begin
      for E of Entries loop
         if E.Kind = Version.Objects.Tree_Blob then
            Add_LFS_Entry
              (Repo, To_String (E.Path), Version.Objects.To_String (E.Id), Vec);
         end if;
      end loop;
      return To_Entry_Array (Vec);
   end LFS_Entries_In_Commit;

   --------------------------------------------------------------------------
   --  Maintenance and history rewriting (git-lfs fetch --all / prune / migrate)
   --------------------------------------------------------------------------

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   package String_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type        => String,
      Hash                => Ada.Strings.Hash,
      Equivalent_Elements => "=");

   package String_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   function Store_Object
     (Repo : Version.Repository.Repository_Handle; Content : String)
      return String
   is
      Oid : constant String := Version.Hash.Sha256_Hex (Content);
   begin
      Version.Files.Write_Binary_File_Atomic
        (LFS_Object_Path (Repo, Oid), Content);
      return Oid;
   end Store_Object;

   function Cached_Object_Content
     (Repo : Version.Repository.Repository_Handle; Oid : String)
      return String is
   begin
      return Version.Files.Read_Binary_File (LFS_Object_Path (Repo, Oid));
   end Cached_Object_Content;

   --  Peel a ref target through annotated tags to the underlying commit id.
   function Peel_To_Commit
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Current : Version.Objects.Hex_Object_Id := Id;
   begin
      loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Current);
         begin
            exit when Version.Objects.Kind (Obj) /= Version.Objects.Tag_Object;
            Current := Version.Objects.Tag_Target_Id (Obj);
         end;
      end loop;
      return Current;
   end Peel_To_Commit;

   --  Commit ids at the tip of every branch and tag.
   function All_Ref_Tips
     (Repo : Version.Repository.Repository_Handle) return String_Vectors.Vector
   is
      use Ada.Strings.Unbounded;
      Tips : String_Vectors.Vector;

      procedure Add (Ref_Name : String) is
      begin
         Tips.Append
           (Version.Objects.To_String
              (Peel_To_Commit
                 (Repo, Version.Refs.Resolve_Ref (Repo, Ref_Name))));
      exception
         when others => null;   --  unresolvable / non-commit ref: skip
      end Add;
   begin
      for B of Version.Refs.List_Branches (Repo) loop
         Add ("refs/heads/" & To_String (B));
      end loop;
      for Tg of Version.Tags.List_Tags loop
         Add ("refs/tags/" & To_String (Tg));
      end loop;
      return Tips;
   end All_Ref_Tips;

   function LFS_Entries_All_Refs
     (Repo : Version.Repository.Repository_Handle) return LFS_Entry_Array
   is
      use Ada.Strings.Unbounded;
      Vec  : LFS_Entry_Vectors.Vector;
      Seen : String_Sets.Set;
   begin
      for Tip of All_Ref_Tips (Repo) loop
         begin
            for E of LFS_Entries_In_Commit
                       (Repo, Version.Objects.To_Object_Id (Tip))
            loop
               if not Seen.Contains (To_String (E.Oid)) then
                  Seen.Insert (To_String (E.Oid));
                  Vec.Append (E);
               end if;
            end loop;
         exception
            when others => null;
         end;
      end loop;
      return To_Entry_Array (Vec);
   end LFS_Entries_All_Refs;

   --  Collect the full filesystem paths of every regular file under Dir.
   procedure Collect_Files
     (Dir : String; Into : in out String_Vectors.Vector)
   is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Dir) then
         return;
      end if;
      Ada.Directories.Start_Search
        (Search, Dir, "",
         [Ada.Directories.Ordinary_File => True,
          Ada.Directories.Directory     => True,
          others                        => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               case Ada.Directories.Kind (Item) is
                  when Ada.Directories.Directory =>
                     Collect_Files (Ada.Directories.Full_Name (Item), Into);
                  when Ada.Directories.Ordinary_File =>
                     Into.Append (Ada.Directories.Full_Name (Item));
                  when others =>
                     null;
               end case;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Collect_Files;

   procedure Prune
     (Repo          : Version.Repository.Repository_Handle;
      Dry_Run       : Boolean;
      Total_Objects : out Natural;
      Retained      : out Natural)
   is
      use Ada.Strings.Unbounded;
      Keep  : String_Sets.Set;
      Base  : constant String :=
        Join (Join (Version.Repository.Common_Git_Dir (Repo), "lfs"), "objects");
      Files : String_Vectors.Vector;
   begin
      Total_Objects := 0;
      Retained := 0;
      for E of LFS_Entries_All_Refs (Repo) loop
         Keep.Include (To_String (E.Oid));
      end loop;
      for E of LFS_Entries_In_Index (Repo) loop
         Keep.Include (To_String (E.Oid));
      end loop;

      Collect_Files (Base, Files);
      for F of Files loop
         Total_Objects := Total_Objects + 1;
         if Keep.Contains (Ada.Directories.Simple_Name (F)) then
            Retained := Retained + 1;
         elsif not Dry_Run then
            begin
               Ada.Directories.Delete_File (F);
            exception
               when others => null;
            end;
         end if;
      end loop;
   end Prune;

   --  basename / exact / "*.ext" match (the common .gitattributes forms git
   --  uses for LFS include patterns).
   function Glob_Matches (Pattern, Path : String) return Boolean is
      function Basename (P : String) return String is
      begin
         for I in reverse P'Range loop
            if P (I) = '/' then
               return P (I + 1 .. P'Last);
            end if;
         end loop;
         return P;
      end Basename;
      Name : constant String := Basename (Path);
   begin
      if Pattern'Length = 0 then
         return False;
      elsif Pattern = Path or else Pattern = Name then
         return True;
      elsif Pattern'Length > 2
        and then Pattern (Pattern'First) = '*'
        and then Pattern (Pattern'First + 1) = '.'
      then
         return Ends_With (Name, Pattern (Pattern'First + 1 .. Pattern'Last));
      else
         return False;
      end if;
   end Glob_Matches;

   function Split_Patterns (Include : String) return String_Vectors.Vector is
      V     : String_Vectors.Vector;
      Start : Natural := Include'First;
   begin
      for I in Include'Range loop
         if Include (I) = ',' then
            if I > Start then
               V.Append (Include (Start .. I - 1));
            end if;
            Start := I + 1;
         end if;
      end loop;
      if Include'Length > 0 and then Include'Last >= Start then
         V.Append (Include (Start .. Include'Last));
      end if;
      return V;
   end Split_Patterns;

   function Matches_Include
     (Patterns : String_Vectors.Vector; Path : String) return Boolean is
   begin
      for P of Patterns loop
         if Glob_Matches (P, Path) then
            return True;
         end if;
      end loop;
      return False;
   end Matches_Include;

   --  Exact string membership (used to drop a .gitattributes rule whose
   --  pattern is one of the exported include patterns).
   function Matches_Include_Exact
     (Patterns : String_Vectors.Vector; Value : String) return Boolean is
   begin
      for P of Patterns loop
         if P = Value then
            return True;
         end if;
      end loop;
      return False;
   end Matches_Include_Exact;

   function Extension_Of (Path : String) return String is
      function Basename (P : String) return String is
      begin
         for I in reverse P'Range loop
            if P (I) = '/' then
               return P (I + 1 .. P'Last);
            end if;
         end loop;
         return P;
      end Basename;
      Name : constant String := Basename (Path);
      Dot  : Natural := 0;
   begin
      for I in reverse Name'Range loop
         if Name (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;
      return (if Dot = 0 then "(no extension)" else "*" & Name (Dot .. Name'Last));
   end Extension_Of;

   --  Does Attr_Text already declare a filter=lfs rule for Pattern?
   function Has_LFS_Rule (Attr_Text, Pattern : String) return Boolean is
      use Ada.Strings.Unbounded;
      Start : Natural := Attr_Text'First;
   begin
      while Start <= Attr_Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Attr_Text'Last
              and then Attr_Text (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;
            declare
               Line        : constant String :=
                 Chomp_CR (Attr_Text (Start .. Stop - 1));
               Pat         : Unbounded_String;
               Is_LFS_Rule : Boolean;
            begin
               Split_Attr_Line (Line, Pat, Is_LFS_Rule);
               if Is_LFS_Rule and then To_String (Pat) = Pattern then
                  return True;
               end if;
            end;
            Start := Stop + 1;
         end;
      end loop;
      return False;
   end Has_LFS_Rule;

   --  Rebuild .gitattributes for a migrated commit: import appends any missing
   --  filter=lfs rule for the patterns; export drops the patterns' rules.
   function Adjust_Attributes
     (Old       : String;
      Patterns  : String_Vectors.Vector;
      Direction : Migrate_Direction) return String
   is
      use Ada.Strings.Unbounded;
      LF     : constant Character := Character'Val (10);
      Result : Unbounded_String;
   begin
      if Direction = Migrate_Import then
         Result := To_Unbounded_String (Old);
         if Length (Result) > 0
           and then Element (Result, Length (Result)) /= LF
         then
            Append (Result, LF);
         end if;
         for P of Patterns loop
            if not Has_LFS_Rule (Old, P) then
               Append
                 (Result, P & " filter=lfs diff=lfs merge=lfs -text" & LF);
            end if;
         end loop;
         return To_String (Result);
      else
         --  export: keep every line whose pattern is not an exported rule.
         declare
            Start : Natural := Old'First;
         begin
            while Start <= Old'Last loop
               declare
                  Stop   : Natural := Start;
                  Has_LF : Boolean;
               begin
                  while Stop <= Old'Last and then Old (Stop) /= LF loop
                     Stop := Stop + 1;
                  end loop;
                  Has_LF := Stop <= Old'Last;
                  declare
                     Line        : constant String :=
                       Chomp_CR (Old (Start .. Stop - 1));
                     Pat         : Unbounded_String;
                     Is_LFS_Rule : Boolean;
                  begin
                     Split_Attr_Line (Line, Pat, Is_LFS_Rule);
                     if Is_LFS_Rule
                       and then Matches_Include_Exact (Patterns, To_String (Pat))
                     then
                        null;    --  drop this exported rule
                     else
                        Append
                          (Result,
                           Old (Start .. (if Has_LF then Stop else Stop - 1)));
                     end if;
                  end;
                  Start := Stop + 1;
               end;
            end loop;
         end;
         return To_String (Result);
      end if;
   end Adjust_Attributes;

   --  Extract the verbatim author line, committer line and message body from a
   --  raw commit object (a single trailing LF is stripped so re-assembly is
   --  byte-faithful). Extra headers (gpgsig, encoding) are intentionally
   --  dropped, as history rewriting invalidates signatures.
   procedure Parse_Commit
     (Content : String;
      Author, Committer, Message : out Ada.Strings.Unbounded.Unbounded_String)
   is
      use Ada.Strings.Unbounded;
      LF       : constant Character := Character'Val (10);
      I        : Natural := Content'First;
      Body_At  : Natural := 0;
   begin
      Author := Null_Unbounded_String;
      Committer := Null_Unbounded_String;
      Message := Null_Unbounded_String;
      while I <= Content'Last loop
         declare
            J : Natural := I;
         begin
            while J <= Content'Last and then Content (J) /= LF loop
               J := J + 1;
            end loop;
            declare
               Line : constant String := Content (I .. J - 1);
            begin
               if Line'Length = 0 then
                  Body_At := J;    --  the LF ending the blank separator line
                  exit;
               elsif Starts_With (Line, "author ") then
                  Author :=
                    To_Unbounded_String (Line (Line'First + 7 .. Line'Last));
               elsif Starts_With (Line, "committer ") then
                  Committer :=
                    To_Unbounded_String (Line (Line'First + 10 .. Line'Last));
               end if;
            end;
            I := J + 1;
         end;
      end loop;
      if Body_At > 0 and then Body_At < Content'Last then
         declare
            Msg : constant String := Content (Body_At + 1 .. Content'Last);
         begin
            if Msg'Length > 0 and then Msg (Msg'Last) = LF then
               Message := To_Unbounded_String (Msg (Msg'First .. Msg'Last - 1));
            else
               Message := To_Unbounded_String (Msg);
            end if;
         end;
      end if;
   end Parse_Commit;

   procedure Collect_Rewrite_Order
     (Repo       : Version.Repository.Repository_Handle;
      Everything : Boolean;
      Order      : out String_Vectors.Vector;
      Roots      : out String_Vectors.Vector;
      Root_Refs  : out String_Vectors.Vector)
   is
      use Ada.Strings.Unbounded;
      Visited : String_Sets.Set;
      L_Order : String_Vectors.Vector;
      L_Roots : String_Vectors.Vector;
      L_Refs  : String_Vectors.Vector;

      procedure Emit (C : String) is
      begin
         if Visited.Contains (C) then
            return;
         end if;
         Visited.Insert (C);
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Version.Objects.To_Object_Id (C));
            Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Objects.Commit_Parent_Ids (Obj);
         begin
            for I in Parents.First_Index .. Parents.Last_Index loop
               Emit (Version.Objects.To_String (Parents.Element (I)));
            end loop;
            L_Order.Append (C);
         end;
      exception
         when others => null;   --  non-commit / unreadable: skip
      end Emit;

      procedure Add_Root (Ref_Name : String) is
         Tip : constant Version.Objects.Hex_Object_Id :=
           Peel_To_Commit (Repo, Version.Refs.Resolve_Ref (Repo, Ref_Name));
      begin
         L_Roots.Append (Version.Objects.To_String (Tip));
         L_Refs.Append (Ref_Name);
      exception
         when others => null;
      end Add_Root;
   begin
      if Everything then
         for B of Version.Refs.List_Branches (Repo) loop
            Add_Root ("refs/heads/" & To_String (B));
         end loop;
      else
         declare
            Branch : constant String := Version.Refs.Current_Branch_Name (Repo);
         begin
            if Branch'Length = 0 then
               raise Ada.IO_Exceptions.Use_Error
                 with "lfs migrate requires a branch (HEAD is detached)";
            end if;
            Add_Root ("refs/heads/" & Branch);
         end;
      end if;
      for R of L_Roots loop
         Emit (R);
      end loop;
      Order := L_Order;
      Roots := L_Roots;
      Root_Refs := L_Refs;
   end Collect_Rewrite_Order;

   procedure Migrate
     (Repo       : Version.Repository.Repository_Handle;
      Direction  : Migrate_Direction;
      Include    : String;
      Everything : Boolean := False)
   is
      use Ada.Strings.Unbounded;
      use type Version.Objects.Tree_Entry_Kind;
      Patterns : constant String_Vectors.Vector := Split_Patterns (Include);
      Order, Roots, Root_Refs : String_Vectors.Vector;
      Map : String_Maps.Map;
   begin
      Collect_Rewrite_Order (Repo, Everything, Order, Roots, Root_Refs);

      for C of Order loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Version.Objects.To_Object_Id (C));
            Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Flatten_Tree
                (Repo, Version.Objects.Commit_Tree_Id (Obj));
            New_Index : Version.Staging.Index_Entry_Vectors.Vector;
            Attr_Mode : Unbounded_String := To_Unbounded_String ("100644");
            Old_Attr  : Unbounded_String;
            Have_Attr : Boolean := False;
         begin
            for E of Entries loop
               if E.Kind = Version.Objects.Tree_Blob then
                  declare
                     Path : constant String := To_String (E.Path);
                  begin
                     if Path = ".gitattributes" then
                        Have_Attr := True;
                        Attr_Mode := E.Mode;
                        Old_Attr := To_Unbounded_String
                          (Version.Objects.Content
                             (Version.Objects.Read_Object (Repo, E.Id)));
                     else
                        declare
                           New_Id : Version.Objects.Object_Id_Storage := E.Id;
                        begin
                           if Matches_Include (Patterns, Path) then
                              declare
                                 Blob : constant String :=
                                   Version.Objects.Content
                                     (Version.Objects.Read_Object (Repo, E.Id));
                              begin
                                 if Direction = Migrate_Import then
                                    if not Is_LFS_Pointer (Blob) then
                                       declare
                                          Ignored : constant String :=
                                            Store_Object (Repo, Blob);
                                          pragma Unreferenced (Ignored);
                                       begin
                                          New_Id :=
                                            Version.Write.Write_Blob
                                              (Repo, Build_Pointer (Blob));
                                       end;
                                    end if;
                                 else
                                    declare
                                       Info : constant Pointer_Info :=
                                         Parse_Pointer (Blob);
                                    begin
                                       if Info.Is_Pointer then
                                          New_Id :=
                                            Version.Write.Write_Blob
                                              (Repo,
                                               Cached_Object_Content
                                                 (Repo, To_String (Info.Oid)));
                                       end if;
                                    end;
                                 end if;
                              end;
                           end if;
                           New_Index.Append
                             (Version.Staging.Index_Entry'
                                (Path  => E.Path,
                                 Id    => New_Id,
                                 Mode  => E.Mode,
                                 Stage => 0, Skip_Worktree => False));
                        end;
                     end if;
                  end;
               end if;
            end loop;

            declare
               New_Attr : constant String :=
                 Adjust_Attributes
                   ((if Have_Attr then To_String (Old_Attr) else ""),
                    Patterns, Direction);
            begin
               if New_Attr'Length > 0 then
                  New_Index.Append
                    (Version.Staging.Index_Entry'
                       (Path  => To_Unbounded_String (".gitattributes"),
                        Id    => Version.Write.Write_Blob (Repo, New_Attr),
                        Mode  => Attr_Mode,
                        Stage => 0, Skip_Worktree => False));
               end if;
            end;

            declare
               New_Tree : constant Version.Objects.Hex_Object_Id :=
                 Version.Write.Write_Tree_From_Index (Repo, New_Index);
               Old_Parents :
                 constant Version.Objects.Object_Id_Vectors.Vector :=
                   Version.Objects.Commit_Parent_Ids (Obj);
               New_Parents : Version.Objects.Object_Id_Vectors.Vector;
               Author, Committer, Message : Unbounded_String;
            begin
               for I in Old_Parents.First_Index .. Old_Parents.Last_Index loop
                  declare
                     P : constant String :=
                       Version.Objects.To_String (Old_Parents.Element (I));
                  begin
                     New_Parents.Append
                       (Version.Objects.To_Object_Id
                          (if Map.Contains (P) then Map.Element (P) else P));
                  end;
               end loop;
               Parse_Commit
                 (Version.Objects.Content (Obj), Author, Committer, Message);
               Map.Insert
                 (C,
                  Version.Objects.To_String
                    (Version.Write.Write_Commit_Raw
                       (Repo, New_Tree, New_Parents,
                        To_String (Author), To_String (Committer),
                        To_String (Message))));
            end;
         end;
      end loop;

      for I in Roots.First_Index .. Roots.Last_Index loop
         if Map.Contains (Roots.Element (I)) then
            Version.Refs.Atomic_Write_Ref
              (Path      =>
                 Join (Version.Repository.Common_Git_Dir (Repo),
                       Root_Refs.Element (I)),
               Object_Id =>
                 Version.Objects.To_Object_Id (Map.Element (Roots.Element (I))));
         end if;
      end loop;

      declare
         Branch    : constant String :=
           Version.Refs.Current_Branch_Name (Repo);
         Attr_Path : constant String :=
           Join (Version.Repository.Root_Path (Repo), ".gitattributes");
      begin
         if Branch'Length > 0 then
            declare
               Head_Tree : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.Commit_Tree_Id
                   (Version.Objects.Read_Object
                      (Repo,
                       Version.Refs.Resolve_Ref (Repo, "refs/heads/" & Branch)));
               Found : Boolean := False;
            begin
               --  Reset the index to the rewritten HEAD.
               Version.Staging.Write_From_Tree (Repo, Head_Tree);
               --  Sync the working-tree .gitattributes with the rewritten HEAD
               --  so later LFS commands recognize the tracked files (the media
               --  files themselves are already correct in the working tree).
               for E of Version.Objects.Flatten_Tree (Repo, Head_Tree) loop
                  if E.Kind = Version.Objects.Tree_Blob
                    and then Ada.Strings.Unbounded.To_String (E.Path)
                               = ".gitattributes"
                  then
                     Version.Files.Write_Binary_File_Atomic
                       (Attr_Path,
                        Version.Objects.Content
                          (Version.Objects.Read_Object (Repo, E.Id)));
                     Found := True;
                     exit;
                  end if;
               end loop;
               if not Found and then Ada.Directories.Exists (Attr_Path) then
                  Ada.Directories.Delete_File (Attr_Path);
               end if;
            end;
         end if;
      exception
         when others => null;
      end;
   end Migrate;

   package Info_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Migrate_Info_Entry);

   function Migrate_Info
     (Repo : Version.Repository.Repository_Handle; Everything : Boolean := False)
      return Migrate_Info_Array
   is
      use Ada.Strings.Unbounded;
      use type Version.Objects.Tree_Entry_Kind;
      Order, Roots, Root_Refs : String_Vectors.Vector;
      Seen : String_Sets.Set;
      Acc  : Info_Vectors.Vector;

      procedure Bump (Ext : String; Size : Natural) is
         Found : Boolean := False;
      begin
         for E of Acc loop
            if To_String (E.Name) = Ext then
               E.Count := E.Count + 1;
               E.Bytes := E.Bytes + Long_Long_Integer (Size);
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            Acc.Append
              (Migrate_Info_Entry'
                 (Name  => To_Unbounded_String (Ext),
                  Count => 1,
                  Bytes => Long_Long_Integer (Size)));
         end if;
      end Bump;
   begin
      Collect_Rewrite_Order (Repo, Everything, Order, Roots, Root_Refs);
      for C of Order loop
         begin
            for E of Version.Objects.Flatten_Tree
                       (Repo,
                        Version.Objects.Commit_Tree_Id
                          (Version.Objects.Read_Object
                             (Repo, Version.Objects.To_Object_Id (C))))
            loop
               if E.Kind = Version.Objects.Tree_Blob then
                  declare
                     Oid : constant String := Version.Objects.To_String (E.Id);
                  begin
                     if not Seen.Contains (Oid) then
                        Seen.Insert (Oid);
                        Bump
                          (Extension_Of (To_String (E.Path)),
                           Version.Objects.Content
                             (Version.Objects.Read_Object (Repo, E.Id))'Length);
                     end if;
                  end;
               end if;
            end loop;
         exception
            when others => null;
         end;
      end loop;

      --  Sort by descending byte size (simple insertion sort; few extensions).
      for I in Acc.First_Index + 1 .. Acc.Last_Index loop
         declare
            Key : constant Migrate_Info_Entry := Acc.Element (I);
            J   : Integer := I - 1;
         begin
            while J >= Acc.First_Index
              and then Acc.Element (J).Bytes < Key.Bytes
            loop
               Acc.Replace_Element (J + 1, Acc.Element (J));
               J := J - 1;
            end loop;
            Acc.Replace_Element (J + 1, Key);
         end;
      end loop;

      return R : Migrate_Info_Array (1 .. Natural (Acc.Length)) do
         for I in R'Range loop
            R (I) := Acc.Element (I);
         end loop;
      end return;
   end Migrate_Info;

end Version.LFS;
