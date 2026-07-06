with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.Sockets;

with Version.Platform;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Clone;
with Version.Files;
with Version.Git_Fixtures;
with Version.Objects;
with Version.Pkt_Line;
with Version.Push.Internal;
with Version.Remotes;
with Version.Repository;
with Version.Refs;
with Version.Test_Support;
with Version.Write;
with Version.Tags;

package body Version.Push.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use type Version.Objects.Tree_Entry_Kind;
   use type Version.Platform.Platform_Kind;
   use AUnit.Test_Cases.Registration;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

   function To_Stream
     (Text : String)
      return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array
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
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (A'Length + B'Length));
      Pos : Ada.Streams.Stream_Element_Offset := Result'First;
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

   function Receive_Pack_Discovery_Stream
      return Ada.Streams.Stream_Element_Array
   is
      Service : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-receive-pack" & LF));
      Flush_1 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
      Head : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             ("0000000000000000000000000000000000000000 capabilities^{}" & NUL
              & "report-status ofs-delta" & LF));
      Flush_2 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
   begin
      return Concat (Concat (Concat (Service, Flush_1), Head), Flush_2);
   end Receive_Pack_Discovery_Stream;

   function Receive_Pack_Rejection_Stream
      return Ada.Streams.Stream_Element_Array
   is
      Report : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("unpack ok" & LF & "ng refs/heads/main rejected" & LF));
   begin
      return Concat (Report, Version.Pkt_Line.Encode_Flush);
   end Receive_Pack_Rejection_Stream;

   task type Receive_Pack_Rejection_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Receive_Pack_Rejection_Server;

   task body Receive_Pack_Rejection_Server is

      CR : constant Character := Character'Val (13);
      Server  : GNAT.Sockets.Socket_Type;
      Address : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Bound   : GNAT.Sockets.Sock_Addr_Type;

      procedure Send_Response
        (Client       : GNAT.Sockets.Socket_Type;
         Content_Type : String;
         Payload         : Stream_Element_Array)
      is
         Header : constant Stream_Element_Array :=
           To_Stream
             ("HTTP/1.1 200 OK" & CR & LF
              & "Content-Type: " & Content_Type & CR & LF
              & "Content-Length: "
              & Ada.Strings.Fixed.Trim
                  (Integer'Image (Integer (Payload'Length)), Ada.Strings.Left)
              & CR & LF
              & "Connection: close" & CR & LF
              & CR & LF);
         Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Client, Header, Last);
         if Payload'Length > 0 then
            GNAT.Sockets.Send_Socket (Client, Payload, Last);
         end if;
      end Send_Response;

      procedure Serve_Response
        (Content_Type : String;
         Payload         : Stream_Element_Array)
      is
         Client      : GNAT.Sockets.Socket_Type;
         Peer        : GNAT.Sockets.Sock_Addr_Type;
         Request     : Stream_Element_Array (1 .. 8192);
         Request_End : Stream_Element_Offset;
      begin
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         Send_Response (Client, Content_Type, Payload);
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
         Option => (Name => GNAT.Sockets.Reuse_Address,
                    Enabled => True));
      GNAT.Sockets.Bind_Socket (Server, Address);
      Bound := GNAT.Sockets.Get_Socket_Name (Server);
      GNAT.Sockets.Listen_Socket (Server);

      accept Ready (Port : out GNAT.Sockets.Port_Type) do
         Port := Bound.Port;
      end Ready;

      Serve_Response
        (Content_Type => "application/x-git-receive-pack-advertisement",
         Payload         => Receive_Pack_Discovery_Stream);
      Serve_Response
        (Content_Type => "application/x-git-receive-pack-result",
         Payload         => Receive_Pack_Rejection_Stream);

      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others =>
               null;
         end;
   end Receive_Pack_Rejection_Server;

   task type Receive_Pack_Discovery_Only_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Receive_Pack_Discovery_Only_Server;

   task body Receive_Pack_Discovery_Only_Server is
      CR : constant Character := Character'Val (13);
      Server  : GNAT.Sockets.Socket_Type;
      Address : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Bound   : GNAT.Sockets.Sock_Addr_Type;

      procedure Send_Discovery (Client : GNAT.Sockets.Socket_Type) is
         Payload : constant Stream_Element_Array := Receive_Pack_Discovery_Stream;
         Header : constant Stream_Element_Array :=
           To_Stream
             ("HTTP/1.1 200 OK" & CR & LF
              & "Content-Type: application/x-git-receive-pack-advertisement"
              & CR & LF
              & "Content-Length: "
              & Ada.Strings.Fixed.Trim
                  (Integer'Image (Integer (Payload'Length)), Ada.Strings.Left)
              & CR & LF
              & "Connection: close" & CR & LF
              & CR & LF);
         Header_Last  : Stream_Element_Offset;
         Payload_Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Client, Header, Header_Last);
         GNAT.Sockets.Send_Socket (Client, Payload, Payload_Last);
      end Send_Discovery;

      Client      : GNAT.Sockets.Socket_Type;
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 8192);
      Request_End : Stream_Element_Offset;
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
      Send_Discovery (Client);
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
   end Receive_Pack_Discovery_Only_Server;

   --  Discovery advertising refs/tags/v1 at a different object id, so a tag
   --  push must refuse to overwrite it (raising before any pack upload).
   function Receive_Pack_Tag_Conflict_Stream
      return Ada.Streams.Stream_Element_Array
   is
      Service : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-receive-pack" & LF));
      Flush_1 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
      Head : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             ("1111111111111111111111111111111111111111 refs/tags/v1" & NUL
              & "report-status ofs-delta" & LF));
      Flush_2 : constant Ada.Streams.Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
   begin
      return Concat (Concat (Concat (Service, Flush_1), Head), Flush_2);
   end Receive_Pack_Tag_Conflict_Stream;

   task type Receive_Pack_Tag_Conflict_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Receive_Pack_Tag_Conflict_Server;

   task body Receive_Pack_Tag_Conflict_Server is
      CR : constant Character := Character'Val (13);
      Server  : GNAT.Sockets.Socket_Type;
      Address : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Bound   : GNAT.Sockets.Sock_Addr_Type;

      procedure Send_Discovery (Client : GNAT.Sockets.Socket_Type) is
         Payload : constant Stream_Element_Array :=
           Receive_Pack_Tag_Conflict_Stream;
         Header : constant Stream_Element_Array :=
           To_Stream
             ("HTTP/1.1 200 OK" & CR & LF
              & "Content-Type: application/x-git-receive-pack-advertisement"
              & CR & LF
              & "Content-Length: "
              & Ada.Strings.Fixed.Trim
                  (Integer'Image (Integer (Payload'Length)), Ada.Strings.Left)
              & CR & LF
              & "Connection: close" & CR & LF
              & CR & LF);
         Header_Last  : Stream_Element_Offset;
         Payload_Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Client, Header, Header_Last);
         GNAT.Sockets.Send_Socket (Client, Payload, Payload_Last);
      end Send_Discovery;

      Client      : GNAT.Sockets.Socket_Type;
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 8192);
      Request_End : Stream_Element_Offset;
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
      Send_Discovery (Client);
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
   end Receive_Pack_Tag_Conflict_Server;

   type Push_Failure_Mode is
     (Drop_Before_Report_Status,
      Remote_Unpack_Error,
      Non_Fast_Forward_Report_Status,
      Partial_Report_Status);

   function Receive_Pack_Failure_Stream
     (Mode : Push_Failure_Mode)
      return Ada.Streams.Stream_Element_Array
   is
   begin
      case Mode is
         when Remote_Unpack_Error =>
            return
              Concat
                (Version.Pkt_Line.Encode_Data
                   (To_Stream ("unpack error remote unpack failed" & LF)),
                 Version.Pkt_Line.Encode_Flush);

         when Non_Fast_Forward_Report_Status =>
            return
              Concat
                (Version.Pkt_Line.Encode_Data
                   (To_Stream
                      ("unpack ok" & LF
                       & "ng refs/heads/main non-fast-forward" & LF)),
                 Version.Pkt_Line.Encode_Flush);

         when Partial_Report_Status =>
            return
              Concat
                (Version.Pkt_Line.Encode_Data
                   (To_Stream ("unpack ok" & LF)),
                 Version.Pkt_Line.Encode_Flush);

         when Drop_Before_Report_Status =>
            return To_Stream ("");
      end case;
   end Receive_Pack_Failure_Stream;

   task type Receive_Pack_Failure_Server (Mode : Push_Failure_Mode) is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Receive_Pack_Failure_Server;

   task body Receive_Pack_Failure_Server is
      CR : constant Character := Character'Val (13);
      Server  : GNAT.Sockets.Socket_Type;
      Address : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Bound   : GNAT.Sockets.Sock_Addr_Type;

      procedure Send_Response
        (Client       : GNAT.Sockets.Socket_Type;
         Content_Type : String;
         Payload         : Stream_Element_Array)
      is
         Header : constant Stream_Element_Array :=
           To_Stream
             ("HTTP/1.1 200 OK" & CR & LF
              & "Content-Type: " & Content_Type & CR & LF
              & "Content-Length: "
              & Ada.Strings.Fixed.Trim
                  (Integer'Image (Integer (Payload'Length)), Ada.Strings.Left)
              & CR & LF
              & "Connection: close" & CR & LF
              & CR & LF);
         Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Client, Header, Last);
         if Payload'Length > 0 then
            GNAT.Sockets.Send_Socket (Client, Payload, Last);
         end if;
      end Send_Response;

      procedure Serve_Response
        (Content_Type : String;
         Payload         : Stream_Element_Array)
      is
         Client      : GNAT.Sockets.Socket_Type;
         Peer        : GNAT.Sockets.Sock_Addr_Type;
         Request     : Stream_Element_Array (1 .. 8192);
         Request_End : Stream_Element_Offset;
      begin
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         Send_Response (Client, Content_Type, Payload);
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

      procedure Serve_Drop is
         Client      : GNAT.Sockets.Socket_Type;
         Peer        : GNAT.Sockets.Sock_Addr_Type;
         Request     : Stream_Element_Array (1 .. 8192);
         Request_End : Stream_Element_Offset;
      begin
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
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
      end Serve_Drop;
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

      Serve_Response
        (Content_Type => "application/x-git-receive-pack-advertisement",
         Payload         => Receive_Pack_Discovery_Stream);

      if Mode = Drop_Before_Report_Status then
         Serve_Drop;
      else
         Serve_Response
           (Content_Type => "application/x-git-receive-pack-result",
            Payload         => Receive_Pack_Failure_Stream (Mode));
      end if;

      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others =>
               null;
         end;
   end Receive_Pack_Failure_Server;

   function Server_Hook_Path
     (Remote_Root : String;
      Name        : String) return String
   is
   begin
      return
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Remote_Root, ".git"), "hooks"),
           Name);
   end Server_Hook_Path;

   function Server_Hook_Output_Path (Remote_Root : String) return String is
   begin
      return Version.Test_Support.Join (Remote_Root, "server-hook-ran.txt");
   end Server_Hook_Output_Path;

   function Server_Hook_Content
     (Remote_Root : String;
      Name        : String) return String
   is
   begin
      return
        "#!/bin/sh" & LF
        & "echo " & Name & " >> " & Server_Hook_Output_Path (Remote_Root) & LF
        & "exit 42" & LF;
   end Server_Hook_Content;

   procedure Seed_Server_Side_Hooks (Remote_Root : String) is
      procedure Seed (Name : String) is
      begin
         Version.Test_Support.Write_Text_File
           (Server_Hook_Path (Remote_Root, Name),
            Server_Hook_Content (Remote_Root, Name));
         Version.Git_Fixtures.Run
           (Remote_Root, "chmod +x .git/hooks/" & Name);
      end Seed;
   begin
      Seed ("pre-receive");
      Seed ("update");
      Seed ("post-receive");
   end Seed_Server_Side_Hooks;

   function Server_Side_Hook_Snapshot (Remote_Root : String) return String is
   begin
      return
        Version.Files.Read_Binary_File
          (Server_Hook_Path (Remote_Root, "pre-receive"))
        & Version.Files.Read_Binary_File
          (Server_Hook_Path (Remote_Root, "update"))
        & Version.Files.Read_Binary_File
          (Server_Hook_Path (Remote_Root, "post-receive"));
   end Server_Side_Hook_Snapshot;

   procedure Assert_Server_Side_Hooks_Preserved
     (Remote_Root : String;
      Expected    : String) is
   begin
      Assert
        (Server_Side_Hook_Snapshot (Remote_Root) = Expected,
         "local push must preserve remote server-side hook bytes");
      Assert
        (not Ada.Directories.Exists (Server_Hook_Output_Path (Remote_Root)),
         "local push must not execute remote server-side hooks");
   end Assert_Server_Side_Hooks_Preserved;

   procedure Assert_Failed_Push_Preserved_State
     (Repo_Path       : String;
      Work_File       : String;
      Expected_Work    : String;
      Tracking_Ref     : String;
      Expected_Tracking : String;
      Temp_Pack       : String;
      Temp_Idx        : String;
      Label           : String)
   is
   begin
      Assert
        (Ada.Directories.Exists (Tracking_Ref),
         Label & ": existing remote-tracking ref must remain present");
      Assert
        (Version.Test_Support.Read_Text_File (Tracking_Ref) = Expected_Tracking,
         Label & ": failed push must not rewrite remote-tracking ref");
      Assert
        (not Ada.Directories.Exists (Temp_Pack),
         Label & ": failed push must remove temporary pack");
      Assert
        (not Ada.Directories.Exists (Temp_Idx),
         Label & ": failed push must remove temporary index");
      Assert
        (Ada.Directories.Exists (Repo_Path),
         Label & ": repository must remain present after failed push");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = Expected_Work,
         Label & ": failed push must not mutate working-tree files");
   end Assert_Failed_Push_Preserved_State;

   procedure Push_Http_Failure_Preserves_Existing_Tracking
     (T     : in out AUnit.Test_Cases.Test_Case'Class;
      Mode  : Push_Failure_Mode;
      Label : String)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String :=
        Version.Test_Support.Join (Root, Label);
      Work_File : constant String := Version.Test_Support.Join (Repo_Path, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Server : Receive_Pack_Failure_Server (Mode);
      Port   : GNAT.Sockets.Port_Type;
      Raised : Boolean := False;
      Remote_Tracking_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "main");
      Temp_Pack : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.pack");
      Temp_Idx : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.idx");
      Existing_Tracking : constant String :=
        "1111111111111111111111111111111111111111";
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git init");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);

      Ada.Directories.Set_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git add a.txt");
      Version.Write.Save ("one");

      Ada.Directories.Create_Path
        (Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join
                 (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
               "remotes"),
            "origin"));
      Version.Test_Support.Write_Text_File
        (Remote_Tracking_Ref,
         Existing_Tracking);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "http://127.0.0.1:"
                 & Ada.Strings.Fixed.Trim
                     (Integer'Image (Integer (Port)), Ada.Strings.Left)
                 & "/repo.git");

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, Label & ": push failure mode must fail push");
      Assert_Failed_Push_Preserved_State
        (Repo_Path          => Repo_Path,
         Work_File          => Work_File,
         Expected_Work       => "one",
         Tracking_Ref        => Remote_Tracking_Ref,
         Expected_Tracking   => Existing_Tracking,
         Temp_Pack          => Temp_Pack,
         Temp_Idx           => Temp_Idx,
         Label              => Label);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Http_Failure_Preserves_Existing_Tracking;

   procedure Push_Http_Network_Drop_Does_Not_Update_Tracking
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Push_Http_Failure_Preserves_Existing_Tracking
        (T     => T,
         Mode  => Drop_Before_Report_Status,
         Label => "http-push-network-drop");
   end Push_Http_Network_Drop_Does_Not_Update_Tracking;

   procedure Push_Http_Unpack_Error_Does_Not_Update_Tracking
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Push_Http_Failure_Preserves_Existing_Tracking
        (T     => T,
         Mode  => Remote_Unpack_Error,
         Label => "http-push-unpack-error");
   end Push_Http_Unpack_Error_Does_Not_Update_Tracking;

   procedure Push_Http_Non_Fast_Forward_Does_Not_Update_Tracking
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Push_Http_Failure_Preserves_Existing_Tracking
        (T     => T,
         Mode  => Non_Fast_Forward_Report_Status,
         Label => "http-push-non-fast-forward");
   end Push_Http_Non_Fast_Forward_Does_Not_Update_Tracking;

   procedure Push_Http_Partial_Report_Status_Does_Not_Update_Tracking
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
   begin
      Push_Http_Failure_Preserves_Existing_Tracking
        (T     => T,
         Mode  => Partial_Report_Status,
         Label => "http-push-partial-report-status");
   end Push_Http_Partial_Report_Status_Does_Not_Update_Tracking;

   procedure Push_Http_Tags_No_Clobber_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String :=
        Version.Test_Support.Join (Root, "tagclobber");
      Work_File : constant String :=
        Version.Test_Support.Join (Repo_Path, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Server  : Receive_Pack_Tag_Conflict_Server;
      Port    : GNAT.Sockets.Port_Type;
      Raised  : Boolean := False;
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git init");
      Version.Git_Fixtures.Run
        (Repo_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);

      Ada.Directories.Set_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git add a.txt");
      Version.Write.Save ("one");
      Version.Git_Fixtures.Run (Repo_Path, "git tag v1");

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "http://127.0.0.1:"
                 & Ada.Strings.Fixed.Trim
                     (Integer'Image (Integer (Port)), Ada.Strings.Left)
                 & "/repo.git");

      begin
         Version.Push.Push_Tags (Remote_Name => "origin");
      exception
         when others =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Raised,
         "HTTP push --tags must refuse to overwrite a differing remote tag");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Http_Tags_No_Clobber_Rejected;

   function Loose_Object_Path
     (Git_Dir : String;
      Id      : String) return String
   is
   begin
      return
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Git_Dir, "objects"),
              Id (Id'First .. Id'First + 1)),
           Id (Id'First + 2 .. Id'Last));
   end Loose_Object_Path;

   procedure Push_Local_Ref_Lock_Rolls_Back_Copied_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-ref-lock-rollback");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-ref-lock-rollback");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Source_Git : constant String := Version.Test_Support.Join (Source, ".git");
      Remote_Lock : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source_Git, "refs"), "heads"),
           "main.lock");
      Remote_Before : String (1 .. 40);
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Remote_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      Version.Test_Support.Write_Text_File (Remote_Lock, "locked" & LF);

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Source);
      Assert (Raised, "remote branch lock must fail local push");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open) = Remote_Before,
         "remote branch lock failure must preserve remote branch");
      Assert
        (Ada.Directories.Exists (Remote_Lock),
         "remote branch lock failure must preserve operator lock");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Source_Git, Clone_Commit)),
         "remote branch lock failure must roll back copied commit object");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Ref_Lock_Rolls_Back_Copied_Objects;

   procedure Push_Local_Packed_Branch_Lock_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-packed-branch-rollback");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-packed-branch-rollback");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Source_Git : constant String := Version.Test_Support.Join (Source, ".git");
      Packed_Refs_Path : constant String :=
        Version.Test_Support.Join (Source_Git, "packed-refs");
      Remote_Branch : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source_Git, "refs"), "heads"),
           "main");
      Remote_Lock : constant String := Remote_Branch & ".lock";
      Packed_Before : Ada.Strings.Unbounded.Unbounded_String;
      Remote_Before : String (1 .. 40);
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Remote_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");
      Packed_Before :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (Packed_Refs_Path));
      Ada.Directories.Set_Directory (Old_Dir);

      Assert
        (not Ada.Directories.Exists (Remote_Branch),
         "packed branch fixture must remove loose remote branch");

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      Version.Test_Support.Write_Text_File (Remote_Lock, "locked" & LF);

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Source);
      Assert (Raised, "remote packed branch lock must fail local push");
      Assert
        (Version.Files.Read_Binary_File (Packed_Refs_Path)
         = Ada.Strings.Unbounded.To_String (Packed_Before),
         "remote packed branch lock failure must preserve packed-refs");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open) = Remote_Before,
         "remote packed branch lock failure must preserve branch value");
      Assert
        (not Ada.Directories.Exists (Remote_Branch),
         "remote packed branch lock failure must not create loose branch");
      Assert
        (Ada.Directories.Exists (Remote_Lock),
         "remote packed branch lock failure must preserve operator lock");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Source_Git, Clone_Commit)),
         "remote packed branch lock failure must roll back copied commit object");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Packed_Branch_Lock_Rolls_Back;

   procedure Push_Local_Tag_Transaction_Failure_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-tag-tx-rollback");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-tag-tx-rollback");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Source_Git : constant String := Version.Test_Support.Join (Source, ".git");
      Release_Tag_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source_Git, "refs"), "tags"),
           "release");
      First_Remote_Tag : constant String :=
        Version.Test_Support.Join (Release_Tag_Dir, "a");
      Second_Remote_Tag : constant String :=
        Version.Test_Support.Join (Release_Tag_Dir, "b");
      Second_Remote_Lock : constant String := Second_Remote_Tag & ".lock";
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Tags.Create_Tag ("release/a");
      Version.Tags.Create_Tag ("release/b");

      Ada.Directories.Create_Path (Release_Tag_Dir);
      Version.Test_Support.Write_Text_File (Second_Remote_Lock, "locked" & LF);

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "remote tag lock must fail local tag push");
      Assert
        (not Ada.Directories.Exists (First_Remote_Tag),
         "failed local tag transaction must not leave earlier tag update");
      Assert
        (not Ada.Directories.Exists (Second_Remote_Tag),
         "failed local tag transaction must not leave later tag update");
      Assert
        (Ada.Directories.Exists (Second_Remote_Lock),
         "failed local tag transaction must preserve operator lock");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Source_Git, Clone_Commit)),
         "failed local tag transaction must roll back copied commit object");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Tag_Transaction_Failure_Rolls_Back;

   procedure Push_Local_Tag_Transaction_Preserves_Packed_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-packed-tag-tx-rollback");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-packed-tag-tx-rollback");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Source_Git : constant String := Version.Test_Support.Join (Source, ".git");
      Packed_Refs_Path : constant String :=
        Version.Test_Support.Join (Source_Git, "packed-refs");
      Release_Tag_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source_Git, "refs"), "tags"),
           "release");
      Existing_Loose_Tag : constant String :=
        Version.Test_Support.Join (Release_Tag_Dir, "existing");
      First_Remote_Tag : constant String :=
        Version.Test_Support.Join (Release_Tag_Dir, "a");
      Second_Remote_Tag : constant String :=
        Version.Test_Support.Join (Release_Tag_Dir, "b");
      Second_Remote_Lock : constant String := Second_Remote_Tag & ".lock";
      Packed_Before : Ada.Strings.Unbounded.Unbounded_String;
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Version.Tags.Create_Tag ("release/existing");
      Version.Git_Fixtures.Run (Source, "git pack-refs --all --prune");
      Packed_Before :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Version.Files.Read_Binary_File (Packed_Refs_Path));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Tags.Create_Tag ("release/a");
      Version.Tags.Create_Tag ("release/b");

      Ada.Directories.Create_Path (Release_Tag_Dir);
      Version.Test_Support.Write_Text_File (Second_Remote_Lock, "locked" & LF);

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "remote packed tag lock must fail local tag push");
      Assert
        (Version.Files.Read_Binary_File (Packed_Refs_Path)
         = Ada.Strings.Unbounded.To_String (Packed_Before),
         "failed local tag transaction must preserve remote packed-refs");
      Assert
        (not Ada.Directories.Exists (Existing_Loose_Tag),
         "failed local tag transaction must not loosen existing packed tag");
      Assert
        (not Ada.Directories.Exists (First_Remote_Tag),
         "failed packed remote tag transaction must not leave earlier loose tag");
      Assert
        (not Ada.Directories.Exists (Second_Remote_Tag),
         "failed packed remote tag transaction must not leave later loose tag");
      Assert
        (Ada.Directories.Exists (Second_Remote_Lock),
         "failed packed remote tag transaction must preserve operator lock");
      Assert
        (not Ada.Directories.Exists (Loose_Object_Path (Source_Git, Clone_Commit)),
         "failed packed remote tag transaction must roll back copied commit object");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Tag_Transaction_Preserves_Packed_Remote;

   procedure Push_Local_Non_Fast_Forward_Does_Not_Update_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-local-nff");
      Clone_Path : constant String := Version.Test_Support.Join (Root, "clone-local-nff");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Raised : Boolean := False;
      Remote_Before : String (1 .. 40);
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "remote advance" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("remote advance");
      Remote_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "local divergent" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("local divergent");

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Source);
      Assert (Raised, "local non-fast-forward push must fail");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open) = Remote_Before,
         "failed local non-fast-forward push must not update remote branch");
      Assert
        (Version.Test_Support.Read_Text_File (Source_File) = "remote advance",
         "failed local non-fast-forward push must not mutate remote worktree");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Non_Fast_Forward_Does_Not_Update_Remote;

   procedure Push_Local_Force_Updates_Non_Fast_Forward
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-force");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-force");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String :=
        Version.Test_Support.Join (Clone_Path, "a.txt");
      Raised : Boolean := False;
      Remote_Before : String (1 .. 40);
      Local_Divergent : String (1 .. 40);
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run
        (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "remote advance" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("remote advance");
      Remote_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "local divergent" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("local divergent");
      Local_Divergent :=
        Version.Refs.Current_Commit_Id (Version.Repository.Open);

      --  Without --force the non-fast-forward update is rejected.
      begin
         Version.Push.Push (Remote_Name => "origin", Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;
      Assert (Raised, "non-fast-forward push must fail without --force");

      Ada.Directories.Set_Directory (Source);
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Remote_Before,
         "rejected push must not update remote branch");

      --  With --force the divergent commit replaces the remote branch.
      Ada.Directories.Set_Directory (Clone_Path);
      Version.Push.Push
        (Remote_Name => "origin", Branch_Name => "main", Force => True);

      Ada.Directories.Set_Directory (Source);
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open)
         = Local_Divergent,
         "forced push must update remote branch to the divergent commit");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Force_Updates_Non_Fast_Forward;

   procedure Push_Local_Delete_Removes_Remote_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String :=
        Version.Test_Support.Join (Root, "remote-delete.git");
      Work : constant String := Version.Test_Support.Join (Root, "work-delete");
      Work_File : constant String := Version.Test_Support.Join (Work, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Remote);
      Version.Git_Fixtures.Run (Remote, "git init --bare");

      Ada.Directories.Create_Directory (Work);
      Version.Git_Fixtures.Run (Work, "git init");
      Version.Git_Fixtures.Run (Work, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work, "git config user.name Test");

      Ada.Directories.Set_Directory (Work);
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Version.Write.Save ("one");
      Version.Remotes.Add_Remote (Name => "origin", Url => Remote);
      Version.Push.Push (Remote_Name => "origin", Branch_Name => "main");

      --  Create a second branch on the remote, then delete it.
      Version.Git_Fixtures.Run (Remote, "git branch topic main");
      Version.Push.Delete_Ref
        (Remote_Name => "origin", Ref_Name => "refs/heads/topic");

      --  Deleting a non-existent ref must fail explicitly.
      begin
         Version.Push.Delete_Ref
           (Remote_Name => "origin", Ref_Name => "refs/heads/absent");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

      Assert
        (not Version.Refs.Ref_Exists
               (Version.Repository.Open_Git_Dir (Remote), "refs/heads/topic"),
         "deleted remote branch must be gone");
      Assert
        (Version.Refs.Ref_Exists
           (Version.Repository.Open_Git_Dir (Remote), "refs/heads/main"),
         "unrelated remote branch must survive a delete");
      Assert (Raised, "deleting an absent ref must fail explicitly");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Delete_Removes_Remote_Ref;

   procedure Push_Local_Refspec_Updates_Named_Ref
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String :=
        Version.Test_Support.Join (Root, "remote-refspec.git");
      Work : constant String := Version.Test_Support.Join (Root, "work-refspec");
      Work_File : constant String := Version.Test_Support.Join (Work, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Local_Id : String (1 .. 40);
   begin
      Ada.Directories.Create_Directory (Remote);
      Version.Git_Fixtures.Run (Remote, "git init --bare");

      Ada.Directories.Create_Directory (Work);
      Version.Git_Fixtures.Run (Work, "git init");
      Version.Git_Fixtures.Run (Work, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work, "git config user.name Test");

      Ada.Directories.Set_Directory (Work);
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Version.Write.Save ("one");
      Local_Id := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Remotes.Add_Remote (Name => "origin", Url => Remote);

      --  Push the local branch to a differently-named remote branch and to a
      --  tag ref via refspecs.
      Version.Push.Push_Refspec
        (Remote_Name => "origin",
         Source      => "main",
         Dest_Ref    => "refs/heads/release");
      Version.Push.Push_Refspec
        (Remote_Name => "origin",
         Source      => "main",
         Dest_Ref    => "refs/tags/v1");

      Ada.Directories.Set_Directory (Old_Dir);

      Assert
        (To_String (Version.Refs.Resolve_Ref
           (Version.Repository.Open_Git_Dir (Remote), "refs/heads/release"))
         = Local_Id,
         "refspec push must update the named remote branch to the source");
      Assert
        (To_String (Version.Refs.Resolve_Ref
           (Version.Repository.Open_Git_Dir (Remote), "refs/tags/v1"))
         = Local_Id,
         "refspec push must create the named remote tag");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Refspec_Updates_Named_Ref;

   procedure Push_Local_Tags_Force_Overwrites_Differing_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String :=
        Version.Test_Support.Join (Root, "remote-tagforce.git");
      Work : constant String := Version.Test_Support.Join (Root, "work-tagforce");
      Work_File : constant String := Version.Test_Support.Join (Work, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      First_Id  : String (1 .. 40);
      Second_Id : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Remote);
      Version.Git_Fixtures.Run (Remote, "git init --bare");

      Ada.Directories.Create_Directory (Work);
      Version.Git_Fixtures.Run (Work, "git init");
      Version.Git_Fixtures.Run (Work, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work, "git config user.name Test");

      Ada.Directories.Set_Directory (Work);
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Version.Write.Save ("one");
      First_Id := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Git_Fixtures.Run (Work, "git tag v1");
      Version.Remotes.Add_Remote (Name => "origin", Url => Remote);
      Version.Push.Push_Tags (Remote_Name => "origin");

      --  Move the tag to a new commit locally.
      Version.Test_Support.Write_Text_File (Work_File, "two" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Version.Write.Save ("two");
      Second_Id := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Git_Fixtures.Run (Work, "git tag -f v1");

      --  Without force, pushing the moved tag is rejected and the remote keeps
      --  the original commit.
      begin
         Version.Push.Push_Tags (Remote_Name => "origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "push --tags must refuse to move an existing remote tag");
      Assert
        (To_String (Version.Refs.Resolve_Ref
           (Version.Repository.Open_Git_Dir (Remote), "refs/tags/v1"))
         = First_Id,
         "rejected tag push must leave the remote tag unchanged");

      --  With force, the remote tag is moved to the new commit.
      Version.Push.Push_Tags (Remote_Name => "origin", Force => True);

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (To_String (Version.Refs.Resolve_Ref
           (Version.Repository.Open_Git_Dir (Remote), "refs/tags/v1"))
         = Second_Id,
         "forced tag push must move the remote tag to the new commit");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Tags_Force_Overwrites_Differing_Tag;

   procedure Push_Default_Uses_Configured_Refspec
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String :=
        Version.Test_Support.Join (Root, "remote-default.git");
      Work : constant String := Version.Test_Support.Join (Root, "work-default");
      Work_File : constant String := Version.Test_Support.Join (Work, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Local_Id : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Remote);
      Version.Git_Fixtures.Run (Remote, "git init --bare");

      Ada.Directories.Create_Directory (Work);
      Version.Git_Fixtures.Run (Work, "git init");
      Version.Git_Fixtures.Run (Work, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Work, "git config user.name Test");

      Ada.Directories.Set_Directory (Work);
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);
      Version.Git_Fixtures.Run (Work, "git add a.txt");
      Version.Write.Save ("one");
      Local_Id := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Remotes.Add_Remote (Name => "origin", Url => Remote);

      --  With no remote.origin.push configured, push with no refspec fails.
      begin
         Version.Push.Push_Default (Remote_Name => "origin");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Assert (Raised, "push with no refspec and no remote.push must fail");

      --  Configure remote.origin.push and push using it.
      Version.Git_Fixtures.Run
        (Work, "git config remote.origin.push refs/heads/main:refs/heads/release");
      Version.Push.Push_Default (Remote_Name => "origin");

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (To_String (Version.Refs.Resolve_Ref
           (Version.Repository.Open_Git_Dir (Remote), "refs/heads/release"))
         = Local_Id,
         "push with no refspec must apply the configured remote.push refspec");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Default_Uses_Configured_Refspec;

   procedure Push_Local_Malformed_Remote_Branch_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-malformed-branch");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-malformed-branch");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Remote_Branch : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Source, ".git"), "refs"),
              "heads"),
           "main");
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);
      Version.Test_Support.Write_Text_File (Remote_Branch, "not-an-object" & LF);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Push.Invalid_Remote_Branch_Commit_Id_Diagnostic,
               "wrong malformed remote branch diagnostic: "
               & Ada.Exceptions.Exception_Message (E));

         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed remote branch must fail local push");

      declare
         Remote_New_Object : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "objects"),
                 Clone_Commit (Clone_Commit'First .. Clone_Commit'First + 1)),
              Clone_Commit (Clone_Commit'First + 2 .. Clone_Commit'Last));
      begin
         Assert
           (not Ada.Directories.Exists (Remote_New_Object),
            "malformed remote branch must not copy new objects to remote");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Malformed_Remote_Branch_Does_Not_Copy_Objects;

   procedure Push_Local_Symlink_Remote_Branch_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-symlink-branch");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-symlink-branch");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Heads_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join (Source, ".git"), "refs"),
           "heads");
      Remote_Branch : constant String :=
        Version.Test_Support.Join (Heads_Dir, "main");
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Heads_Dir, "real-main"),
         "1111111111111111111111111111111111111111" & LF);
      Version.Git_Fixtures.Run (Heads_Dir, "rm main && ln -s real-main main");

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid remote ref entry: " & Remote_Branch,
               "wrong symlink remote branch diagnostic: "
               & Ada.Exceptions.Exception_Message (E));

         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "symlink remote branch must fail local push");

      declare
         Remote_New_Object : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "objects"),
                 Clone_Commit (Clone_Commit'First .. Clone_Commit'First + 1)),
              Clone_Commit (Clone_Commit'First + 2 .. Clone_Commit'Last));
      begin
         Assert
           (not Ada.Directories.Exists (Remote_New_Object),
            "symlink remote branch must not copy new objects to remote");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Symlink_Remote_Branch_Does_Not_Copy_Objects;

   procedure Push_Local_Tag_Rejection_Does_Not_Update_Remote_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String := Version.Test_Support.Join (Root, "source-local-tag-reject");
      Clone_Path : constant String := Version.Test_Support.Join (Root, "clone-local-tag-reject");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Raised : Boolean := False;
      Remote_Tag_Before : String (1 .. 40);
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "source one" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source one");
      Version.Tags.Create_Tag ("release/v1.0");
      Remote_Tag_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Version.Tags.Delete_Tag ("release/v1.0");
      Version.Tags.Create_Tag ("release/v1.0");

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Source);
      Assert (Raised, "conflicting tag push must fail");
      Version.Git_Fixtures.Run
        (Source,
         "test """"$(git rev-parse release/v1.0)"""" = """"" & Remote_Tag_Before & """""");

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Tag_Rejection_Does_Not_Update_Remote_Tag;

   procedure Push_Local_Tag_Rejection_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-tag-object-reject");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-tag-object-reject");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "source one" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source one");
      Version.Tags.Create_Tag ("release/v1.0");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Tags.Delete_Tag ("release/v1.0");
      Version.Tags.Create_Tag ("release/v1.0");

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "conflicting tag push must fail");

      declare
         Remote_New_Object : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "objects"),
                 Clone_Commit (Clone_Commit'First .. Clone_Commit'First + 1)),
              Clone_Commit (Clone_Commit'First + 2 .. Clone_Commit'Last));
      begin
         Assert
           (not Ada.Directories.Exists (Remote_New_Object),
            "failed local tag push must not copy new objects to remote");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Tag_Rejection_Does_Not_Copy_Objects;

   procedure Push_Local_Malformed_Remote_Tag_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-malformed-tag");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-malformed-tag");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Remote_Tag : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "refs"),
                 "tags"),
              "release"),
           "v1.0");
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "source one" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source one");
      Version.Tags.Create_Tag ("release/v1.0");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);
      Version.Test_Support.Write_Text_File (Remote_Tag, "not-an-object" & LF);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Tags.Delete_Tag ("release/v1.0");
      Version.Tags.Create_Tag ("release/v1.0");

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Push.Invalid_Remote_Tag_Object_Id_Diagnostic,
               "wrong malformed remote tag diagnostic: "
               & Ada.Exceptions.Exception_Message (E));

         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "malformed remote tag must fail local push");

      declare
         Remote_New_Object : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "objects"),
                 Clone_Commit (Clone_Commit'First .. Clone_Commit'First + 1)),
              Clone_Commit (Clone_Commit'First + 2 .. Clone_Commit'Last));
      begin
         Assert
           (not Ada.Directories.Exists (Remote_New_Object),
            "malformed remote tag must not copy new objects to remote");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Malformed_Remote_Tag_Does_Not_Copy_Objects;

   procedure Push_Local_Symlink_Remote_Tag_Does_Not_Copy_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-local-symlink-tag");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-local-symlink-tag");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Release_Dir : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Source, ".git"), "refs"),
              "tags"),
           "release");
      Remote_Tag : constant String := Version.Test_Support.Join (Release_Dir, "v1.0");
      Clone_Commit : String (1 .. 40);
      Raised : Boolean := False;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform then
         return;
      end if;

      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "source one" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source one");
      Version.Tags.Create_Tag ("release/v1.0");
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Release_Dir, "real-tag"),
         "1111111111111111111111111111111111111111" & LF);
      Version.Git_Fixtures.Run (Release_Dir, "rm v1.0 && ln -s real-tag v1.0");

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "clone two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");
      Clone_Commit := Version.Refs.Current_Commit_Id (Version.Repository.Open);
      Version.Tags.Delete_Tag ("release/v1.0");
      Version.Tags.Create_Tag ("release/v1.0");

      begin
         Version.Push.Push_Tags ("origin");
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = "invalid remote ref entry: " & Remote_Tag,
               "wrong symlink remote tag diagnostic: "
               & Ada.Exceptions.Exception_Message (E));

         when Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "symlink remote tag must fail local push");

      declare
         Remote_New_Object : constant String :=
           Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Source, ".git"), "objects"),
                 Clone_Commit (Clone_Commit'First .. Clone_Commit'First + 1)),
              Clone_Commit (Clone_Commit'First + 2 .. Clone_Commit'Last));
      begin
         Assert
           (not Ada.Directories.Exists (Remote_New_Object),
            "symlink remote tag must not copy new objects to remote");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Symlink_Remote_Tag_Does_Not_Copy_Objects;

   procedure Push_Local_Branch_Fast_Forward
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
        Version.Test_Support.Join (Root, "source");

      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone");

      Old_Dir : constant String :=
        Ada.Directories.Current_Directory;

      Source_File : constant String :=
        Version.Test_Support.Join (Source, "a.txt");

      Clone_File : constant String :=
        Version.Test_Support.Join (Clone_Path, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
        (Source_File,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("one");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
        (Source => Source,
         Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);

      Version.Test_Support.Write_Text_File
        (Clone_File,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("two");

      Version.Push.Push
        (Remote_Name => "origin",
         Branch_Name => "main");

      Ada.Directories.Set_Directory (Source);

      Version.Git_Fixtures.Run
        (Source,
         "test ""$(git log --format=%s -1)"" = ""two""");

      Version.Git_Fixtures.Run
        (Source,
         "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Branch_Fast_Forward;

   procedure Push_Local_Preserves_Server_Side_Hooks_On_Success
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-server-hooks-success");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-server-hooks-success");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Hook_Snapshot : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "one" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("one");
      Seed_Server_Side_Hooks (Source);
      Hook_Snapshot :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Server_Side_Hook_Snapshot (Source));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "two" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("two");
      Version.Push.Push
        (Remote_Name => "origin",
         Branch_Name => "main");

      Ada.Directories.Set_Directory (Source);
      Version.Git_Fixtures.Run
        (Source,
         "test ""$(git log --format=%s -1)"" = ""two""");
      Assert_Server_Side_Hooks_Preserved
        (Source, Ada.Strings.Unbounded.To_String (Hook_Snapshot));

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Preserves_Server_Side_Hooks_On_Success;

   procedure Push_Local_Preserves_Server_Side_Hooks_On_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Source : constant String :=
        Version.Test_Support.Join (Root, "source-server-hooks-failure");
      Clone_Path : constant String :=
        Version.Test_Support.Join (Root, "clone-server-hooks-failure");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Source_File : constant String := Version.Test_Support.Join (Source, "a.txt");
      Clone_File : constant String := Version.Test_Support.Join (Clone_Path, "a.txt");
      Hook_Snapshot : Ada.Strings.Unbounded.Unbounded_String;
      Remote_Before : String (1 .. 40);
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);
      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "base" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");
      Seed_Server_Side_Hooks (Source);
      Hook_Snapshot :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Server_Side_Hook_Snapshot (Source));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone (Source => Source, Target => Clone_Path);

      Ada.Directories.Set_Directory (Source);
      Version.Test_Support.Write_Text_File (Source_File, "remote advance" & LF);
      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("remote advance");
      Remote_Before := Version.Refs.Current_Commit_Id (Version.Repository.Open);

      Ada.Directories.Set_Directory (Clone_Path);
      Version.Test_Support.Write_Text_File (Clone_File, "local divergent" & LF);
      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("local divergent");

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Source);
      Assert (Raised, "local non-fast-forward push must fail");
      Assert
        (Version.Refs.Current_Commit_Id (Version.Repository.Open) = Remote_Before,
         "failed local push must not update remote branch");
      Assert_Server_Side_Hooks_Preserved
        (Source, Ada.Strings.Unbounded.To_String (Hook_Snapshot));

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Local_Preserves_Server_Side_Hooks_On_Failure;

   procedure Push_Rejects_Non_Fast_Forward
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
      Version.Test_Support.Join (Root, "source");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "clone");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Source_File : constant String :=
      Version.Test_Support.Join (Source, "a.txt");

      Clone_File : constant String :=
      Version.Test_Support.Join (Clone_Path, "a.txt");

      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "base" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("base");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Source,
         Target => Clone_Path);

      --  Source advances independently.
      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "source advance" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source advance");

      --  Clone advances from the old base, so push must be rejected.
      Ada.Directories.Set_Directory (Clone_Path);

      Version.Test_Support.Write_Text_File
      (Clone_File,
         "clone advance" & Character'Val (10));

      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone advance");

      begin
         Version.Push.Push
         (Remote_Name => "origin",
            Branch_Name => "main");

      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
      (Raised,
         "push must reject non-fast-forward remote update");

      Ada.Directories.Set_Directory (Source);

      Version.Git_Fixtures.Run
      (Source,
         "test ""$(git log --format=%s -1)"" = ""source advance""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Rejects_Non_Fast_Forward;





   procedure Push_Tags_To_Remote
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
      Version.Test_Support.Join (Root, "source-tags");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-tags");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Source_File : constant String :=
      Version.Test_Support.Join (Source, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "tags" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("tags");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Source,
         Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);

      Version.Tags.Create_Tag ("release/v1.0");
      Version.Tags.Create_Annotated_Tag ("release/v1.0-annotated", "annotated release");
      Version.Git_Fixtures.Run (Clone_Path, "git pack-refs --all --prune");

      Version.Push.Push_Tags ("origin");

      Ada.Directories.Set_Directory (Source);

      Version.Git_Fixtures.Run
      (Source,
         "test ""$(git rev-parse release/v1.0)"" = ""$(git rev-parse HEAD)""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Tags_To_Remote;

   procedure Push_Tags_Rejects_Conflicting_Remote_Tag
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
      Version.Test_Support.Join (Root, "source-conflicting-tags");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-conflicting-tags");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Source_File : constant String :=
      Version.Test_Support.Join (Source, "a.txt");

      Clone_File : constant String :=
      Version.Test_Support.Join (Clone_Path, "a.txt");

      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "source one" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("source one");

      Version.Tags.Create_Tag ("release/v1.0");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Source,
         Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);

      Version.Test_Support.Write_Text_File
      (Clone_File,
         "clone two" & Character'Val (10));

      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("clone two");

      Version.Tags.Delete_Tag ("release/v1.0");
      Version.Tags.Create_Tag ("release/v1.0");

      begin
         Version.Push.Push_Tags ("origin");

      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert
      (Raised,
         "push --tags must reject conflicting remote tag update");

      Ada.Directories.Set_Directory (Source);

      Version.Git_Fixtures.Run
      (Source,
         "test ""$(git log --format=%s -1 release/v1.0)"" = ""source one""");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Tags_Rejects_Conflicting_Remote_Tag;

   procedure Push_File_Url_Branch_Fast_Forward
   (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
      Version.Temp_Fixture.Root
         (Version.Temp_Fixture.Test_Case (T));

      Source : constant String :=
      Version.Test_Support.Join (Root, "source-file-url");

      Clone_Path : constant String :=
      Version.Test_Support.Join (Root, "clone-file-url");

      Old_Dir : constant String :=
      Ada.Directories.Current_Directory;

      Source_File : constant String :=
      Version.Test_Support.Join (Source, "a.txt");

      Clone_File : constant String :=
      Version.Test_Support.Join (Clone_Path, "a.txt");
   begin
      Ada.Directories.Create_Directory (Source);

      Version.Git_Fixtures.Run (Source, "git init");
      Version.Git_Fixtures.Run (Source, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Source, "git config user.name Test");

      Ada.Directories.Set_Directory (Source);

      Version.Test_Support.Write_Text_File
      (Source_File,
         "one" & Character'Val (10));

      Version.Git_Fixtures.Run (Source, "git add a.txt");
      Version.Write.Save ("one");

      Ada.Directories.Set_Directory (Old_Dir);

      Version.Clone.Clone
      (Source => Source,
         Target => Clone_Path);

      Ada.Directories.Set_Directory (Clone_Path);

      Version.Remotes.Delete_Remote ("origin");
      Version.Remotes.Add_Remote
      (Name => "origin",
         Url  => "file://" & Source);

      Version.Test_Support.Write_Text_File
      (Clone_File,
         "two" & Character'Val (10));

      Version.Git_Fixtures.Run (Clone_Path, "git add a.txt");
      Version.Write.Save ("two");

      Version.Push.Push
      (Remote_Name => "origin",
         Branch_Name => "main");

      Ada.Directories.Set_Directory (Source);

      Version.Git_Fixtures.Run
      (Source,
         "test ""$(git log --format=%s -1)"" = ""two""");

      Version.Git_Fixtures.Run
      (Source,
         "git fsck --strict");

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_File_Url_Branch_Fast_Forward;

   procedure Push_Http_Report_Status_Rejection_Does_Not_Update_Tracking
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String := Version.Test_Support.Join (Root, "http-push-reject");
      Work_File : constant String := Version.Test_Support.Join (Repo_Path, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Server : Receive_Pack_Rejection_Server;
      Port   : GNAT.Sockets.Port_Type;
      Raised : Boolean := False;
      Remote_Tracking_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "main");
      Temp_Pack : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.pack");
      Temp_Idx : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.idx");
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git init");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);

      Ada.Directories.Set_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git add a.txt");
      Version.Write.Save ("one");

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "http://127.0.0.1:"
                 & Ada.Strings.Fixed.Trim
                     (Integer'Image (Integer (Port)), Ada.Strings.Left)
                 & "/repo.git");

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "HTTP receive-pack rejection must fail push");
      Assert
        (not Ada.Directories.Exists (Remote_Tracking_Ref),
         "failed HTTP push must not update remote-tracking refs");
      Assert
        (not Ada.Directories.Exists (Temp_Pack),
         "failed HTTP push must remove temporary pack");
      Assert
        (not Ada.Directories.Exists (Temp_Idx),
         "failed HTTP push must remove temporary index");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = "one",
         "failed HTTP push must not mutate working-tree files");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Http_Report_Status_Rejection_Does_Not_Update_Tracking;

   procedure Push_Http_Local_Pack_Failure_Cleans_Temp_Pack
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String :=
        Version.Test_Support.Join (Root, "http-push-local-pack-failure");
      Work_File : constant String := Version.Test_Support.Join (Repo_Path, "a.txt");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Server : Receive_Pack_Discovery_Only_Server;
      Port   : GNAT.Sockets.Port_Type;
      Raised : Boolean := False;
      Remote_Tracking_Ref : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
                 "remotes"),
              "origin"),
           "main");
      Temp_Pack : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.pack");
      Temp_Idx : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join
             (Version.Test_Support.Join
                (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
              "pack"),
           "version-push-temp.idx");
      Existing_Tracking : constant String :=
        "1111111111111111111111111111111111111111";
   begin
      Server.Ready (Port);

      Ada.Directories.Create_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git init");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Repo_Path, "git config user.name Test");
      Version.Test_Support.Write_Text_File (Work_File, "one" & LF);

      Ada.Directories.Set_Directory (Repo_Path);
      Version.Git_Fixtures.Run (Repo_Path, "git add a.txt");
      Version.Write.Save ("one");

      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Head_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));
         Head_Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Head_Id);
         Tree_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.Commit_Tree_Id (Head_Obj);
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo, Tree_Id);
         Blob_Id : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
         Other_Blob : Version.Objects.Object_Id_Storage;

         function Object_File_Path
           (Id : Version.Objects.Hex_Object_Id) return String
         is
            Text : constant String := To_String (Id);
         begin
            return
              Version.Test_Support.Join
                (Version.Test_Support.Join
                   (Version.Test_Support.Join
                      (Version.Test_Support.Join (Repo_Path, ".git"), "objects"),
                    Text (1 .. 2)),
                 Text (3 .. 40));
         end Object_File_Path;
      begin
         for Tree_Item of Entries loop
            if Tree_Item.Kind = Version.Objects.Tree_Blob then
               Blob_Id := Tree_Item.Id;
               exit;
            end if;
         end loop;

         Assert
           (Blob_Id /= Version.Objects.Object_Id_Storage'(Version.Objects.Zero_Object_Id),
            "push local-pack failure fixture should contain a reachable blob");

         Other_Blob := Version.Write.Write_Blob (Repo, "different push blob payload");
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Object_File_Path (Blob_Id)));
         Version.Files.Delete_File_If_Exists (Object_File_Path (Blob_Id));
         Version.Files.Write_Binary_File
           (Path    => Object_File_Path (Blob_Id),
            Content => Version.Files.Read_Binary_File
              (Object_File_Path (Other_Blob)));
      end;

      Ada.Directories.Create_Path
        (Version.Test_Support.Join
           (Version.Test_Support.Join
              (Version.Test_Support.Join
                 (Version.Test_Support.Join (Repo_Path, ".git"), "refs"),
               "remotes"),
            "origin"));
      Version.Test_Support.Write_Text_File
        (Remote_Tracking_Ref,
         Existing_Tracking);

      Version.Remotes.Add_Remote
        (Name => "origin",
         Url  => "http://127.0.0.1:"
                 & Ada.Strings.Fixed.Trim
                     (Integer'Image (Integer (Port)), Ada.Strings.Left)
                 & "/repo.git");

      begin
         Version.Push.Push
           (Remote_Name => "origin",
            Branch_Name => "main");
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Use_Error =>
            Raised := True;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "local pack generation failure must fail HTTP push");
      Assert
        (Version.Test_Support.Read_Text_File (Remote_Tracking_Ref) = Existing_Tracking,
         "local pack generation failure must preserve remote-tracking ref");
      Assert
        (not Ada.Directories.Exists (Temp_Pack),
         "local pack generation failure must remove temporary pack");
      Assert
        (not Ada.Directories.Exists (Temp_Idx),
         "local pack generation failure must remove temporary index");
      Assert
        (Version.Test_Support.Read_Text_File (Work_File) = "one",
         "local pack generation failure must not mutate working tree");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Push_Http_Local_Pack_Failure_Cleans_Temp_Pack;

   procedure Push_Internal_Detects_Changed_Remote_Branch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String := Version.Test_Support.Join (Root, "remote.git");
      Heads  : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Remote, "refs"), "heads");
      A_Id   : constant String := "1111111111111111111111111111111111111111";
      B_Id   : constant String := "2222222222222222222222222222222222222222";
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Path (Heads);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Heads, "main"),
         B_Id & Character'Val (10));

      begin
         Version.Push.Internal.Require_Remote_Branch_Unchanged
           (Remote_Git_Dir     => Remote,
            Branch_Name        => "main",
            Expected_Remote_Id => A_Id);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Push.Remote_Branch_Changed_During_Push_Diagnostic,
               "stale remote branch diagnostic must be stable");
      end;

      Assert (Raised, "changed remote branch must be rejected");
   end Push_Internal_Detects_Changed_Remote_Branch;

   procedure Push_Internal_Detects_Changed_Remote_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root
          (Version.Temp_Fixture.Test_Case (T));
      Remote : constant String := Version.Test_Support.Join (Root, "remote.git");
      Tags   : constant String :=
        Version.Test_Support.Join
          (Version.Test_Support.Join (Remote, "refs"), "tags");
      A_Id   : constant String := "1111111111111111111111111111111111111111";
      B_Id   : constant String := "2222222222222222222222222222222222222222";
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Path (Tags);
      Version.Test_Support.Write_Text_File
        (Version.Test_Support.Join (Tags, "v1.0"),
         B_Id & Character'Val (10));

      begin
         Version.Push.Internal.Require_Remote_Tag_Unchanged
           (Remote_Git_Dir     => Remote,
            Tag_Name           => "v1.0",
            Expected_Remote_Id => A_Id);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Push.Remote_Tag_Changed_During_Push_Diagnostic,
               "stale remote tag diagnostic must be stable");
      end;

      Assert (Raised, "changed remote tag must be rejected");
   end Push_Internal_Detects_Changed_Remote_Tag;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Push_Local_Branch_Fast_Forward'Access,
         "Push: local fast-forward branch");

      Register_Routine
        (T,
         Push_Internal_Detects_Changed_Remote_Branch'Access,
         "Push: detects changed remote branch");

      Register_Routine
        (T,
         Push_Internal_Detects_Changed_Remote_Tag'Access,
         "Push: detects changed remote tag");

      Register_Routine
        (T,
         Push_Local_Preserves_Server_Side_Hooks_On_Success'Access,
         "Push: local server-side hooks preserved on success");

      Register_Routine
        (T,
         Push_Local_Preserves_Server_Side_Hooks_On_Failure'Access,
         "Push: local server-side hooks preserved on failure");

      Register_Routine
        (T,
         Push_Local_Ref_Lock_Rolls_Back_Copied_Objects'Access,
         "Push: local ref lock rolls back copied objects");

      Register_Routine
        (T,
         Push_Local_Packed_Branch_Lock_Rolls_Back'Access,
         "Push: local packed branch lock rolls back refs and objects");

      Register_Routine
        (T,
         Push_Local_Tag_Transaction_Failure_Rolls_Back'Access,
         "Push: local tag transaction failure rolls back refs and objects");

      Register_Routine
        (T,
         Push_Local_Tag_Transaction_Preserves_Packed_Remote'Access,
         "Push: local tag transaction failure preserves packed remote refs");


      Register_Routine
         (T,
            Push_Rejects_Non_Fast_Forward'Access,
            "Push: reject non-fast-forward branch");


      Register_Routine
         (T,
            Push_Tags_To_Remote'Access,
            "Push: tags to remote");

      Register_Routine
         (T,
            Push_Tags_Rejects_Conflicting_Remote_Tag'Access,
            "Push: reject conflicting remote tag");

      Register_Routine
         (T,
            Push_File_Url_Branch_Fast_Forward'Access,
            "Push: file URL fast-forward branch");

      Register_Routine
         (T,
            Push_Http_Local_Pack_Failure_Cleans_Temp_Pack'Access,
            "Push: HTTP local pack failure cleans temporary pack");

      Register_Routine
         (T,
            Push_Http_Report_Status_Rejection_Does_Not_Update_Tracking'Access,
            "Push: HTTP report-status rejection does not update tracking");

      Register_Routine
         (T,
            Push_Http_Network_Drop_Does_Not_Update_Tracking'Access,
            "Push: HTTP network drop does not update existing tracking");

      Register_Routine
         (T,
            Push_Http_Unpack_Error_Does_Not_Update_Tracking'Access,
            "Push: HTTP unpack error does not update existing tracking");

      Register_Routine
         (T,
            Push_Http_Non_Fast_Forward_Does_Not_Update_Tracking'Access,
            "Push: HTTP non-fast-forward rejection does not update existing tracking");

      Register_Routine
         (T,
            Push_Http_Partial_Report_Status_Does_Not_Update_Tracking'Access,
            "Push: HTTP partial report-status does not update existing tracking");

      Register_Routine
         (T,
            Push_Http_Tags_No_Clobber_Rejected'Access,
            "Push: HTTP push --tags refuses to overwrite a differing tag");

      Register_Routine
         (T,
            Push_Local_Non_Fast_Forward_Does_Not_Update_Remote'Access,
            "Push: local non-fast-forward does not update remote branch");

      Register_Routine
         (T,
            Push_Local_Force_Updates_Non_Fast_Forward'Access,
            "Push: --force updates a non-fast-forward remote branch");

      Register_Routine
         (T,
            Push_Local_Delete_Removes_Remote_Ref'Access,
            "Push: --delete removes a remote ref (and rejects absent)");

      Register_Routine
         (T,
            Push_Local_Refspec_Updates_Named_Ref'Access,
            "Push: refspec pushes source to a named remote branch and tag");

      Register_Routine
         (T,
            Push_Local_Tags_Force_Overwrites_Differing_Tag'Access,
            "Push: --tags --force overwrites a differing remote tag");

      Register_Routine
         (T,
            Push_Default_Uses_Configured_Refspec'Access,
            "Push: no-refspec push applies remote.<name>.push config");

      Register_Routine
         (T,
            Push_Local_Malformed_Remote_Branch_Does_Not_Copy_Objects'Access,
            "Push: local malformed remote branch does not copy objects");

      Register_Routine
         (T,
            Push_Local_Symlink_Remote_Branch_Does_Not_Copy_Objects'Access,
            "Push: local symlink remote branch does not copy objects");

      Register_Routine
         (T,
            Push_Local_Tag_Rejection_Does_Not_Update_Remote_Tag'Access,
            "Push: local conflicting tag push does not update remote tag");

      Register_Routine
         (T,
            Push_Local_Tag_Rejection_Does_Not_Copy_Objects'Access,
            "Push: local conflicting tag push does not copy objects");

      Register_Routine
         (T,
            Push_Local_Malformed_Remote_Tag_Does_Not_Copy_Objects'Access,
            "Push: local malformed remote tag does not copy objects");

      Register_Routine
         (T,
            Push_Local_Symlink_Remote_Tag_Does_Not_Copy_Objects'Access,
            "Push: local symlink remote tag does not copy objects");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Push");
   end Name;

end Version.Push.Tests;