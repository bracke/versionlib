with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.SHA256;

with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.HTTP2;
with Http_Client.Requests;
with Http_Client.Response_Streams;
with Http_Client.Types;
with Http_Client.URI;

with Version.Config;
with Version.Files;
with Version.Transport;
with Version.Transport.Local;
with Version.Transport.Ssh;

package body Version.LFS is

   use type Http_Client.Errors.Result_Status;
   use type Version.Transport.Transport_Kind;

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

   function LFS_Batch_Url (Url : String; Is_LFS_Url : Boolean) return String is
      Clean : constant String := Strip_Trailing_Slashes (Url);
   begin
      if Clean'Length = 0 then
         return "";
      elsif Ends_With (Clean, "/objects/batch") then
         return Clean;
      elsif Is_LFS_Url or else Ends_With (Clean, "/info/lfs") then
         return Clean & "/objects/batch";
      else
         return Clean & "/info/lfs/objects/batch";
      end if;
   end LFS_Batch_Url;

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
      Options.TLS.HTTP2.Enable_Public_Streaming := True;
      Options.TLS.HTTP2.Enable_Upload_Streaming := True;
      Options.Enable_Decompression := False;
      Options.Max_Body_Size := Max_Body;
      return Options;
   end LFS_HTTP_Options;

   function Read_HTTP_Body
     (Url          : String;
      Method       : Http_Client.Types.Method_Name;
      Headers      : Http_Client.Headers.Header_List;
      Payload      : String;
      Max_Body     : Natural;
      Context      : String) return String
   is
      use Ada.Strings.Unbounded;
      use Ada.Streams;

      URI     : Http_Client.URI.URI_Reference;
      Request : Http_Client.Requests.Request;
      Stream  : Http_Client.Response_Streams.Streaming_Response;
      Options : constant Http_Client.Response_Streams.Streaming_Options :=
        LFS_HTTP_Options (Max_Body);
      Buffer  : Stream_Element_Array (1 .. 16 * 1024);
      Last    : Stream_Element_Offset;
      Status  : Http_Client.Errors.Result_Status;
      Result_Body : Unbounded_String;
      Opened  : Boolean := False;
   begin
      if Http_Client.URI.Parse (Url, URI) /= Http_Client.Errors.Ok then
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

      Status := Http_Client.Response_Streams.Open (Request, Stream, Options);
      if Status /= Http_Client.Errors.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
      end if;

      Opened := True;

      if Http_Client.Response_Streams.Status_Code (Stream) < 200
        or else Http_Client.Response_Streams.Status_Code (Stream) > 299
      then
         raise Ada.IO_Exceptions.Data_Error with
           Context & ": HTTP" & Integer'Image
             (Http_Client.Response_Streams.Status_Code (Stream));
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
      if Status /= Http_Client.Errors.Ok then
         raise Ada.IO_Exceptions.Data_Error with
           Context & ": " & Http_Client.Errors.Result_Status'Image (Status);
      end if;

      return To_String (Result_Body);

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
                (Url      => Href,
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
              and then Fetch_From_SSH_LFS
                (Repo          => Repo,
                 Url           => LFS_Url,
                 Oid           => Oid,
                 Expected_Size => Expected_Size)
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
              and then Fetch_From_SSH_LFS
                (Repo          => Repo,
                 Url           => Origin,
                 Oid           => Oid,
                 Expected_Size => Expected_Size)
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
         Oid : constant String := GNAT.SHA256.Digest (Content);
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

end Version.LFS;
