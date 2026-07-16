with Ada.Directories;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions; use AUnit.Assertions;
with AUnit.Test_Cases;

with GNAT.Sockets;
with GNAT.SHA256;

with Version.Files;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Refs;
with Version.Repository;

package body Version.LFS.Tests is

   use AUnit.Test_Cases.Registration;

   CR : constant Character := Character'Val (13);
   LF : constant Character := Character'Val (10);

   function To_Stream (Text : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
      J      : Stream_Element_Offset := Result'First;
   begin
      for I in Text'Range loop
         Result (J) := Stream_Element (Character'Pos (Text (I)));
         J := J + 1;
      end loop;
      return Result;
   end To_Stream;

   --  Minimal LFS batch server: answers the upload batch POST with an upload
   --  action pointing at its own /put endpoint, then accepts the object PUT.
   task type LFS_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end LFS_Server;

   task body LFS_Server is
      Server      : GNAT.Sockets.Socket_Type;
      Client      : GNAT.Sockets.Socket_Type;
      Address     : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Bound       : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 8192);
      Request_End : Stream_Element_Offset;

      procedure Send (Sock : GNAT.Sockets.Socket_Type; Data : Stream_Element_Array)
      is
         Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Sock, Data, Last);
      end Send;
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

      declare
         Port_Img : constant String :=
           Ada.Strings.Fixed.Trim
             (Integer'Image (Integer (Bound.Port)), Ada.Strings.Left);
         Batch : constant String :=
           "{""transfer"":""basic"",""objects"":[{""oid"":""x"",""size"":1,"
           & """actions"":{""upload"":{""href"":""http://127.0.0.1:"
           & Port_Img & "/put""}}}]}";
         Batch_Response : constant String :=
           "HTTP/1.1 200 OK" & CR & LF
           & "Content-Type: application/vnd.git-lfs+json" & CR & LF
           & "Content-Length: "
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Batch'Length), Ada.Strings.Left)
           & CR & LF & "Connection: close" & CR & LF & CR & LF & Batch;
         Ok_Empty : constant String :=
           "HTTP/1.1 200 OK" & CR & LF & "Content-Length: 0" & CR & LF
           & "Connection: close" & CR & LF & CR & LF;
      begin
         --  Batch POST.
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         Send (Client, To_Stream (Batch_Response));
         GNAT.Sockets.Close_Socket (Client);

         --  Object PUT.
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         Send (Client, To_Stream (Ok_Empty));
         GNAT.Sockets.Close_Socket (Client);
      end;
      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others => null;
         end;
   end LFS_Server;

   function Contains (Data : Stream_Element_Array;
                      Last : Stream_Element_Offset;
                      Pattern : String) return Boolean
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

   --  Basic-auth-gated LFS server: any request lacking the correct
   --  "Authorization: Basic dXNlcjpwYXNz" (user:pass) is answered 401; an
   --  authenticated batch POST gets the upload action and an authenticated PUT
   --  gets 200. Loops until an authenticated PUT completes.
   task type LFS_Auth_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end LFS_Auth_Server;

   task body LFS_Auth_Server is
      Server      : GNAT.Sockets.Socket_Type;
      Client      : GNAT.Sockets.Socket_Type;
      Address     : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Bound       : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 8192);
      Request_End : Stream_Element_Offset;
      Done        : Boolean := False;

      procedure Send (Sock : GNAT.Sockets.Socket_Type; Data : Stream_Element_Array)
      is
         Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Sock, Data, Last);
      end Send;
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

      declare
         Port_Img : constant String :=
           Ada.Strings.Fixed.Trim
             (Integer'Image (Integer (Bound.Port)), Ada.Strings.Left);
         Batch : constant String :=
           "{""transfer"":""basic"",""objects"":[{""oid"":""x"",""size"":1,"
           & """actions"":{""upload"":{""href"":""http://127.0.0.1:"
           & Port_Img & "/put""}}}]}";
         Batch_Response : constant String :=
           "HTTP/1.1 200 OK" & CR & LF
           & "Content-Type: application/vnd.git-lfs+json" & CR & LF
           & "Content-Length: "
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Batch'Length), Ada.Strings.Left)
           & CR & LF & "Connection: close" & CR & LF & CR & LF & Batch;
         Ok_Empty : constant String :=
           "HTTP/1.1 200 OK" & CR & LF & "Content-Length: 0" & CR & LF
           & "Connection: close" & CR & LF & CR & LF;
         Unauthorized : constant String :=
           "HTTP/1.1 401 Unauthorized" & CR & LF
           & "WWW-Authenticate: Basic realm=""lfs""" & CR & LF
           & "Content-Length: 0" & CR & LF & "Connection: close"
           & CR & LF & CR & LF;
      begin
         while not Done loop
            GNAT.Sockets.Accept_Socket (Server, Client, Peer);
            GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
            if Contains (Request, Request_End,
                         "Authorization: Basic dXNlcjpwYXNz")
            then
               if Contains (Request, Request_End, "PUT ") then
                  Send (Client, To_Stream (Ok_Empty));
                  Done := True;
               else
                  Send (Client, To_Stream (Batch_Response));
               end if;
            else
               Send (Client, To_Stream (Unauthorized));
            end if;
            GNAT.Sockets.Close_Socket (Client);
         end loop;
      end;
      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others => null;
         end;
   end LFS_Auth_Server;

   --  Minimal LFS lock server: answers create (POST /locks), list
   --  (GET /locks) and unlock (POST /locks/<id>/unlock) with a single canned
   --  lock, so the lock round-trip can be exercised end to end. Stops once it
   --  has served an unlock request.
   task type Lock_Server is
      entry Ready (Port : out GNAT.Sockets.Port_Type);
   end Lock_Server;

   task body Lock_Server is
      Server      : GNAT.Sockets.Socket_Type;
      Client      : GNAT.Sockets.Socket_Type;
      Address     : constant GNAT.Sockets.Sock_Addr_Type :=
        (Family => GNAT.Sockets.Family_Inet,
         Addr   => GNAT.Sockets.Inet_Addr ("127.0.0.1"),
         Port   => 0);
      Peer        : GNAT.Sockets.Sock_Addr_Type;
      Bound       : GNAT.Sockets.Sock_Addr_Type;
      Request     : Stream_Element_Array (1 .. 8192);
      Request_End : Stream_Element_Offset;
      Done        : Boolean := False;

      Lock : constant String :=
        "{""id"":""lk1"",""path"":""big.bin"","
        & """locked_at"":""2024-01-01T00:00:00Z"","
        & """owner"":{""name"":""tester""}}";

      function Response (Code, Body_Text : String) return String is
      begin
         return "HTTP/1.1 " & Code & CR & LF
           & "Content-Type: application/vnd.git-lfs+json" & CR & LF
           & "Content-Length: "
           & Ada.Strings.Fixed.Trim
               (Integer'Image (Body_Text'Length), Ada.Strings.Left)
           & CR & LF & "Connection: close" & CR & LF & CR & LF & Body_Text;
      end Response;

      procedure Send (Sock : GNAT.Sockets.Socket_Type; Data : Stream_Element_Array)
      is
         Last : Stream_Element_Offset;
      begin
         GNAT.Sockets.Send_Socket (Sock, Data, Last);
      end Send;
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

      while not Done loop
         GNAT.Sockets.Accept_Socket (Server, Client, Peer);
         GNAT.Sockets.Receive_Socket (Client, Request, Request_End);
         if Contains (Request, Request_End, "/unlock") then
            Send (Client, To_Stream (Response ("200 OK", "{""lock"":" & Lock & "}")));
            Done := True;
         elsif Contains (Request, Request_End, "GET ") then
            Send
              (Client,
               To_Stream
                 (Response
                    ("200 OK",
                     "{""locks"":[" & Lock & "],""next_cursor"":""""}")));
         else
            Send (Client, To_Stream (Response ("201 Created", "{""lock"":" & Lock & "}")));
         end if;
         GNAT.Sockets.Close_Socket (Client);
      end loop;
      GNAT.Sockets.Close_Socket (Server);
   exception
      when others =>
         begin
            GNAT.Sockets.Close_Socket (Server);
         exception
            when others => null;
         end;
   end Lock_Server;

   --  Push-time upload of a locally cached LFS object to an HTTP LFS store
   --  completes the batch + PUT handshake (git's basic transfer).
   procedure Upload_Object_Over_HTTP
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Content : constant String := "LFS upload regression payload" & LF;
      Oid     : constant String := GNAT.SHA256.Digest (Content);
      Server  : LFS_Server;
      Port    : GNAT.Sockets.Port_Type;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Common_Git_Dir (Repo);
         Cache : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join
                   (Version.Files.Join
                      (Version.Files.Join (Git_Dir, "lfs"), "objects"),
                    Oid (Oid'First .. Oid'First + 1)),
                 Oid (Oid'First + 2 .. Oid'First + 3)),
              Oid);
      begin
         Version.Files.Write_Binary_File_Atomic (Cache, Content);
         Server.Ready (Port);
         Version.Git_Fixtures.Run
           (Root,
            "git config lfs.url http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim
                (Integer'Image (Integer (Port)), Ada.Strings.Left));

         Assert
           (Version.LFS.Upload_Object (Repo, Oid, "origin"),
            "LFS HTTP upload must complete the batch + PUT handshake");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Upload_Object_Over_HTTP;

   --  Against an LFS server that requires HTTP Basic auth, the upload runs the
   --  repo's credential.helper on 401 and retries with credentials (git's LFS
   --  auth handshake) on both the batch POST and the object PUT.
   procedure Upload_Object_Over_HTTP_With_Auth
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Content : constant String := "LFS auth regression payload" & LF;
      Oid     : constant String := GNAT.SHA256.Digest (Content);
      Server  : LFS_Auth_Server;
      Port    : GNAT.Sockets.Port_Type;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Git_Dir : constant String := Version.Repository.Common_Git_Dir (Repo);
         Cache : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join
                   (Version.Files.Join
                      (Version.Files.Join (Git_Dir, "lfs"), "objects"),
                    Oid (Oid'First .. Oid'First + 1)),
                 Oid (Oid'First + 2 .. Oid'First + 3)),
              Oid);
      begin
         Version.Files.Write_Binary_File_Atomic (Cache, Content);
         Server.Ready (Port);
         Version.Git_Fixtures.Run
           (Root,
            "git config lfs.url http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim
                (Integer'Image (Integer (Port)), Ada.Strings.Left));
         Version.Git_Fixtures.Run
           (Root,
            "git config credential.helper "
            & "'!printf ""username=user\npassword=pass\n""'");

         Assert
           (Version.LFS.Upload_Object (Repo, Oid, "origin"),
            "authenticated LFS HTTP upload must fill credentials and retry");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Upload_Object_Over_HTTP_With_Auth;

   --  Lock, list, then unlock a path against an HTTP LFS lock server: the
   --  responses are parsed into Lock_Info and the round-trip completes
   --  (git-lfs's /locks, /locks list and /locks/<id>/unlock routes).
   procedure Lock_Round_Trip_Over_HTTP
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Server  : Lock_Server;
      Port    : GNAT.Sockets.Port_Type;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Server.Ready (Port);
         Version.Git_Fixtures.Run
           (Root,
            "git config lfs.url http://127.0.0.1:"
            & Ada.Strings.Fixed.Trim
                (Integer'Image (Integer (Port)), Ada.Strings.Left));

         declare
            Created : constant Version.LFS.Lock_Info :=
              Version.LFS.Create_Lock (Repo, "big.bin");
         begin
            Assert
              (Ada.Strings.Unbounded.To_String (Created.Path) = "big.bin",
               "Create_Lock must parse the lock path");
            Assert
              (Ada.Strings.Unbounded.To_String (Created.Id) = "lk1",
               "Create_Lock must parse the lock id");
            Assert
              (Ada.Strings.Unbounded.To_String (Created.Owner) = "tester",
               "Create_Lock must parse the owner name");
         end;

         declare
            Listed : constant Version.LFS.Lock_Array :=
              Version.LFS.List_Locks (Repo);
         begin
            Assert (Listed'Length = 1, "List_Locks must return one lock");
            Assert
              (Ada.Strings.Unbounded.To_String (Listed (Listed'First).Path)
                 = "big.bin",
               "List_Locks must parse the listed lock path");
         end;

         Version.LFS.Delete_Lock (Repo, Id => "lk1");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Lock_Round_Trip_Over_HTTP;

   --  track / untrack manage filter=lfs rules in .gitattributes, and
   --  Tracked_Patterns reports them (git lfs track/untrack).
   procedure Track_Untrack_Round_Trip
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Assert (Version.LFS.Track_Pattern (Repo, "*.bin"),
                 "first track must add the pattern");
         Assert (not Version.LFS.Track_Pattern (Repo, "*.bin"),
                 "re-tracking the same pattern must be a no-op");
         declare
            Pats : constant Version.LFS.Pattern_Array :=
              Version.LFS.Tracked_Patterns (Repo);
         begin
            Assert (Pats'Length = 1, "exactly one tracked pattern");
            Assert
              (Ada.Strings.Unbounded.To_String (Pats (Pats'First).Pattern)
                 = "*.bin",
               "tracked pattern text");
         end;
         Assert (Version.LFS.Untrack_Pattern (Repo, "*.bin"),
                 "untrack must remove the pattern");
         Assert (not Version.LFS.Untrack_Pattern (Repo, "*.bin"),
                 "untracking an absent pattern must be a no-op");
         Assert (Version.LFS.Tracked_Patterns (Repo)'Length = 0,
                 "no patterns remain after untrack");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Track_Untrack_Round_Trip;

   --  Build_Pointer + Parse_Pointer round-trip (git lfs pointer).
   procedure Pointer_Build_And_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Content : constant String := "some media bytes" & LF;
      Ptr     : constant String := Version.LFS.Build_Pointer (Content);
      Info    : constant Version.LFS.Pointer_Info :=
        Version.LFS.Parse_Pointer (Ptr);
   begin
      Assert (Info.Is_Pointer, "a built pointer must parse as a pointer");
      Assert
        (Ada.Strings.Unbounded.To_String (Info.Oid)
           = GNAT.SHA256.Digest (Content),
         "pointer oid must be the media sha256");
      Assert (Info.Size = Content'Length,
              "pointer size must be the media byte length");
      Assert
        (not Version.LFS.Parse_Pointer ("not a pointer" & LF).Is_Pointer,
         "non-pointer content must not parse as a pointer");
   end Pointer_Build_And_Parse;

   --  migrate import rewrites history so a matching plain blob becomes an LFS
   --  pointer, caches the media, and adds the .gitattributes rule; export
   --  reverses it back to the original blob.
   procedure Migrate_Import_Export_Round_Trip
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run (Root, "git config user.email t@e.com");
      Version.Git_Fixtures.Run (Root, "git config user.name T");
      Ada.Directories.Set_Directory (Root);
      Version.Git_Fixtures.Run (Root, "printf 'binary media payload\n' > big.bin");
      Version.Git_Fixtures.Run (Root, "git add big.bin");
      Version.Git_Fixtures.Run (Root, "git commit -q -m c1");

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Version.LFS.Migrate (Repo, Version.LFS.Migrate_Import, "*.bin");
         declare
            Entries : constant Version.LFS.LFS_Entry_Array :=
              Version.LFS.LFS_Entries_In_Commit
                (Repo,
                 Version.Objects.To_Object_Id
                   (Version.Refs.Current_Commit_Id (Repo)));
         begin
            Assert (Entries'Length = 1,
                    "migrate import must produce one LFS pointer entry");
            Assert (Entries (Entries'First).Cached,
                    "the migrated object's media must be cached");
         end;

         Version.LFS.Migrate (Repo, Version.LFS.Migrate_Export, "*.bin");
         Assert
           (Version.LFS.LFS_Entries_In_Commit
              (Repo,
               Version.Objects.To_Object_Id
                 (Version.Refs.Current_Commit_Id (Repo)))'Length = 0,
            "migrate export must leave no LFS pointers");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Migrate_Import_Export_Round_Trip;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Migrate_Import_Export_Round_Trip'Access,
         "LFS: migrate import/export rewrites history to and from pointers");
      Register_Routine
        (T, Track_Untrack_Round_Trip'Access,
         "LFS: track / untrack manage .gitattributes filter=lfs rules");
      Register_Routine
        (T, Pointer_Build_And_Parse'Access,
         "LFS: build / parse pointer round-trip");
      Register_Routine
        (T, Upload_Object_Over_HTTP'Access,
         "LFS: push uploads a cached object over HTTP batch + PUT");
      Register_Routine
        (T, Upload_Object_Over_HTTP_With_Auth'Access,
         "LFS: authenticated HTTP upload fills credentials on 401");
      Register_Routine
        (T, Lock_Round_Trip_Over_HTTP'Access,
         "LFS: lock / list / unlock round-trip over HTTP");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.LFS");
   end Name;

end Version.LFS.Tests;
