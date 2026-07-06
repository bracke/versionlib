with Ada.Directories;
with Ada.Exceptions;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;

with Interfaces; use Interfaces;

with GNAT.OS_Lib;
with GNAT.Sockets;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Compression;
with Version.Fetch.Internal;
with Version.Git_Fixtures;
with Version.Hash;
with Version.Init;
with Version.Objects; use Version.Objects;
with Version.Pkt_Line;
with Version.Ref_Transaction;
with Version.Platform;
with Version.Remotes;
with Version.Repository;
with Version.Refs;
with Version.Test_Support;
with Version.Write;
with Version.Tags;

package body Version.Fetch.Tests is

   use type Version.Platform.Platform_Kind;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

   Fetch_Fixture_Main_Id : constant String :=
     "1111111111111111111111111111111111111111";

   function Loose_Object_Path
     (Git_Dir : String;
      Id      : Version.Objects.Hex_Object_Id) return String
   is
      Text : constant String := To_String (Id);
   begin
      return
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"),
              Text (Text'First .. Text'First + 1)),
           Text (Text'First + 2 .. Text'Last));
   end Loose_Object_Path;

   function To_Stream (Text : String) return Ada.Streams.Stream_Element_Array
   is
      Result :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      J      : Ada.Streams.Stream_Element_Offset := Result'First;
   begin
      for I in Text'Range loop
         Result (J) := Ada.Streams.Stream_Element (Character'Pos (Text (I)));
         J := J + 1;
      end loop;

      return Result;
   end To_Stream;

   function Concat
     (A : Ada.Streams.Stream_Element_Array;
      B : Ada.Streams.Stream_Element_Array)
      return Ada.Streams.Stream_Element_Array
   is
      Result :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (A'Length + B'Length));
      Pos    : Ada.Streams.Stream_Element_Offset := Result'First;
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

   function Discovery_Stream_With_Capabilities
     (Capabilities : String) return Ada.Streams.Stream_Element_Array
   is
      Service : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-upload-pack" & LF));
      Flush_1 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
      Head    : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (Fetch_Fixture_Main_Id & " HEAD" & NUL & Capabilities & LF));
      Main    : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (Fetch_Fixture_Main_Id & " refs/heads/main" & LF));
      Flush_2 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
   begin
      return
        Concat
          (Concat (Concat (Concat (Service, Flush_1), Head), Main), Flush_2);
   end Discovery_Stream_With_Capabilities;

   function Discovery_Stream return Ada.Streams.Stream_Element_Array is
   begin
      return
        Discovery_Stream_With_Capabilities
          ("multi_ack side-band-64k ofs-delta symref=HEAD:refs/heads/main");
   end Discovery_Stream;

   function Shallow_Discovery_Stream return Ada.Streams.Stream_Element_Array is
   begin
      return
        Discovery_Stream_With_Capabilities
          ("multi_ack side-band-64k ofs-delta shallow symref=HEAD:refs/heads/main");
   end Shallow_Discovery_Stream;

   function Tag_Discovery_Stream return Ada.Streams.Stream_Element_Array is
      Service : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-upload-pack" & LF));
      Flush_1 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
      Head    : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (Fetch_Fixture_Main_Id & " HEAD" & NUL
              & "multi_ack side-band-64k ofs-delta include-tag "
              & "symref=HEAD:refs/heads/main" & LF));
      Main    : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (Fetch_Fixture_Main_Id & " refs/heads/main" & LF));
      New_Tag : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             ("2222222222222222222222222222222222222222"
              & " refs/tags/new-lightweight" & LF));
      Existing_Tag : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             ("3333333333333333333333333333333333333333"
              & " refs/tags/existing-annotated" & LF));
      Peeled_Tag : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (Fetch_Fixture_Main_Id
              & " refs/tags/existing-annotated^{}" & LF));
      Flush_2 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
   begin
      return
        Concat
          (Concat
             (Concat
                (Concat
                   (Concat
                      (Concat
                         (Concat (Service, Flush_1),
                          Head),
                       Main),
                    New_Tag),
                 Existing_Tag),
              Peeled_Tag),
           Flush_2);
   end Tag_Discovery_Stream;

   function Malformed_Pkt_Line_Response return Ada.Streams.Stream_Element_Array
   is
   begin
      return To_Stream ("zzzz");
   end Malformed_Pkt_Line_Response;

   function Truncated_Pack_Response return Ada.Streams.Stream_Element_Array is
      Payload : constant Ada.Streams.Stream_Element_Array :=
        [1 => 1,
         2 => Ada.Streams.Stream_Element (Character'Pos ('P')),
         3 => Ada.Streams.Stream_Element (Character'Pos ('A')),
         4 => Ada.Streams.Stream_Element (Character'Pos ('C')),
         5 => Ada.Streams.Stream_Element (Character'Pos ('K'))];
   begin
      return Version.Pkt_Line.Encode_Data (Payload);
   end Truncated_Pack_Response;

   function Sideband_Response
     (Channel : Ada.Streams.Stream_Element; Text : String)
      return Ada.Streams.Stream_Element_Array
   is
      Text_Bytes : constant Ada.Streams.Stream_Element_Array :=
        To_Stream (Text);
      Payload    :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Text_Bytes'Length + 1));
      Pos        : Ada.Streams.Stream_Element_Offset := Payload'First;
   begin
      Payload (Pos) := Channel;
      Pos := Pos + 1;

      for I in Text_Bytes'Range loop
         Payload (Pos) := Text_Bytes (I);
         Pos := Pos + 1;
      end loop;

      return Version.Pkt_Line.Encode_Data (Payload);
   end Sideband_Response;

   function Upload_Pack_Fatal_Response return Ada.Streams.Stream_Element_Array
   is
   begin
      return Sideband_Response (3, "remote failure" & LF);
   end Upload_Pack_Fatal_Response;

   function Unknown_Sideband_Response return Ada.Streams.Stream_Element_Array
   is
   begin
      return Sideband_Response (9, "unexpected channel" & LF);
   end Unknown_Sideband_Response;

   function Empty_Pack_Response return Ada.Streams.Stream_Element_Array is
   begin
      return
        Concat
          (Version.Pkt_Line.Encode_Data (To_Stream ("NAK" & LF)),
           Version.Pkt_Line.Encode_Flush);
   end Empty_Pack_Response;

   function U32_BE (Value : Interfaces.Unsigned_32) return String is
   begin
      return
        Character'Val (Natural (Interfaces.Shift_Right (Value, 24) and 16#FF#))
        & Character'Val
            (Natural (Interfaces.Shift_Right (Value, 16) and 16#FF#))
        & Character'Val
            (Natural (Interfaces.Shift_Right (Value, 8) and 16#FF#))
        & Character'Val (Natural (Value and 16#FF#));
   end U32_BE;

   function Pack_File
     (Object_Count   : Interfaces.Unsigned_32;
      Payload        : String;
      Valid_Checksum : Boolean := True) return String
   is
      Prefix : constant String :=
        "PACK"
        & U32_BE (Interfaces.Unsigned_32'(2))
        & U32_BE (Object_Count)
        & Payload;
      Sum    : constant String :=
        (if Valid_Checksum
         then Version.Hash.Sha1_Raw (Prefix)
         else String'(1 .. 20 => Character'Val (0)));
   begin
      return Prefix & Sum;
   end Pack_File;

   function Blob_Entry (Content : String) return String is
   begin
      if Content'Length > 15 then
         raise Ada.IO_Exceptions.Data_Error with "test blob entry too large";
      end if;

      return
        Character'Val (16#30# + Content'Length)
        & Version.Compression.Deflate_Zlib (Content);
   end Blob_Entry;

   function Ref_Delta_Entry_With_Missing_Base return String is
      Delta_Data : constant String := Character'Val (0) & Character'Val (0);
      Header     : constant String := "" &
        Character'Val (16#70# + Delta_Data'Length);
   begin
      return
        Header
        & String'(1 .. 20 => Character'Val (0))
        & Version.Compression.Deflate_Zlib (Delta_Data);
   end Ref_Delta_Entry_With_Missing_Base;

   function Pack_Sideband_Response
     (Pack_Data : String) return Ada.Streams.Stream_Element_Array is
   begin
      return Sideband_Response (1, Pack_Data);
   end Pack_Sideband_Response;

   function Bad_Pack_Checksum_Response return Ada.Streams.Stream_Element_Array
   is
   begin
      return
        Pack_Sideband_Response
          (Pack_File
             (Object_Count   => Interfaces.Unsigned_32'(0),
              Payload        => "",
              Valid_Checksum => False));
   end Bad_Pack_Checksum_Response;

   function Missing_Delta_Base_Response return Ada.Streams.Stream_Element_Array
   is
   begin
      return
        Pack_Sideband_Response
          (Pack_File
             (Object_Count => Interfaces.Unsigned_32'(1),
              Payload      => Ref_Delta_Entry_With_Missing_Base));
   end Missing_Delta_Base_Response;

   function Object_Mismatch_Response return Ada.Streams.Stream_Element_Array is
   begin
      return
        Pack_Sideband_Response
          (Pack_File
             (Object_Count => Interfaces.Unsigned_32'(1),
              Payload      => Blob_Entry ("not commit")));
   end Object_Mismatch_Response;

   type Fetch_Failure_Mode is
     (Malformed_Pkt_Line_Mode,
      Truncated_Pack_Mode,
      Upload_Pack_Fatal_Mode,
      Unknown_Sideband_Mode,
      Empty_Pack_Mode,
      Bad_Pack_Checksum_Mode,
      Missing_Delta_Base_Mode,
      Object_Mismatch_Mode,
      Tag_Fatal_Mode,
      Http_404_Discovery_Mode,
      No_Shallow_Capability_Mode,
      Shallow_Fatal_Mode);

   task type Fetch_Failure_Server (Mode : Fetch_Failure_Mode) is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Fetch_Failure_Server;

   task body Fetch_Failure_Server is
      CR : constant Character := Character'Val (13);

      Server  : GNAT.Sockets.Socket_Type;
      Address : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Bound   : GNAT.Sockets.Sock_Addr_Type;

      procedure Send_Response
        (Client       : GNAT.Sockets.Socket_Type;
         Status_Line  : String;
         Content_Type : String;
         Payload      : Stream_Element_Array)
      is
         Header : constant Stream_Element_Array :=
           To_Stream
             (Status_Line
              & CR
              & LF
              & "Content-Type: "
              & Content_Type
              & CR
              & LF
              & "Content-Length: "
              & Ada.Strings.Fixed.Trim
                  (Integer'Image (Integer (Payload'Length)), Ada.Strings.Left)
              & CR
              & LF
              & "Connection: close"
              & CR
              & LF
              & CR
              & LF);
         Last   : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Client, Header, Last);
         if Payload'Length > 0 then
            GNAT.Sockets.Send_Socket (Client, Payload, Last);
         end if;
      end Send_Response;

      procedure Serve_Response
        (Content_Type : String; Payload : Stream_Element_Array)
      is
         Client      : GNAT.Sockets.Socket_Type;
         Peer        : GNAT.Sockets.Sock_Addr_Type;
         Request     : Stream_Element_Array (1 .. 8192);
         Request_End : Stream_Element_Offset;
      begin
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         Send_Response (Client, "HTTP/1.1 200 OK", Content_Type, Payload);
         GNAT.Sockets.Close_Socket (Client);
      exception
         when others =>
            begin
               GNAT.Sockets.Close_Socket (Client);
            exception
               when others =>
                  null;
            end;
            raise;
      end Serve_Response;
   begin
      GNAT.Sockets.Create_Socket (Server);
      GNAT.Sockets.Set_Socket_Option
        (Socket => Server,
         Level  => GNAT.Sockets.Socket_Level,
         Option => (Name => GNAT.Sockets.Reuse_Address, Enabled => True));

      GNAT.Sockets.Bind_Socket (Server, Address);
      Bound := GNAT.Sockets.Get_Socket_Name (Server);
      GNAT.Sockets.Listen_Socket (Server);

      accept Ready (Port : out GNAT.Sockets.Port_Type) do
         Port := Bound.Port;
      end Ready;

      case Mode is
         when Http_404_Discovery_Mode    =>
            declare
               Client      : GNAT.Sockets.Socket_Type;
               Peer        : GNAT.Sockets.Sock_Addr_Type;
               Request     : Stream_Element_Array (1 .. 8192);
               Request_End : Stream_Element_Offset;
            begin
               GNAT.Sockets.Accept_Socket (Server, Client, Peer);
               GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
               Send_Response
                 (Client,
                  "HTTP/1.1 404 Not Found",
                  "text/plain",
                  To_Stream ("not found" & LF));
               GNAT.Sockets.Close_Socket (Client);
            end;

         when No_Shallow_Capability_Mode =>
            Serve_Response
              (Content_Type => "application/x-git-upload-pack-advertisement",
               Payload      => Discovery_Stream);

         when Shallow_Fatal_Mode         =>
            Serve_Response
              (Content_Type => "application/x-git-upload-pack-advertisement",
               Payload      => Shallow_Discovery_Stream);
            Serve_Response
              (Content_Type => "application/x-git-upload-pack-result",
               Payload      => Upload_Pack_Fatal_Response);

         when Tag_Fatal_Mode             =>
            Serve_Response
              (Content_Type => "application/x-git-upload-pack-advertisement",
               Payload      => Tag_Discovery_Stream);
            Serve_Response
              (Content_Type => "application/x-git-upload-pack-result",
               Payload      => Upload_Pack_Fatal_Response);

         when others                     =>
            case Mode is
               when Bad_Pack_Checksum_Mode | Missing_Delta_Base_Mode =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-advertisement",
                     Payload      => Shallow_Discovery_Stream);

               when others =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-advertisement",
                     Payload      => Discovery_Stream);
            end case;

            case Mode is
               when Malformed_Pkt_Line_Mode =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Malformed_Pkt_Line_Response);

               when Truncated_Pack_Mode     =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Truncated_Pack_Response);

               when Upload_Pack_Fatal_Mode  =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Upload_Pack_Fatal_Response);

               when Unknown_Sideband_Mode   =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Unknown_Sideband_Response);

               when Empty_Pack_Mode         =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Empty_Pack_Response);

               when Bad_Pack_Checksum_Mode  =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Bad_Pack_Checksum_Response);

               when Missing_Delta_Base_Mode =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Missing_Delta_Base_Response);

               when Object_Mismatch_Mode    =>
                  Serve_Response
                    (Content_Type => "application/x-git-upload-pack-result",
                     Payload      => Object_Mismatch_Response);

               when others                  =>
                  null;
            end case;
      end case;

      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others =>
               null;
         end;
   end Fetch_Failure_Server;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   procedure Fetch_Local_Remote_Branches_And_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");

      Target : constant String := Version.Test_Support.Join (Root, "target");

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File, "source" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source commit");

      Version.Git_Fixtures.Run (Source, "git branch feature");

      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      Version.Fetch.Fetch ("origin");

      Version.Git_Fixtures.Run
        (Target, "test -f .git/refs/remotes/origin/main");

      Version.Git_Fixtures.Run
        (Target, "test -f .git/refs/remotes/origin/feature");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit_Text : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Target, ".git/refs/remotes/origin/main"));
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit_Text),
            "fetched remote main ref must be valid object id");

         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Commit_Text));
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "fetched object must be readable as commit");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Remote_Branches_And_Objects;



   procedure Fetch_Local_Remote_Tags
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source-tags");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target-tags");

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File, "tagged" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("tagged");

      Version.Tags.Create_Tag ("release/v1.0");
      Version.Tags.Create_Annotated_Tag ("release/v1.0-annotated", "annotated release");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");

      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      Version.Fetch.Fetch ("origin");

      Version.Git_Fixtures.Run
        (Target,
         "test ""$(git rev-parse release/v1.0)"" = ""$(git rev-parse origin/main)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Remote_Tags;


   procedure Fetch_Ssh_Tag_Update_Conflict_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source-ssh-tag-conflict");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target-ssh-tag-conflict");

      Bin : constant String := Version.Test_Support.Join (Root, "bin-tag-conflict");
      Fake_Ssh : constant String := Version.Test_Support.Join (Bin, "ssh");

      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Path_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("PATH");
      Old_Path : constant String :=
        (if Old_Path_Exists then Ada.Environment_Variables.Value ("PATH") else "");

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Git_Dir : constant String :=
        Version.Test_Support.Join (Target, ".git");

      Tags_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Git_Dir, "refs"), "tags");

      Conflict_Tag : constant String :=
        Version.Test_Support.Join (Tags_Dir, "conflict");

      Safe_Tag : constant String :=
        Version.Test_Support.Join (Tags_Dir, "safe-tag");

      Remote_Main : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
              "origin"),
           "main");

      Old_Tag_Id : constant String :=
        "6666666666666666666666666666666666666666";

      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Fake_Ssh,
         "#!/bin/sh" & LF
         & "shift" & LF
         & "exec sh -c ""$1""" & LF);
      GNAT.OS_Lib.Set_Executable (Fake_Ssh);
      Ada.Environment_Variables.Set
        ("PATH", Bin & GNAT.OS_Lib.Path_Separator & Old_Path);

      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "ssh tag conflict" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("ssh tag conflict");
      Version.Tags.Create_Tag ("safe-tag");
      Version.Tags.Create_Tag ("conflict/sub");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");

      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Create_Path (Tags_Dir);
      Version.Test_Support.Write_Text_File (Conflict_Tag, Old_Tag_Id & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote
        (Name => "origin", Url => "ssh://fake" & Source & "/.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "conflicting tag ref update must fail fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Conflict_Tag) = Old_Tag_Id,
         "failed tag transaction must preserve conflicting existing tag ref");
      Assert
        (not Ada.Directories.Exists (Safe_Tag),
         "failed tag transaction must not create earlier valid tag ref");
      Assert
        (not Ada.Directories.Exists (Remote_Main),
         "failed tag transaction must not create remote-tracking branch ref");

      if Old_Path_Exists then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         if Old_Path_Exists then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         else
            Ada.Environment_Variables.Clear ("PATH");
         end if;
         raise;
   end Fetch_Ssh_Tag_Update_Conflict_Is_Atomic;

   procedure Fetch_File_Url_Remote_Branches_And_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source-file-url");

      Target : constant String :=
        Version.Test_Support.Join (Root, "target-file-url");

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File, "file url source" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("file url source commit");

      Version.Git_Fixtures.Run (Source, "git branch feature");

      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote (Name => "origin", Url => "file://" & Source);

      Version.Fetch.Fetch ("origin");

      Version.Git_Fixtures.Run
        (Target, "test -f .git/refs/remotes/origin/main");

      Version.Git_Fixtures.Run
        (Target, "test -f .git/refs/remotes/origin/feature");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit_Text : constant String :=
           Version.Test_Support.Read_Text_File
             (Version.Test_Support.Join
                (Target, ".git/refs/remotes/origin/main"));
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit_Text),
            "file URL fetched remote main ref must be valid object id");

         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Commit_Text));
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "file URL fetched object must be readable as commit");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_File_Url_Remote_Branches_And_Objects;

   procedure Fetch_Depth_Rejects_Local_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Source : constant String := Version.Test_Support.Join (Root, "source");

      Target : constant String := Version.Test_Support.Join (Root, "target");

      Old_Dir : constant String := Ada.Directories.Current_Directory;

      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin", 1);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "depth fetch should reject local transports");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Depth_Rejects_Local_Remote;

   procedure Fetch_Missing_Local_Remote_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target         : constant String :=
        Version.Test_Support.Join (Root, "target-missing");
      Missing        : constant String :=
        Version.Test_Support.Join (Root, "missing-source.git");
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Raised         : Boolean := False;
      Remote_Ref_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "remotes"),
           "origin");
   begin
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote (Name => "origin", Url => Missing);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.Directories.Name_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "missing local remote must fail deterministically");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "failed fetch must not create remote-tracking refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Missing_Local_Remote_Does_Not_Update_Refs;

   procedure Fetch_Local_Loose_Tag_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-loose-tag.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-loose-tag");
      Objects : constant String := Version.Test_Support.Join (Source, "objects");
      Remote_Tags : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "refs"), "tags");
      Valid_Tag : constant String := Version.Test_Support.Join (Remote_Tags, "valid-loose");
      Bad_Tag : constant String := Version.Test_Support.Join (Remote_Tags, "bad-loose");
      Local_Tag : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "tags"),
           "valid-loose");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Objects);
      Version.Test_Support.Make_Directory (Remote_Tags);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Version.Test_Support.Write_Text_File
        (Valid_Tag, "1111111111111111111111111111111111111111" & LF);
      Version.Test_Support.Write_Text_File
        (Bad_Tag, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Loose_Tag_Object_Id_Diagnostic,
               "wrong loose tag failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed loose tag refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Tag),
         "failed loose tag fetch must not write earlier staged tag refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Loose_Tag_Failure_Is_Atomic;

   procedure Fetch_Local_Loose_Branch_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-loose-head");
      Target : constant String := Version.Test_Support.Join (Root, "target-loose-head");
      Remote_Heads : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source, ".git"), "refs"),
           "heads");
      Valid_Head : constant String := Version.Test_Support.Join (Remote_Heads, "valid-loose");
      Bad_Head : constant String := Version.Test_Support.Join (Remote_Heads, "bad-loose");
      Local_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Target, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "valid-loose");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Source);
      Commit_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File (Valid_Head, To_String (Commit_Id) & LF);
      Version.Test_Support.Write_Text_File
        (Bad_Head, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Loose_Branch_Object_Id_Diagnostic,
               "wrong loose branch failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed loose branch refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Ref),
         "failed loose branch fetch must not write earlier staged remote ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Loose_Branch_Failure_Is_Atomic;

   procedure Fetch_Local_Special_Tag_Ref_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-special-tag.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-special-tag");
      Source_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "objects"), "aa");
      Source_Object : constant String :=
        Version.Test_Support.Join
          (Source_Object_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Remote_Tags : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "refs"), "tags");
      Link_Path : constant String := Version.Test_Support.Join (Remote_Tags, "link-tag");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Version.Test_Support.Make_Directory (Source_Object_Dir);
      Version.Test_Support.Make_Directory (Remote_Tags);
      Version.Test_Support.Write_Text_File (Source_Object, "remote object content");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Remote_Tags, "real-tag"),
         "1111111111111111111111111111111111111111" & LF);
      Version.Git_Fixtures.Run (Remote_Tags, "ln -s real-tag link-tag");
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid loose ref entry: " & Link_Path,
               "wrong special loose tag diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "special loose tag refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "failed special tag fetch must not copy objects");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Special_Tag_Ref_Does_Not_Copy_Objects;

   procedure Fetch_Local_Special_Head_Ref_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-special-head.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-special-head");
      Source_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "objects"), "aa");
      Source_Object : constant String :=
        Version.Test_Support.Join
          (Source_Object_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Remote_Heads : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "refs"), "heads");
      Link_Path : constant String := Version.Test_Support.Join (Remote_Heads, "link-head");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Version.Test_Support.Make_Directory (Source_Object_Dir);
      Version.Test_Support.Make_Directory (Remote_Heads);
      Version.Test_Support.Write_Text_File (Source_Object, "remote object content");
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Remote_Heads, "real-head"),
         "1111111111111111111111111111111111111111" & LF);
      Version.Git_Fixtures.Run (Remote_Heads, "ln -s real-head link-head");
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid loose ref entry: " & Link_Path,
               "wrong special loose head diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "special loose head refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "failed special head fetch must not copy objects");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Special_Head_Ref_Does_Not_Copy_Objects;

   procedure Fetch_Local_Bad_Ref_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-bad-ref-object.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-bad-ref-object");
      Source_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "objects"), "aa");
      Source_Object : constant String :=
        Version.Test_Support.Join
          (Source_Object_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Packed_Refs : constant String := Version.Test_Support.Join (Source, "packed-refs");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Object_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "remote object content");
      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz refs/tags/bad-packed" & LF);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong object-copy preflight diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "failed local fetch must not copy objects before ref validation succeeds");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Bad_Ref_Does_Not_Copy_Objects;

   procedure Fetch_Local_Loose_Tag_Then_Packed_Tag_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-cross-tag.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-cross-tag");
      Objects : constant String := Version.Test_Support.Join (Source, "objects");
      Remote_Tags : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "refs"), "tags");
      Valid_Tag : constant String := Version.Test_Support.Join (Remote_Tags, "valid-loose");
      Packed_Refs : constant String := Version.Test_Support.Join (Source, "packed-refs");
      Local_Tag : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "tags"),
           "valid-loose");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Objects);
      Version.Test_Support.Make_Directory (Remote_Tags);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Version.Test_Support.Write_Text_File
        (Valid_Tag, "1111111111111111111111111111111111111111" & LF);
      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz refs/tags/bad-packed" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong cross-phase tag failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed tag refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Tag),
         "failed packed tag fetch must not retain earlier loose tag ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Loose_Tag_Then_Packed_Tag_Failure_Is_Atomic;

   procedure Fetch_Local_Loose_Branch_Then_Packed_Branch_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-cross-head");
      Target : constant String := Version.Test_Support.Join (Root, "target-cross-head");
      Remote_Heads : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source, ".git"), "refs"),
           "heads");
      Valid_Head : constant String := Version.Test_Support.Join (Remote_Heads, "valid-loose");
      Packed_Refs : constant String :=
        Version.Test_Support.Join (Version.Test_Support.Join (Source, ".git"), "packed-refs");
      Local_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Target, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "valid-loose");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Source);
      Commit_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File (Valid_Head, To_String (Commit_Id) & LF);
      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz refs/heads/bad-packed" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong cross-phase branch failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed branch refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Ref),
         "failed packed branch fetch must not retain earlier loose remote ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Loose_Branch_Then_Packed_Branch_Failure_Is_Atomic;

   procedure Fetch_Local_Malformed_Packed_Tag_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-packed-tag-syntax.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-packed-tag-syntax");
      Source_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "objects"), "aa");
      Source_Object : constant String :=
        Version.Test_Support.Join
          (Source_Object_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Packed_Refs : constant String := Version.Test_Support.Join (Source, "packed-refs");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Object_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "remote object content");
      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "1111111111111111111111111111111111111111refs/tags/bad" & LF);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong malformed packed tag diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed tag line must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "malformed packed tag line must not copy objects");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Malformed_Packed_Tag_Does_Not_Copy_Objects;

   procedure Fetch_Local_Malformed_Packed_Head_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-packed-head-syntax.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-packed-head-syntax");
      Source_Object_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Source, "objects"), "aa");
      Source_Object : constant String :=
        Version.Test_Support.Join
          (Source_Object_Dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Target_Object : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "aa"),
           "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
      Packed_Refs : constant String := Version.Test_Support.Join (Source, "packed-refs");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source_Object_Dir);
      Version.Test_Support.Write_Text_File (Source_Object, "remote object content");
      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "1111111111111111111111111111111111111111refs/heads/main" & LF);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong malformed packed head diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed head line must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Target_Object),
         "malformed packed head line must not copy objects");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Malformed_Packed_Head_Does_Not_Copy_Objects;

   procedure Fetch_Local_Packed_Tag_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-packed.git");
      Target : constant String := Version.Test_Support.Join (Root, "target-packed");
      Objects : constant String := Version.Test_Support.Join (Source, "objects");
      Packed_Refs : constant String := Version.Test_Support.Join (Source, "packed-refs");
      Local_Tag : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "tags"),
           "valid-packed");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Test_Support.Make_Directory (Objects);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");

      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         "1111111111111111111111111111111111111111 refs/tags/valid-packed" & LF
         & "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz refs/tags/bad-packed" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong packed ref failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed tag refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Tag),
         "failed packed tag fetch must not write earlier staged tag refs");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Packed_Tag_Failure_Is_Atomic;

   procedure Fetch_Local_Packed_Tag_Lock_Rolls_Back_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-packed-tag-lock");
      Target : constant String :=
        Version.Test_Support.Join (Root, "target-packed-tag-lock");
      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
      Target_Git_Dir : constant String :=
        Version.Test_Support.Join (Target, ".git");
      Tag_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Target_Git_Dir, "refs"), "tags"),
           "release");
      Tag_Lock : constant String := Tag_Ref & ".lock";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_Commit : Version.Objects.Object_Id_Storage;
      Source_Tag : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");
      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "source tag lock" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source tag lock commit");
      Source_Commit := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Tags.Create_Annotated_Tag ("release", "annotated release");
      Source_Tag := Version.Tags.Resolve_Tag ("release");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Set_Directory (Target);
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Tag_Ref));
      Version.Test_Support.Write_Text_File (Tag_Lock, "locked" & LF);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale packed tag lock must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Tag_Ref),
         "failed packed tag lock fetch must not create tag ref");
      Assert
        (Ada.Directories.Exists (Tag_Lock),
         "failed packed tag lock fetch must preserve stale lock");
      Assert
        (not Ada.Directories.Exists
           (Loose_Object_Path (Target_Git_Dir, Source_Commit)),
         "failed packed tag lock fetch must roll back copied commit object");
      Assert
        (not Ada.Directories.Exists
           (Loose_Object_Path (Target_Git_Dir, Source_Tag)),
         "failed packed tag lock fetch must roll back copied tag object");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Packed_Tag_Lock_Rolls_Back_Objects;

   procedure Fetch_Local_Packed_Branch_Failure_Is_Atomic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-packed-head");
      Target : constant String := Version.Test_Support.Join (Root, "target-packed-head");
      Packed_Refs : constant String :=
        Version.Test_Support.Join (Version.Test_Support.Join (Source, ".git"), "packed-refs");
      Local_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Target, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "valid-packed");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Version.Git_Fixtures.Run (Target, "git init");

      Ada.Directories.Set_Directory (Source);
      Commit_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Write_Text_File
        (Packed_Refs,
         To_String (Commit_Id) & " refs/heads/valid-packed" & LF
         & "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz refs/heads/bad-packed" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Fetch.Invalid_Packed_Ref_Line_Diagnostic,
               "wrong packed ref failure diagnostic: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed packed branch refs must fail local fetch");
      Assert
        (not Ada.Directories.Exists (Local_Ref),
         "failed packed branch fetch must not write earlier staged remote ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Packed_Branch_Failure_Is_Atomic;

   procedure Fetch_Local_Loose_Head_Lock_Failure_Rolls_Back_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-loose-lock");
      Target : constant String :=
        Version.Test_Support.Join (Root, "target-loose-lock");
      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
      Target_File : constant String :=
        Version.Test_Support.Join (Target, "a.txt");
      Git_Dir : constant String := Version.Test_Support.Join (Target, ".git");
      Remote_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Main_Ref : constant String := Version.Test_Support.Join (Remote_Dir, "main");
      Feature_Ref : constant String :=
        Version.Test_Support.Join (Remote_Dir, "feature");
      Feature_Lock : constant String := Feature_Ref & ".lock";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Id : Version.Objects.Object_Id_Storage;
      Source_Id : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");
      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "source" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source commit");
      Source_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Git_Fixtures.Run (Source, "git branch feature");

      Version.Git_Fixtures.Run (Target, "git init");
      Version.Git_Fixtures.Run
        (Target, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Target, "git config user.name Test");
      Ada.Directories.Set_Directory (Target);
      Version.Test_Support.Write_Text_File
        (Target_File, "target" & Character'Val (10));
      Version.Git_Fixtures.Run (Target, "git add a.txt");
      Version.Write.Save ("target commit");
      Old_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Create_Path (Remote_Dir);
      Version.Test_Support.Write_Text_File (Main_Ref, To_String (Old_Id) & LF);
      Version.Test_Support.Write_Text_File (Feature_Lock, "locked" & LF);

      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale remote-tracking lock must fail local fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) = To_String (Old_Id),
         "failed loose-head fetch must preserve existing origin/main");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) /= To_String (Source_Id),
         "failed loose-head fetch must not advance origin/main");
      Assert
        (not Ada.Directories.Exists (Feature_Ref),
         "failed loose-head fetch must not create origin/feature");
      Assert
        (Ada.Directories.Exists (Feature_Lock),
         "failed loose-head fetch must preserve stale lock for caller cleanup");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Loose_Head_Lock_Failure_Rolls_Back_Refs;

   procedure Fetch_Local_Packed_Head_Lock_Failure_Rolls_Back_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-packed-lock");
      Target : constant String :=
        Version.Test_Support.Join (Root, "target-packed-lock");
      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
      Target_File : constant String :=
        Version.Test_Support.Join (Target, "a.txt");
      Git_Dir : constant String := Version.Test_Support.Join (Target, ".git");
      Remote_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Main_Ref : constant String := Version.Test_Support.Join (Remote_Dir, "main");
      Feature_Ref : constant String :=
        Version.Test_Support.Join (Remote_Dir, "feature");
      Feature_Lock : constant String := Feature_Ref & ".lock";
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Id : Version.Objects.Object_Id_Storage;
      Source_Id : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");
      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "source packed" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source packed commit");
      Source_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Git_Fixtures.Run (Source, "git branch feature");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");

      Version.Git_Fixtures.Run (Target, "git init");
      Version.Git_Fixtures.Run
        (Target, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Target, "git config user.name Test");
      Ada.Directories.Set_Directory (Target);
      Version.Test_Support.Write_Text_File
        (Target_File, "target packed" & Character'Val (10));
      Version.Git_Fixtures.Run (Target, "git add a.txt");
      Version.Write.Save ("target packed commit");
      Old_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Create_Path (Remote_Dir);
      Version.Test_Support.Write_Text_File (Main_Ref, To_String (Old_Id) & LF);
      Version.Test_Support.Write_Text_File (Feature_Lock, "locked" & LF);

      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale packed remote-tracking lock must fail local fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) = To_String (Old_Id),
         "failed packed-head fetch must preserve existing origin/main");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) /= To_String (Source_Id),
         "failed packed-head fetch must not advance origin/main");
      Assert
        (not Ada.Directories.Exists (Feature_Ref),
         "failed packed-head fetch must not create origin/feature");
      Assert
        (Ada.Directories.Exists (Feature_Lock),
         "failed packed-head fetch must preserve stale lock for caller cleanup");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Git_Dir, Source_Id)),
         "failed packed-head fetch must roll back copied source commit object");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Packed_Head_Lock_Failure_Rolls_Back_Refs;

   procedure Fetch_Local_Mixed_Tag_Head_Lock_Rolls_Back_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-mixed-fetch-lock");
      Target : constant String :=
        Version.Test_Support.Join (Root, "target-mixed-fetch-lock");
      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
      Target_File : constant String :=
        Version.Test_Support.Join (Target, "a.txt");
      Git_Dir : constant String := Version.Test_Support.Join (Target, ".git");
      Remote_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Main_Ref : constant String := Version.Test_Support.Join (Remote_Dir, "main");
      Feature_Ref : constant String := Version.Test_Support.Join (Remote_Dir, "feature");
      Feature_Lock : constant String := Feature_Ref & ".lock";
      Tag_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Git_Dir, "refs"), "tags"),
              "release"),
           "mixed");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Old_Id : Version.Objects.Object_Id_Storage;
      Source_Id : Version.Objects.Object_Id_Storage;
      Source_Tag : Version.Objects.Object_Id_Storage;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Ada.Directories.Create_Directory (Target);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");
      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File
        (Source_File, "source mixed fetch" & Character'Val (10));
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source mixed fetch commit");
      Source_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Version.Git_Fixtures.Run (Source, "git branch feature");
      Version.Tags.Create_Annotated_Tag ("release/mixed", "mixed release");
      Source_Tag := Version.Tags.Resolve_Tag ("release/mixed");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");

      Version.Git_Fixtures.Run (Target, "git init");
      Version.Git_Fixtures.Run
        (Target, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Target, "git config user.name Test");
      Ada.Directories.Set_Directory (Target);
      Version.Test_Support.Write_Text_File
        (Target_File, "target mixed fetch" & Character'Val (10));
      Version.Git_Fixtures.Run (Target, "git add a.txt");
      Version.Write.Save ("target mixed fetch commit");
      Old_Id := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Create_Path (Remote_Dir);
      Version.Test_Support.Write_Text_File (Main_Ref, To_String (Old_Id) & LF);
      Version.Test_Support.Write_Text_File (Feature_Lock, "locked" & LF);
      Version.Remotes.Add_Remote (Name => "origin", Url => Source);

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "mixed tag/head lock must fail local fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) = To_String (Old_Id),
         "failed mixed fetch must preserve existing origin/main");
      Assert
        (Version.Test_Support.Read_Text_File (Main_Ref) /= To_String (Source_Id),
         "failed mixed fetch must not advance origin/main");
      Assert
        (not Ada.Directories.Exists (Feature_Ref),
         "failed mixed fetch must not create origin/feature");
      Assert
        (Ada.Directories.Exists (Feature_Lock),
         "failed mixed fetch must preserve stale remote-tracking lock");
      Assert
        (not Ada.Directories.Exists (Tag_Ref),
         "failed mixed fetch must not create tag ref before head lock failure");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Git_Dir, Source_Id)),
         "failed mixed fetch must roll back copied source commit object");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Git_Dir, Source_Tag)),
         "failed mixed fetch must roll back copied source tag object");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Local_Mixed_Tag_Head_Lock_Rolls_Back_Objects;

   procedure Fetch_Malformed_Http_Pkt_Line_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, "target-http-malformed");
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Server          : Fetch_Failure_Server (Malformed_Pkt_Line_Mode);
      Port            : GNAT.Sockets.Port_Type;
      Raised          : Boolean := False;
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "remotes"),
           "origin");
      Remote_Main_Ref : constant String :=
        Version.Test_Support.Join (Remote_Ref_Dir, "main");
      Tmp_Pack        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "pack"),
           "tmp-version-fetch.pack");
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  =>
           "http://127.0.0.1:"
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Integer (Port)), Ada.Strings.Left)
           & "/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when others =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed upload-pack pkt-line must fail fetch");
      Assert
        (not Ada.Directories.Exists (Remote_Main_Ref),
         "malformed pkt-line fetch must not create origin/main");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "malformed pkt-line fetch must not create remote-tracking ref directory");
      Assert
        (not Ada.Directories.Exists (Tmp_Pack),
         "malformed pkt-line fetch must not leave a temporary fetched pack");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Malformed_Http_Pkt_Line_Does_Not_Update_Refs;

   procedure Fetch_Truncated_Http_Pack_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, "target-http-truncated-pack");
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Server          : Fetch_Failure_Server (Truncated_Pack_Mode);
      Port            : GNAT.Sockets.Port_Type;
      Raised          : Boolean := False;
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "remotes"),
           "origin");
      Remote_Main_Ref : constant String :=
        Version.Test_Support.Join (Remote_Ref_Dir, "main");
      Tmp_Pack        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "objects"),
              "pack"),
           "tmp-version-fetch.pack");
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  =>
           "http://127.0.0.1:"
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Integer (Port)), Ada.Strings.Left)
           & "/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when others =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "truncated upload-pack pack must fail fetch");
      Assert
        (not Ada.Directories.Exists (Remote_Main_Ref),
         "truncated pack fetch must not create origin/main");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "truncated pack fetch must not create remote-tracking ref directory");
      Assert
        (not Ada.Directories.Exists (Tmp_Pack),
         "truncated pack fetch must not leave a temporary fetched pack");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Truncated_Http_Pack_Does_Not_Update_Refs;

   procedure Run_Http_Fetch_Failure_No_Mutation
     (T                     : in out AUnit.Test_Cases.Test_Case'Class;
      Mode                  : Fetch_Failure_Mode;
      Target_Name           : String;
      Use_Depth             : Boolean := False;
      Preserve_Existing_Ref : Boolean := False;
      Preserve_Shallow      : Boolean := False)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, Target_Name);
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Server          : Fetch_Failure_Server (Mode);
      Port            : GNAT.Sockets.Port_Type;
      Raised          : Boolean := False;
      Git_Dir         : constant String :=
        Version.Test_Support.Join (Target, ".git");
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Remote_Main_Ref : constant String :=
        Version.Test_Support.Join (Remote_Ref_Dir, "main");
      Tmp_Pack        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.pack");
      Tmp_Idx         : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.idx");
      Shallow_Path    : constant String :=
        Version.Test_Support.Join (Git_Dir, "shallow");
      Work_File       : constant String :=
        Version.Test_Support.Join (Target, "sentinel.txt");
      Old_Ref         : constant String :=
        "2222222222222222222222222222222222222222";
      Old_Shallow_Id  : constant String :=
        "3333333333333333333333333333333333333333";
      Old_Shallow     : constant String := Old_Shallow_Id & LF;
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Version.Test_Support.Write_Text_File (Work_File, "sentinel" & LF);

      if Preserve_Existing_Ref then
         Ada.Directories.Create_Path (Remote_Ref_Dir);
         Version.Test_Support.Write_Text_File (Remote_Main_Ref, Old_Ref & LF);
      end if;

      if Preserve_Shallow then
         Version.Test_Support.Write_Text_File (Shallow_Path, Old_Shallow);
      end if;

      Ada.Directories.Set_Directory (Target);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  =>
           "http://127.0.0.1:"
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Integer (Port)), Ada.Strings.Left)
           & "/repo.git");

      begin
         if Use_Depth then
            Version.Fetch.Fetch ("origin", 1);
         else
            Version.Fetch.Fetch ("origin");
         end if;
      exception
         when others =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "transport failure must fail fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = "sentinel",
         "failed fetch must not mutate working-tree files");
      Assert
        (not Ada.Directories.Exists (Tmp_Pack),
         "failed fetch must not leave a temporary fetched pack");
      Assert
        (not Ada.Directories.Exists (Tmp_Idx),
         "failed fetch must not leave a temporary fetched pack index");

      if Preserve_Existing_Ref then
         Assert
           (Ada.Directories.Exists (Remote_Main_Ref),
            "failed fetch must preserve existing remote-tracking ref");
         Assert
           (Version.Test_Support.Read_Text_File (Remote_Main_Ref)
            = Old_Ref,
            "failed fetch must not update existing remote-tracking ref");
      else
         Assert
           (not Ada.Directories.Exists (Remote_Main_Ref),
            "failed fetch must not create origin/main");
         Assert
           (not Ada.Directories.Exists (Remote_Ref_Dir),
            "failed fetch must not create remote-tracking ref directory");
      end if;

      if Preserve_Shallow then
         Assert
           (Ada.Directories.Exists (Shallow_Path),
            "failed shallow fetch must preserve existing shallow file");
         Assert
           (Version.Test_Support.Read_Text_File (Shallow_Path) = Old_Shallow_Id,
            "failed shallow fetch must not rewrite shallow metadata");
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Run_Http_Fetch_Failure_No_Mutation;

   procedure Fetch_Http_Upload_Pack_Fatal_Does_Not_Update_Existing_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Upload_Pack_Fatal_Mode,
         Target_Name           => "target-http-upload-pack-fatal",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Upload_Pack_Fatal_Does_Not_Update_Existing_Refs;

   procedure Fetch_Http_Malformed_Pkt_Line_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Malformed_Pkt_Line_Mode,
         Target_Name           => "target-http-malformed-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Malformed_Pkt_Line_Preserves_Existing_Ref;

   procedure Fetch_Http_Truncated_Pack_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Truncated_Pack_Mode,
         Target_Name           => "target-http-truncated-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Truncated_Pack_Preserves_Existing_Ref;

   procedure Fetch_Http_Unknown_Sideband_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Unknown_Sideband_Mode,
         Target_Name           => "target-http-unknown-sideband-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Unknown_Sideband_Preserves_Existing_Ref;

   procedure Fetch_Http_Empty_Pack_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Empty_Pack_Mode,
         Target_Name           => "target-http-empty-pack-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Empty_Pack_Preserves_Existing_Ref;

   procedure Fetch_Http_Bad_Pack_Checksum_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Bad_Pack_Checksum_Mode,
         Target_Name => "target-http-bad-pack-checksum");
   end Fetch_Http_Bad_Pack_Checksum_Does_Not_Update_Refs;

   procedure Fetch_Http_Missing_Delta_Base_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Missing_Delta_Base_Mode,
         Target_Name => "target-http-missing-delta-base");
   end Fetch_Http_Missing_Delta_Base_Does_Not_Update_Refs;

   procedure Fetch_Http_Object_Mismatch_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Object_Mismatch_Mode,
         Target_Name => "target-http-object-mismatch");
   end Fetch_Http_Object_Mismatch_Does_Not_Update_Refs;

   procedure Fetch_Http_Bad_Pack_Checksum_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Bad_Pack_Checksum_Mode,
         Target_Name           => "target-http-bad-pack-checksum-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Bad_Pack_Checksum_Preserves_Existing_Ref;

   procedure Fetch_Http_Missing_Delta_Base_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Missing_Delta_Base_Mode,
         Target_Name           =>
           "target-http-missing-delta-base-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Missing_Delta_Base_Preserves_Existing_Ref;

   procedure Fetch_Http_Object_Mismatch_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Object_Mismatch_Mode,
         Target_Name           => "target-http-object-mismatch-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_Object_Mismatch_Preserves_Existing_Ref;

   procedure Fetch_Http_Bad_Pack_Checksum_Preserves_Ref_And_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Bad_Pack_Checksum_Mode,
         Target_Name           => "target-http-bad-pack-shallow-existing-ref",
         Use_Depth             => True,
         Preserve_Existing_Ref => True,
         Preserve_Shallow      => True);
   end Fetch_Http_Bad_Pack_Checksum_Preserves_Ref_And_Shallow;

   procedure Fetch_Http_Missing_Delta_Base_Preserves_Ref_And_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Missing_Delta_Base_Mode,
         Target_Name           =>
           "target-http-missing-delta-shallow-existing-ref",
         Use_Depth             => True,
         Preserve_Existing_Ref => True,
         Preserve_Shallow      => True);
   end Fetch_Http_Missing_Delta_Base_Preserves_Ref_And_Shallow;

   procedure Fetch_Http_404_Discovery_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Http_404_Discovery_Mode,
         Target_Name           => "target-http-404-existing-ref",
         Preserve_Existing_Ref => True);
   end Fetch_Http_404_Discovery_Preserves_Existing_Ref;

   procedure Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Ref_And_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => No_Shallow_Capability_Mode,
         Target_Name           => "target-http-no-shallow-existing-ref",
         Use_Depth             => True,
         Preserve_Existing_Ref => True,
         Preserve_Shallow      => True);
   end Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Ref_And_Shallow;

   procedure Fetch_Http_Shallow_Fatal_Preserves_Ref_And_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                     => T,
         Mode                  => Shallow_Fatal_Mode,
         Target_Name           => "target-http-shallow-fatal-existing-ref",
         Use_Depth             => True,
         Preserve_Existing_Ref => True,
         Preserve_Shallow      => True);
   end Fetch_Http_Shallow_Fatal_Preserves_Ref_And_Shallow;

   procedure Fetch_Http_Unknown_Sideband_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Unknown_Sideband_Mode,
         Target_Name => "target-http-unknown-sideband");
   end Fetch_Http_Unknown_Sideband_Does_Not_Update_Refs;

   procedure Fetch_Http_Empty_Pack_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Empty_Pack_Mode,
         Target_Name => "target-http-empty-pack");
   end Fetch_Http_Empty_Pack_Does_Not_Update_Refs;

   procedure Fetch_Http_404_Discovery_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T           => T,
         Mode        => Http_404_Discovery_Mode,
         Target_Name => "target-http-404-discovery");
   end Fetch_Http_404_Discovery_Does_Not_Update_Refs;

   procedure Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                => T,
         Mode             => No_Shallow_Capability_Mode,
         Target_Name      => "target-http-no-shallow-capability",
         Use_Depth        => True,
         Preserve_Shallow => True);
   end Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Shallow;

   procedure Fetch_Http_Shallow_Fatal_Preserves_Shallow
     (T : in out AUnit.Test_Cases.Test_Case'Class) is
   begin
      Run_Http_Fetch_Failure_No_Mutation
        (T                => T,
         Mode             => Shallow_Fatal_Mode,
         Target_Name      => "target-http-shallow-fatal",
         Use_Depth        => True,
         Preserve_Shallow => True);
   end Fetch_Http_Shallow_Fatal_Preserves_Shallow;

   procedure Fetch_Http_Tag_Failure_Preserves_Tag_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, "target-http-tag-failure");
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Server          : Fetch_Failure_Server (Tag_Fatal_Mode);
      Port            : GNAT.Sockets.Port_Type;
      Raised          : Boolean := False;
      Git_Dir         : constant String :=
        Version.Test_Support.Join (Target, ".git");
      Tags_Dir        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Git_Dir, "refs"), "tags");
      Existing_Tag    : constant String :=
        Version.Test_Support.Join (Tags_Dir, "existing-annotated");
      New_Tag         : constant String :=
        Version.Test_Support.Join (Tags_Dir, "new-lightweight");
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Tmp_Pack        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.pack");
      Tmp_Idx         : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.idx");
      Old_Tag_Id      : constant String :=
        "5555555555555555555555555555555555555555";
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Create_Path (Tags_Dir);
      Version.Test_Support.Write_Text_File (Existing_Tag, Old_Tag_Id & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  =>
           "http://127.0.0.1:"
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Integer (Port)), Ada.Strings.Left)
           & "/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when others =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "HTTP tag upload-pack failure must fail fetch");
      Assert
        (Ada.Directories.Exists (Existing_Tag),
         "failed HTTP tag fetch must preserve existing tag ref");
      Assert
        (Version.Test_Support.Read_Text_File (Existing_Tag) = Old_Tag_Id,
         "failed HTTP tag fetch must not update existing tag ref");
      Assert
        (not Ada.Directories.Exists (New_Tag),
         "failed HTTP tag fetch must not create new tag ref");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "failed HTTP tag fetch must not create remote-tracking refs");
      Assert
        (not Ada.Directories.Exists (Tmp_Pack),
         "failed HTTP tag fetch must not leave a temporary fetched pack");
      Assert
        (not Ada.Directories.Exists (Tmp_Idx),
         "failed HTTP tag fetch must not leave a temporary fetched pack index");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Http_Tag_Failure_Preserves_Tag_Refs;

   procedure Fetch_Ssh_Backend_Failure_Does_Not_Update_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root           : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target         : constant String :=
        Version.Test_Support.Join (Root, "target-ssh-failure");
      Bin            : constant String := Version.Test_Support.Join (Root, "bin");
      Fake_Ssh       : constant String := Version.Test_Support.Join (Bin, "ssh");
      Old_Dir        : constant String := Ada.Directories.Current_Directory;
      Old_Path_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("PATH");
      Old_Path       : constant String :=
        (if Old_Path_Exists then Ada.Environment_Variables.Value ("PATH") else "");
      Raised         : Boolean := False;
      Remote_Ref_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Target, ".git"), "refs"),
              "remotes"),
           "origin");
      Work_File      : constant String :=
        Version.Test_Support.Join (Target, "sentinel.txt");
   begin
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Fake_Ssh, "#!/bin/sh" & LF & "exit 7" & LF);
      GNAT.OS_Lib.Set_Executable (Fake_Ssh);
      Ada.Environment_Variables.Set
        ("PATH", Bin & GNAT.OS_Lib.Path_Separator & Old_Path);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Version.Test_Support.Write_Text_File (Work_File, "sentinel" & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote
        (Name => "origin", Url => "ssh://git@example.com/group/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "SSH backend failure must fail fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = "sentinel",
         "failed SSH fetch must not mutate working-tree files");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "failed SSH fetch must not create remote-tracking refs");
      if Old_Path_Exists then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         if Old_Path_Exists then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         else
            Ada.Environment_Variables.Clear ("PATH");
         end if;
         raise;
   end Fetch_Ssh_Backend_Failure_Does_Not_Update_Refs;

   procedure Fetch_Ssh_Backend_Failure_Preserves_Existing_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, "target-ssh-existing-ref");
      Bin             : constant String := Version.Test_Support.Join (Root, "bin");
      Fake_Ssh        : constant String := Version.Test_Support.Join (Bin, "ssh");
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Old_Path_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("PATH");
      Old_Path        : constant String :=
        (if Old_Path_Exists then Ada.Environment_Variables.Value ("PATH") else "");
      Raised          : Boolean := False;
      Git_Dir         : constant String :=
        Version.Test_Support.Join (Target, ".git");
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Remote_Main_Ref : constant String :=
        Version.Test_Support.Join (Remote_Ref_Dir, "main");
      Work_File       : constant String :=
        Version.Test_Support.Join (Target, "sentinel.txt");
      Old_Ref         : constant String :=
        "4444444444444444444444444444444444444444";
   begin
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Fake_Ssh, "#!/bin/sh" & LF & "exit 7" & LF);
      GNAT.OS_Lib.Set_Executable (Fake_Ssh);
      Ada.Environment_Variables.Set
        ("PATH", Bin & GNAT.OS_Lib.Path_Separator & Old_Path);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Version.Test_Support.Write_Text_File (Work_File, "sentinel" & LF);
      Ada.Directories.Create_Path (Remote_Ref_Dir);
      Version.Test_Support.Write_Text_File (Remote_Main_Ref, Old_Ref & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote
        (Name => "origin", Url => "ssh://git@example.com/group/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "SSH backend failure must fail fetch");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = "sentinel",
         "failed SSH fetch must not mutate working-tree files");
      Assert
        (Ada.Directories.Exists (Remote_Main_Ref),
         "failed SSH fetch must preserve existing remote-tracking ref");
      Assert
        (Version.Test_Support.Read_Text_File (Remote_Main_Ref) = Old_Ref,
         "failed SSH fetch must not update existing remote-tracking ref");
      if Old_Path_Exists then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         if Old_Path_Exists then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         else
            Ada.Environment_Variables.Clear ("PATH");
         end if;
         raise;
   end Fetch_Ssh_Backend_Failure_Preserves_Existing_Ref;

   procedure Fetch_Ssh_Tag_Failure_Preserves_Tag_Refs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root            : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Target          : constant String :=
        Version.Test_Support.Join (Root, "target-ssh-tag-failure");
      Bin             : constant String := Version.Test_Support.Join (Root, "bin-tags-fail");
      Fake_Ssh        : constant String := Version.Test_Support.Join (Bin, "ssh");
      Old_Dir         : constant String := Ada.Directories.Current_Directory;
      Old_Path_Exists : constant Boolean :=
        Ada.Environment_Variables.Exists ("PATH");
      Old_Path        : constant String :=
        (if Old_Path_Exists then Ada.Environment_Variables.Value ("PATH") else "");
      Raised          : Boolean := False;
      Git_Dir         : constant String :=
        Version.Test_Support.Join (Target, ".git");
      Tags_Dir        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Git_Dir, "refs"), "tags");
      Existing_Tag    : constant String :=
        Version.Test_Support.Join (Tags_Dir, "existing-annotated");
      New_Tag         : constant String :=
        Version.Test_Support.Join (Tags_Dir, "new-lightweight");
      Remote_Ref_Dir  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "refs"), "remotes"),
           "origin");
      Tmp_Pack        : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.pack");
      Tmp_Idx         : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"), "pack"),
           "tmp-version-fetch.idx");
      Old_Tag_Id      : constant String :=
        "4444444444444444444444444444444444444444";
   begin
      Version.Test_Support.Make_Directory (Bin);
      Version.Test_Support.Write_Text_File
        (Fake_Ssh,
         "#!/bin/sh" & LF
         & "printf '007c1111111111111111111111111111111111111111"
         & " HEAD\000multi_ack side-band-64k ofs-delta include-tag"
         & " symref=HEAD:refs/heads/main\n'" & LF
         & "printf '003d1111111111111111111111111111111111111111 refs/heads/main\n'" & LF
         & "printf '00472222222222222222222222222222222222222222 refs/tags/new-lightweight\n'" & LF
         & "printf '004a3333333333333333333333333333333333333333 refs/tags/existing-annotated\n'" & LF
         & "printf '004d1111111111111111111111111111111111111111 refs/tags/existing-annotated^{}\n'" & LF
         & "printf '0000'" & LF
         & "sleep 1" & LF
         & "printf 'zzzz'" & LF
         & "exit 7" & LF);
      GNAT.OS_Lib.Set_Executable (Fake_Ssh);
      Ada.Environment_Variables.Set
        ("PATH", Bin & GNAT.OS_Lib.Path_Separator & Old_Path);

      Ada.Directories.Create_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Ada.Directories.Create_Path (Tags_Dir);
      Version.Test_Support.Write_Text_File (Existing_Tag, Old_Tag_Id & LF);

      Ada.Directories.Set_Directory (Target);
      Version.Remotes.Add_Remote
        (Name => "origin", Url => "ssh://git@example.com/group/repo.git");

      begin
         Version.Fetch.Fetch ("origin");
      exception
         when Ada.IO_Exceptions.Use_Error | Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed SSH upload-pack response must fail fetch");
      Assert
        (Ada.Directories.Exists (Existing_Tag),
         "failed SSH tag fetch must preserve existing tag ref");
      Assert
        (Version.Test_Support.Read_Text_File (Existing_Tag) = Old_Tag_Id,
         "failed SSH tag fetch must not update existing tag ref");
      Assert
        (not Ada.Directories.Exists (New_Tag),
         "failed SSH tag fetch must not create new tag ref");
      Assert
        (not Ada.Directories.Exists (Remote_Ref_Dir),
         "failed SSH tag fetch must not create remote-tracking refs");
      Assert
        (not Ada.Directories.Exists (Tmp_Pack),
         "failed SSH tag fetch must not leave a temporary fetched pack");
      Assert
        (not Ada.Directories.Exists (Tmp_Idx),
         "failed SSH tag fetch must not leave a temporary fetched pack index");

      if Old_Path_Exists then
         Ada.Environment_Variables.Set ("PATH", Old_Path);
      else
         Ada.Environment_Variables.Clear ("PATH");
      end if;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         if Old_Path_Exists then
            Ada.Environment_Variables.Set ("PATH", Old_Path);
         else
            Ada.Environment_Variables.Clear ("PATH");
         end if;
         raise;
   end Fetch_Ssh_Tag_Failure_Preserves_Tag_Refs;

   procedure Fetch_Internal_Rejects_Stale_Remote_Tracking_Update
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String :=
        Version.Test_Support.Join (Root, "fetch-stale-tracking");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Ref_Name : constant String := "refs/remotes/origin/main";
      Ref_Path : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Repo_Path, ".git"), Ref_Name);
      A_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("1111111111111111111111111111111111111111");
      B_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("2222222222222222222222222222222222222222");
      C_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("3333333333333333333333333333333333333333");
      Tx     : Version.Ref_Transaction.Transaction;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Repo_Path);
      Version.Init.Init (Repo_Path);
      Ada.Directories.Set_Directory (Repo_Path);

      Version.Refs.Atomic_Write_Ref (Path => Ref_Path, Object_Id => A_Id);

      Version.Ref_Transaction.Start (Tx, Version.Repository.Open);
      Version.Fetch.Internal.Add_Update_With_Current_Old
        (Tx       => Tx,
         Repo     => Version.Repository.Open,
         Ref_Name => Ref_Name,
         New_Id   => C_Id);

      Version.Refs.Atomic_Write_Ref (Path => Ref_Path, Object_Id => B_Id);

      begin
         Version.Ref_Transaction.Commit (Tx);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Ref_Transaction.Expected_Old_Mismatch_Diagnostic
                   ("refs/remotes/origin/main"),
               "fetch expected-old diagnostic changed: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale fetch remote-tracking update must be rejected");
      Assert
        (Version.Test_Support.Read_Text_File (Ref_Path) = To_String (B_Id),
         "stale fetch update must preserve concurrently advanced tracking ref");
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Fetch_Internal_Rejects_Stale_Remote_Tracking_Update;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Fetch_Local_Remote_Branches_And_Objects'Access,
         "Fetch: local remote branches and objects");



      Register_Routine
        (T, Fetch_Local_Remote_Tags'Access, "Fetch: local remote tags");


      Register_Routine
        (T,
         Fetch_Ssh_Tag_Update_Conflict_Is_Atomic'Access,
         "Fetch: SSH tag update conflict is atomic");

      Register_Routine
        (T,
         Fetch_File_Url_Remote_Branches_And_Objects'Access,
         "Fetch: file URL remote branches and objects");

      Register_Routine
        (T,
         Fetch_Depth_Rejects_Local_Remote'Access,
         "Fetch: depth rejects local remote");

      Register_Routine
        (T,
         Fetch_Missing_Local_Remote_Does_Not_Update_Refs'Access,
         "Fetch: failed local remote does not update refs");

      Register_Routine
        (T,
         Fetch_Local_Loose_Tag_Failure_Is_Atomic'Access,
         "Fetch: local loose tag failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Loose_Branch_Failure_Is_Atomic'Access,
         "Fetch: local loose branch failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Special_Tag_Ref_Does_Not_Copy_Objects'Access,
         "Fetch: local special tag ref does not copy objects");

      Register_Routine
        (T,
         Fetch_Local_Special_Head_Ref_Does_Not_Copy_Objects'Access,
         "Fetch: local special head ref does not copy objects");

      Register_Routine
        (T,
         Fetch_Local_Bad_Ref_Does_Not_Copy_Objects'Access,
         "Fetch: local bad ref does not copy objects");

      Register_Routine
        (T,
         Fetch_Local_Loose_Tag_Then_Packed_Tag_Failure_Is_Atomic'Access,
         "Fetch: local loose tag then packed tag failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Loose_Branch_Then_Packed_Branch_Failure_Is_Atomic'Access,
         "Fetch: local loose branch then packed branch failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Malformed_Packed_Tag_Does_Not_Copy_Objects'Access,
         "Fetch: local malformed packed tag does not copy objects");

      Register_Routine
        (T,
         Fetch_Local_Malformed_Packed_Head_Does_Not_Copy_Objects'Access,
         "Fetch: local malformed packed head does not copy objects");

      Register_Routine
        (T,
         Fetch_Local_Packed_Tag_Failure_Is_Atomic'Access,
         "Fetch: local packed tag failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Packed_Tag_Lock_Rolls_Back_Objects'Access,
         "Fetch: local packed tag lock rolls back copied objects");

      Register_Routine
        (T,
         Fetch_Local_Packed_Branch_Failure_Is_Atomic'Access,
         "Fetch: local packed branch failure is atomic");

      Register_Routine
        (T,
         Fetch_Local_Loose_Head_Lock_Failure_Rolls_Back_Refs'Access,
         "Fetch: local loose head lock failure rolls back refs");

      Register_Routine
        (T,
         Fetch_Local_Packed_Head_Lock_Failure_Rolls_Back_Refs'Access,
         "Fetch: local packed head lock failure rolls back refs");

      Register_Routine
        (T,
         Fetch_Local_Mixed_Tag_Head_Lock_Rolls_Back_Objects'Access,
         "Fetch: local mixed tag/head lock rolls back refs and objects");

      Register_Routine
        (T,
         Fetch_Malformed_Http_Pkt_Line_Does_Not_Update_Refs'Access,
         "Fetch: malformed HTTP pkt-line does not update refs");

      Register_Routine
        (T,
         Fetch_Truncated_Http_Pack_Does_Not_Update_Refs'Access,
         "Fetch: truncated HTTP pack does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Upload_Pack_Fatal_Does_Not_Update_Existing_Refs'Access,
         "Fetch: upload-pack fatal preserves existing refs");

      Register_Routine
        (T,
         Fetch_Http_Malformed_Pkt_Line_Preserves_Existing_Ref'Access,
         "Fetch: malformed pkt-line preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Truncated_Pack_Preserves_Existing_Ref'Access,
         "Fetch: truncated pack preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Unknown_Sideband_Preserves_Existing_Ref'Access,
         "Fetch: unknown sideband preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Empty_Pack_Preserves_Existing_Ref'Access,
         "Fetch: missing required object preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Bad_Pack_Checksum_Does_Not_Update_Refs'Access,
         "Fetch: bad pack checksum does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Missing_Delta_Base_Does_Not_Update_Refs'Access,
         "Fetch: missing delta base does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Object_Mismatch_Does_Not_Update_Refs'Access,
         "Fetch: advertised object mismatch does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Bad_Pack_Checksum_Preserves_Existing_Ref'Access,
         "Fetch: bad pack checksum preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Missing_Delta_Base_Preserves_Existing_Ref'Access,
         "Fetch: missing delta base preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Object_Mismatch_Preserves_Existing_Ref'Access,
         "Fetch: advertised object mismatch preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Bad_Pack_Checksum_Preserves_Ref_And_Shallow'Access,
         "Fetch: bad pack checksum preserves existing ref and shallow metadata");

      Register_Routine
        (T,
         Fetch_Http_Missing_Delta_Base_Preserves_Ref_And_Shallow'Access,
         "Fetch: missing delta base preserves existing ref and shallow metadata");

      Register_Routine
        (T,
         Fetch_Http_404_Discovery_Preserves_Existing_Ref'Access,
         "Fetch: HTTP discovery failure preserves existing ref");

      Register_Routine
        (T,
         Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Ref_And_Shallow'Access,
         "Fetch: shallow capability failure preserves ref and shallow file");

      Register_Routine
        (T,
         Fetch_Http_Shallow_Fatal_Preserves_Ref_And_Shallow'Access,
         "Fetch: shallow transport failure preserves ref and shallow file");

      Register_Routine
        (T,
         Fetch_Http_Unknown_Sideband_Does_Not_Update_Refs'Access,
         "Fetch: unknown sideband does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Empty_Pack_Does_Not_Update_Refs'Access,
         "Fetch: missing required object does not update refs");

      Register_Routine
        (T,
         Fetch_Http_404_Discovery_Does_Not_Update_Refs'Access,
         "Fetch: HTTP discovery failure does not update refs");

      Register_Routine
        (T,
         Fetch_Http_Depth_Without_Shallow_Capability_Preserves_Shallow'Access,
         "Fetch: shallow capability failure preserves shallow file");

      Register_Routine
        (T,
         Fetch_Http_Shallow_Fatal_Preserves_Shallow'Access,
         "Fetch: shallow transport failure preserves shallow file");

      Register_Routine
        (T,
         Fetch_Http_Tag_Failure_Preserves_Tag_Refs'Access,
         "Fetch: HTTP tag failure preserves tag refs");

      Register_Routine
        (T,
         Fetch_Ssh_Backend_Failure_Does_Not_Update_Refs'Access,
         "Fetch: SSH backend failure does not update refs");

      Register_Routine
        (T,
         Fetch_Internal_Rejects_Stale_Remote_Tracking_Update'Access,
         "Fetch: rejects stale remote-tracking transaction update");

      Register_Routine
        (T,
         Fetch_Ssh_Backend_Failure_Preserves_Existing_Ref'Access,
         "Fetch: SSH backend failure preserves existing ref");

      Register_Routine
        (T,
         Fetch_Ssh_Tag_Failure_Preserves_Tag_Refs'Access,
         "Fetch: SSH tag failure preserves tag refs");

   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Fetch");
   end Name;

end Version.Fetch.Tests;
