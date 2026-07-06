with Ada.Containers;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;

with Version.Files;
with Version.Hash;
with Version.History;
with Version.Pack_Write;
with Version.Pkt_Line;
with Version.Receive_Pack.Internal;
with Version.Ref_Names;
with Version.Transport.Http;
with Version.Transport.Ssh;

package body Version.Receive_Pack is
   use Version.Objects;

   use Ada.Streams;

   use type Version.Pkt_Line.Packet_Kind;
   use type Version.Pkt_Line.Parse_Status;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

   Zero_Id : constant String := "0000000000000000000000000000000000000000";

   use type Version.Hash.Hash_Algorithm;

   --  Client capability list for a push. A SHA-256 remote requires the client
   --  to declare object-format=sha256 (git receive-pack otherwise treats the
   --  stream as sha1 and fails to unpack).
   function Push_Capabilities
     (Repo : Version.Repository.Repository_Handle) return String is
     (if Version.Repository.Algorithm (Repo) = Version.Hash.Sha256
      then "report-status ofs-delta agent=version object-format=sha256"
      else "report-status ofs-delta agent=version");

   --  The all-zero object id (ref create/delete sentinel) at the repository's
   --  hash width: 40 zeros for sha1, 64 for sha256.
   function Null_Id
     (Repo : Version.Repository.Repository_Handle) return String is
     (if Version.Repository.Algorithm (Repo) = Version.Hash.Sha256
      then [1 .. 64 => '0']
      else Zero_Id);

   package Byte_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Ada.Streams.Stream_Element);

   type Collecting_Consumer is limited new Version.Transport.Http.Byte_Consumer
   with record
      Store : Byte_Vectors.Vector;
   end record;

   overriding
   procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Ada.Streams.Stream_Element_Array);

   overriding
   procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      for I in Data'Range loop
         Item.Store.Append (Data (I));
      end loop;
   end Consume;

   function Collected (Item : Collecting_Consumer) return Stream_Element_Array
   is
      Result :
        Stream_Element_Array
          (1 .. Stream_Element_Offset (Natural (Item.Store.Length)));
      Pos    : Stream_Element_Offset := Result'First;
   begin
      if not Item.Store.Is_Empty then
         for I in Item.Store.First_Index .. Item.Store.Last_Index loop
            Result (Pos) := Item.Store.Element (I);
            Pos := Pos + 1;
         end loop;
      end if;

      return Result;
   end Collected;

   function To_String (Data : Stream_Element_Array) return String is
      Result : String (1 .. Natural (Data'Length));
      J      : Natural := Result'First;
   begin
      for I in Data'Range loop
         Result (J) := Character'Val (Data (I));
         J := J + 1;
      end loop;

      return Result;
   end To_String;

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

   function Trim_LF (Text : String) return String is
   begin
      if Text'Length > 0 and then Text (Text'Last) = LF then
         return Text (Text'First .. Text'Last - 1);
      end if;

      return Text;
   end Trim_LF;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return
        Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   function Has_Capability
     (Capabilities : String; Name : String) return Boolean
   is
      Start : Natural := Capabilities'First;
   begin
      if Capabilities'Length = 0 then
         return False;
      end if;

      while Start <= Capabilities'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Capabilities'Last and then Capabilities (Stop) /= ' '
            loop
               Stop := Stop + 1;
            end loop;

            if Capabilities (Start .. Stop - 1) = Name then
               return True;
            end if;

            Start := Stop + 1;
         end;
      end loop;

      return False;
   end Has_Capability;

   procedure Append_Bytes
     (Target : in out Stream_Element_Array;
      Pos    : in out Stream_Element_Offset;
      Source : Stream_Element_Array) is
   begin
      for I in Source'Range loop
         Target (Pos) := Source (I);
         Pos := Pos + 1;
      end loop;
   end Append_Bytes;

   procedure Append_Advertised_Ref
     (Result : in out Discovery_Result; Payload : String; First : Boolean)
   is
      Clean   : constant String := Trim_LF (Payload);
      NUL_Pos : Natural := 0;
   begin
      if First then
         for I in Clean'Range loop
            if Clean (I) = NUL then
               NUL_Pos := I;
               exit;
            end if;
         end loop;
      end if;

      declare
         Ref_Text : constant String :=
           (if First and then NUL_Pos /= 0
            then Clean (Clean'First .. NUL_Pos - 1)
            else Clean);
      begin
         if First and then NUL_Pos /= 0 then
            Result.Capabilities :=
              To_Unbounded_String (Clean (NUL_Pos + 1 .. Clean'Last));
         end if;

         declare
            --  "<id> <refname>": the object id (40 or 64 hex) is the token
            --  before the first space.
            Sep : Natural := 0;
         begin
            for I in Ref_Text'Range loop
               if Ref_Text (I) = ' ' then
                  Sep := I;
                  exit;
               end if;
            end loop;

            if Sep = 0 then
               raise Ada.IO_Exceptions.Data_Error
                 with "malformed receive-pack advertised ref separator";
            end if;

            declare
               Id_Text : constant String :=
                 Ref_Text (Ref_Text'First .. Sep - 1);
               Name    : constant String :=
                 Ref_Text (Sep + 1 .. Ref_Text'Last);
            begin
               if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                  raise Ada.IO_Exceptions.Data_Error
                    with "invalid receive-pack advertised object id";
               end if;

               Result.Refs.Append
                 (Advertised_Ref'(Name => To_Unbounded_String (Name),
                                  Id   => To_Object_Id (Id_Text)));
            end;
         end;
      end;
   end Append_Advertised_Ref;

   function Parse_Discovery
     (Data : Stream_Element_Array) return Discovery_Result
   is
      Parser            : Version.Pkt_Line.Parser;
      Kind              : Version.Pkt_Line.Packet_Kind;
      Buffer            : Stream_Element_Array (1 .. 65_520);
      Last              : Stream_Element_Offset;
      Status            : Version.Pkt_Line.Parse_Status;
      Result            : Discovery_Result;
      Saw_Service       : Boolean := False;
      Saw_Service_Flush : Boolean := False;
      First_Ref         : Boolean := True;
   begin
      Version.Pkt_Line.Feed (Parser, Data);

      loop
         Status := Version.Pkt_Line.Next (Parser, Kind, Buffer, Last);

         case Status is
            when Version.Pkt_Line.Ok             =>
               null;

            when Version.Pkt_Line.Need_More_Data =>
               exit;

            when others                          =>
               raise Ada.IO_Exceptions.Data_Error
                 with "malformed receive-pack discovery pkt-line";
         end case;

         if not Saw_Service then
            if Kind /= Version.Pkt_Line.Data_Packet or else Last < Buffer'First
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "receive-pack discovery missing service header";
            end if;

            declare
               Service : constant String :=
                 To_String (Buffer (Buffer'First .. Last));
            begin
               if Trim_LF (Service) /= "# service=git-receive-pack" then
                  raise Ada.IO_Exceptions.Data_Error
                    with "unexpected receive-pack discovery service header";
               end if;
            end;

            Saw_Service := True;

         elsif not Saw_Service_Flush then
            if Kind /= Version.Pkt_Line.Flush_Packet then
               raise Ada.IO_Exceptions.Data_Error
                 with "receive-pack discovery missing service flush";
            end if;

            Saw_Service_Flush := True;

         elsif Kind = Version.Pkt_Line.Flush_Packet then
            exit;

         elsif Kind = Version.Pkt_Line.Data_Packet then
            if Last < Buffer'First then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty receive-pack advertised ref";
            end if;

            Append_Advertised_Ref
              (Result  => Result,
               Payload => To_String (Buffer (Buffer'First .. Last)),
               First   => First_Ref);
            First_Ref := False;

         else
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected receive-pack discovery packet kind";
         end if;
      end loop;

      if not Saw_Service or else not Saw_Service_Flush then
         raise Ada.IO_Exceptions.Data_Error
           with "incomplete receive-pack discovery";
      end if;

      if not Has_Capability (To_String (Result.Capabilities), "report-status")
      then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack server does not advertise report-status";
      end if;

      return Result;
   end Parse_Discovery;

   function Parse_Advertisement
     (Data : Stream_Element_Array) return Discovery_Result
   is
      Parser    : Version.Pkt_Line.Parser;
      Kind      : Version.Pkt_Line.Packet_Kind;
      Buffer    : Stream_Element_Array (1 .. 65_520);
      Last      : Stream_Element_Offset;
      Status    : Version.Pkt_Line.Parse_Status;
      Result    : Discovery_Result;
      First_Ref : Boolean := True;
      Saw_Ref   : Boolean := False;
   begin
      Version.Pkt_Line.Feed (Parser, Data);

      loop
         Status := Version.Pkt_Line.Next (Parser, Kind, Buffer, Last);

         case Status is
            when Version.Pkt_Line.Ok             =>
               null;

            when Version.Pkt_Line.Need_More_Data =>
               exit;

            when others                          =>
               raise Ada.IO_Exceptions.Data_Error
                 with "malformed receive-pack advertisement pkt-line";
         end case;

         if Kind = Version.Pkt_Line.Flush_Packet then
            exit;

         elsif Kind = Version.Pkt_Line.Data_Packet then
            if Last < Buffer'First then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty receive-pack advertised ref";
            end if;

            Append_Advertised_Ref
              (Result  => Result,
               Payload => To_String (Buffer (Buffer'First .. Last)),
               First   => First_Ref);
            First_Ref := False;
            Saw_Ref := True;

         else
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected receive-pack advertisement packet kind";
         end if;
      end loop;

      if not Saw_Ref then
         raise Ada.IO_Exceptions.Data_Error
           with "empty receive-pack advertisement";
      end if;

      if not Has_Capability (To_String (Result.Capabilities), "report-status")
      then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack server does not advertise report-status";
      end if;

      return Result;
   end Parse_Advertisement;

   function Build_Update_Command
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String) return Stream_Element_Array is
   begin
      if (Old_Id /= Zero_Id
          and then not Version.Objects.Is_Valid_Hex_Object_Id (Old_Id))
        or else not Version.Objects.Is_Valid_Hex_Object_Id (New_Id)
      then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid receive-pack update object id";
      end if;

      if not Version.Ref_Names.Is_Valid_Ref_Name (Ref_Name)
        or else not (Starts_With (Ref_Name, "refs/heads/")
                     or else Starts_With (Ref_Name, "refs/tags/"))
        or else Ref_Name = "refs/heads/"
        or else Ref_Name = "refs/tags/"
      then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid receive-pack ref";
      end if;

      declare
         Line : constant String :=
           Old_Id & " " & New_Id & " " & Ref_Name & NUL & Capabilities & LF;
      begin
         return Version.Pkt_Line.Encode_Data (To_Stream (Line));
      end;
   end Build_Update_Command;

   function Build_Request
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String;
      Pack         : Stream_Element_Array) return Stream_Element_Array
   is
      Command : constant Stream_Element_Array :=
        Build_Update_Command
          (Old_Id       => Old_Id,
           New_Id       => New_Id,
           Ref_Name     => Ref_Name,
           Capabilities => Capabilities);
      Flush   : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Result  :
        Stream_Element_Array
          (1
           ..
             Stream_Element_Offset
               (Command'Length + Flush'Length + Pack'Length));
      Pos     : Stream_Element_Offset := Result'First;
   begin
      Append_Bytes (Result, Pos, Command);
      Append_Bytes (Result, Pos, Flush);
      Append_Bytes (Result, Pos, Pack);
      return Result;
   end Build_Request;

   function Build_Request_From_Pack_File
     (Old_Id       : String;
      New_Id       : String;
      Ref_Name     : String;
      Capabilities : String;
      Pack_Path    : String) return Stream_Element_Array
   is
      Command  : constant Stream_Element_Array :=
        Build_Update_Command
          (Old_Id       => Old_Id,
           New_Id       => New_Id,
           Ref_Name     => Ref_Name,
           Capabilities => Capabilities);
      Flush    : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Flush;
      File     : Ada.Streams.Stream_IO.File_Type;
      Pack_Len : constant Natural :=
        Natural (Ada.Directories.Size (Pack_Path));
      Result   :
        Stream_Element_Array
          (1
           ..
             Stream_Element_Offset (Command'Length + Flush'Length + Pack_Len));
      Pos      : Stream_Element_Offset := Result'First;
      Last     : Stream_Element_Offset;
   begin
      Append_Bytes (Result, Pos, Command);
      Append_Bytes (Result, Pos, Flush);

      Ada.Streams.Stream_IO.Open
        (File,
         Ada.Streams.Stream_IO.In_File,
         Version.Files.To_Native_Path (Pack_Path));
      Ada.Streams.Stream_IO.Read (File, Result (Pos .. Result'Last), Last);
      Ada.Streams.Stream_IO.Close (File);

      if Last /= Result'Last then
         raise Ada.IO_Exceptions.Data_Error
           with "could not read complete pack file into receive-pack request";
      end if;

      return Result;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Build_Request_From_Pack_File;

   procedure Handle_Report_Status_Line
     (Line          : String;
      Ref_Name      : String;
      Saw_Unpack_Ok : in out Boolean;
      Saw_Ref_Ok    : in out Boolean) is
   begin
      if Line'Length = 0 then
         return;
      elsif Line = "unpack ok" then
         Saw_Unpack_Ok := True;
      elsif Starts_With (Line, "unpack ") then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack unpack failed: " & Line;
      elsif Line = "ok " & Ref_Name then
         Saw_Ref_Ok := True;
      elsif Starts_With (Line, "ng " & Ref_Name & " ") then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack ref update failed: " & Line;
      elsif Starts_With (Line, "ng ") then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack ref update failed: " & Line;
      end if;
   end Handle_Report_Status_Line;

   procedure Handle_Report_Status_Payload
     (Payload       : String;
      Ref_Name      : String;
      Saw_Unpack_Ok : in out Boolean;
      Saw_Ref_Ok    : in out Boolean)
   is
      Start : Natural := Payload'First;
      Stop  : Natural := Payload'First;
   begin
      while Start <= Payload'Last loop
         Stop := Start;

         while Stop <= Payload'Last and then Payload (Stop) /= LF loop
            Stop := Stop + 1;
         end loop;

         if Stop > Start then
            Handle_Report_Status_Line
              (Line          => Payload (Start .. Stop - 1),
               Ref_Name      => Ref_Name,
               Saw_Unpack_Ok => Saw_Unpack_Ok,
               Saw_Ref_Ok    => Saw_Ref_Ok);
         else
            Handle_Report_Status_Line
              (Line          => "",
               Ref_Name      => Ref_Name,
               Saw_Unpack_Ok => Saw_Unpack_Ok,
               Saw_Ref_Ok    => Saw_Ref_Ok);
         end if;

         Start := Stop + 1;
      end loop;
   end Handle_Report_Status_Payload;

   procedure Parse_Report_Status
     (Response_Bytes : Stream_Element_Array; Ref_Name : String)
   is
      Parser        : Version.Pkt_Line.Parser;
      Kind          : Version.Pkt_Line.Packet_Kind;
      Buffer        : Stream_Element_Array (1 .. 65_520);
      Last          : Stream_Element_Offset;
      Status        : Version.Pkt_Line.Parse_Status;
      Saw_Unpack_Ok : Boolean := False;
      Saw_Ref_Ok    : Boolean := False;
   begin
      Version.Pkt_Line.Feed (Parser, Response_Bytes);

      loop
         Status := Version.Pkt_Line.Next (Parser, Kind, Buffer, Last);

         case Status is
            when Version.Pkt_Line.Ok             =>
               null;

            when Version.Pkt_Line.Need_More_Data =>
               exit;

            when others                          =>
               raise Ada.IO_Exceptions.Data_Error
                 with "malformed receive-pack report-status pkt-line";
         end case;

         if Kind = Version.Pkt_Line.Flush_Packet then
            if Saw_Unpack_Ok or else Saw_Ref_Ok then
               exit;
            end if;

         elsif Kind /= Version.Pkt_Line.Data_Packet or else Last < Buffer'First
         then
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected receive-pack report-status packet";
         end if;

         if Buffer (Buffer'First) = 1 then
            if Last = Buffer'First then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty receive-pack side-band report-status packet";
            end if;

            Handle_Report_Status_Payload
              (Payload       => To_String (Buffer (Buffer'First + 1 .. Last)),
               Ref_Name      => Ref_Name,
               Saw_Unpack_Ok => Saw_Unpack_Ok,
               Saw_Ref_Ok    => Saw_Ref_Ok);

         elsif Buffer (Buffer'First) = 2 then
            null;

         elsif Buffer (Buffer'First) = 3 then
            raise Ada.IO_Exceptions.Data_Error
              with "remote receive-pack error: "
                   & To_String (Buffer (Buffer'First + 1 .. Last));

         else
            Handle_Report_Status_Payload
              (Payload       => To_String (Buffer (Buffer'First .. Last)),
               Ref_Name      => Ref_Name,
               Saw_Unpack_Ok => Saw_Unpack_Ok,
               Saw_Ref_Ok    => Saw_Ref_Ok);
         end if;
      end loop;

      if not Saw_Unpack_Ok then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack report-status missing unpack ok";
      end if;

      if not Saw_Ref_Ok then
         raise Ada.IO_Exceptions.Data_Error
           with "receive-pack report-status missing ok for " & Ref_Name;
      end if;
   end Parse_Report_Status;

   function Local_Branch_Commit
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return Version.Objects.Hex_Object_Id is
   begin
      Version.Ref_Names.Require_Branch_Name (Name);

      declare
         Path : constant String :=
           Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "refs/heads/" & Name);
      begin
         if not Ada.Directories.Exists (Path) then
            raise Ada.IO_Exceptions.Data_Error
              with "local branch does not exist: " & Name;
         end if;

         declare
            Text : constant String := Version.Files.Read_Binary_File (Path);
            Last : Natural := Text'First;
         begin
            while Last <= Text'Last
              and then Text (Last) /= LF
              and then Text (Last) /= Character'Val (13)
            loop
               Last := Last + 1;
            end loop;

            declare
               Id_Text : constant String := Text (Text'First .. Last - 1);
            begin
               if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                  raise Ada.IO_Exceptions.Data_Error
                    with "invalid local branch commit id";
               end if;

               return Version.Objects.To_Object_Id (Id_Text);
            end;
         end;
      end;
   end Local_Branch_Commit;

   function Find_Remote_Branch
     (Discovery : Discovery_Result; Branch_Name : String) return String
   is
      Target : constant String := "refs/heads/" & Branch_Name;
   begin
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      if not Discovery.Refs.Is_Empty then
         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            if To_String (Discovery.Refs.Element (I).Name) = Target then
               return To_String (Discovery.Refs.Element (I).Id);
            end if;
         end loop;
      end if;

      return "";
   end Find_Remote_Branch;

   procedure Delete_If_Exists (Path : String) is
   begin
      Version.Files.Delete_File_If_Exists (Path);
   end Delete_If_Exists;

   procedure Delete_Push_Temporary_Pack
     (Pack_Path  : String;
      Index_Path : String) is
   begin
      Delete_If_Exists (Pack_Path);
      Delete_If_Exists (Index_Path);
   end Delete_Push_Temporary_Pack;

   procedure Write_Push_Temporary_Pack
     (Repo       : Version.Repository.Repository_Handle;
      Object_Ids : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Path  : String;
      Index_Path : String) is
   begin
      Delete_Push_Temporary_Pack
        (Pack_Path  => Pack_Path,
         Index_Path => Index_Path);

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Object_Ids,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);
   exception
      when others =>
         Delete_Push_Temporary_Pack
           (Pack_Path  => Pack_Path,
            Index_Path => Index_Path);
         raise;
   end Write_Push_Temporary_Pack;

   function Valid_Branch_Name (Branch_Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Branch_Name (Branch_Name);
   end Valid_Branch_Name;

   procedure Push_Branch
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Branch_Name : String;
      Force       : Boolean := False)
   is
      Capabilities       : constant String := Push_Capabilities (Repo);
      Discovery_Consumer : Collecting_Consumer;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      if not Valid_Branch_Name (Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name for HTTP push: " & Branch_Name;
      end if;

      declare
         Local_Id : constant Version.Objects.Hex_Object_Id :=
           Local_Branch_Commit (Repo, Branch_Name);
      begin
         Version.Transport.Http.Discover_Receive_Pack
           (Url => Url, Consumer => Discovery_Consumer);

         declare
            Discovery      : constant Discovery_Result :=
              Parse_Discovery (Collected (Discovery_Consumer));
            Remote_Id_Text : constant String :=
              Find_Remote_Branch (Discovery, Branch_Name);
            Old_Id         : constant String :=
              (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
            Tracking_Old   : constant String :=
              Version.Receive_Pack.Internal.Remote_Tracking_Id_Or_Zero
                (Repo        => Repo,
                 Remote_Name => Remote_Name,
                 Branch_Name => Branch_Name);
         begin
            if Remote_Id_Text'Length > 0 and then not Force then
               if not Version.History.Is_Ancestor
                        (Repo       => Repo,
                         Base_Id    =>
                           Version.Objects.To_Object_Id (Remote_Id_Text),
                         Derived_Id => Local_Id)
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "cannot push: remote branch is not an ancestor";
               end if;
            end if;

            declare
               Pack_Path  : constant String :=
                 Version.Files.Join
                   (Version.Repository.Common_Git_Dir (Repo),
                    "objects/pack/version-push-temp.pack");
               Index_Path : constant String :=
                 Version.Files.Join
                   (Version.Repository.Common_Git_Dir (Repo),
                    "objects/pack/version-push-temp.idx");
               Objects    :
                 constant Version.Objects.Object_Id_Vectors.Vector :=
                   Version.History.Reachable_Objects
                     (Repo => Repo, Root_Id => Local_Id);
            begin
               Write_Push_Temporary_Pack
                 (Repo       => Repo,
                  Object_Ids => Objects,
                  Pack_Path  => Pack_Path,
                  Index_Path => Index_Path);

               begin
                  declare
                     Ref_Name          : constant String :=
                       "refs/heads/" & Branch_Name;
                     Request           : constant Stream_Element_Array :=
                       Build_Request_From_Pack_File
                         (Old_Id       => Old_Id,
                          New_Id       => To_String (Local_Id),
                          Ref_Name     => Ref_Name,
                          Capabilities => Capabilities,
                          Pack_Path    => Pack_Path);
                     Response_Consumer : Collecting_Consumer;
                  begin
                     Version.Transport.Http.Receive_Pack
                       (Url      => Url,
                        Request  => Request,
                        Consumer => Response_Consumer);

                     Parse_Report_Status
                       (Response_Bytes => Collected (Response_Consumer),
                        Ref_Name       => Ref_Name);

                     Version.Receive_Pack.Internal.Update_Remote_Tracking_Ref
                       (Repo         => Repo,
                        Remote_Name  => Remote_Name,
                        Branch_Name  => Branch_Name,
                        Commit_Id    => Local_Id,
                        Expected_Old => Tracking_Old);
                  end;
               exception
                  when others =>
                     Delete_Push_Temporary_Pack
                       (Pack_Path  => Pack_Path,
                        Index_Path => Index_Path);
                     raise;
               end;

               Delete_Push_Temporary_Pack
                 (Pack_Path  => Pack_Path,
                  Index_Path => Index_Path);
            end;
         end;
      end;
   end Push_Branch;

   procedure Push_Branch_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Branch_Name : String;
      Force       : Boolean := False)
   is
      Capabilities : constant String := Push_Capabilities (Repo);
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Unbounded_String;
      Buffer : Stream_Element_Array (1 .. 8192);
      Last   : Stream_Element_Offset;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      if not Valid_Branch_Name (Branch_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid branch name for SSH push: " & Branch_Name;
      end if;

      Version.Transport.Ssh.Open_Receive_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Unbounded.Index (Raw_Advertisement, "0000") /= 0;
      end loop;

      declare
         Local_Id : constant Version.Objects.Hex_Object_Id :=
           Local_Branch_Commit (Repo, Branch_Name);
         Discovery : constant Discovery_Result :=
           Parse_Advertisement (To_Stream (To_String (Raw_Advertisement)));
         Remote_Id_Text : constant String :=
           Find_Remote_Branch (Discovery, Branch_Name);
         Old_Id : constant String :=
           (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
         Tracking_Old : constant String :=
           Version.Receive_Pack.Internal.Remote_Tracking_Id_Or_Zero
             (Repo        => Repo,
              Remote_Name => Remote_Name,
              Branch_Name => Branch_Name);
      begin
         if Remote_Id_Text'Length > 0 and then not Force then
            if not Version.History.Is_Ancestor
                     (Repo       => Repo,
                      Base_Id    =>
                        Version.Objects.To_Object_Id (Remote_Id_Text),
                      Derived_Id => Local_Id)
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "cannot push: remote branch is not an ancestor";
            end if;
         end if;

         declare
            Pack_Path  : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.pack");
            Index_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.idx");
            Objects    :
              constant Version.Objects.Object_Id_Vectors.Vector :=
                Version.History.Reachable_Objects
                  (Repo => Repo, Root_Id => Local_Id);
         begin
            Write_Push_Temporary_Pack
              (Repo       => Repo,
               Object_Ids => Objects,
               Pack_Path  => Pack_Path,
               Index_Path => Index_Path);

            begin
               declare
                  Ref_Name : constant String :=
                    "refs/heads/" & Branch_Name;
                  Request : constant Stream_Element_Array :=
                    Build_Request_From_Pack_File
                      (Old_Id       => Old_Id,
                       New_Id       => To_String (Local_Id),
                       Ref_Name     => Ref_Name,
                       Capabilities => Capabilities,
                       Pack_Path    => Pack_Path);
                  Response : Unbounded_String;
               begin
                  Version.Transport.Ssh.Write (Stream, Request);

                  loop
                     Version.Transport.Ssh.Read_Some
                       (Stream => Stream, Buffer => Buffer, Last => Last);

                     exit when Last < Buffer'First;

                     Append
                       (Response,
                        To_String (Buffer (Buffer'First .. Last)));
                  end loop;

                  Version.Transport.Ssh.Close (Stream);

                  Parse_Report_Status
                    (Response_Bytes => To_Stream (To_String (Response)),
                     Ref_Name       => Ref_Name);

                  Version.Receive_Pack.Internal.Update_Remote_Tracking_Ref
                    (Repo         => Repo,
                     Remote_Name  => Remote_Name,
                     Branch_Name  => Branch_Name,
                     Commit_Id    => Local_Id,
                     Expected_Old => Tracking_Old);
               end;
            exception
               when others =>
                  Delete_Push_Temporary_Pack
                    (Pack_Path  => Pack_Path,
                     Index_Path => Index_Path);
                  Version.Transport.Ssh.Close (Stream);
                  raise;
            end;

            Delete_Push_Temporary_Pack
              (Pack_Path  => Pack_Path,
               Index_Path => Index_Path);
         end;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Push_Branch_Ssh;

   function Find_Remote_Ref
     (Discovery : Discovery_Result; Ref_Name : String) return String is
   begin
      if not Discovery.Refs.Is_Empty then
         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            if To_String (Discovery.Refs.Element (I).Name) = Ref_Name then
               return To_String (Discovery.Refs.Element (I).Id);
            end if;
         end loop;
      end if;
      return "";
   end Find_Remote_Ref;

   procedure Push_Tag
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Tag_Name    : String;
      Object_Id   : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False)
   is
      Capabilities       : constant String := Push_Capabilities (Repo);
      Ref_Name           : constant String := "refs/tags/" & Tag_Name;
      Discovery_Consumer : Collecting_Consumer;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Tag_Name (Tag_Name);

      Version.Transport.Http.Discover_Receive_Pack
        (Url => Url, Consumer => Discovery_Consumer);

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Discovery (Collected (Discovery_Consumer));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
         Old_Id         : constant String :=
           (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
      begin
         if Remote_Id_Text = To_String (Object_Id) then
            return;  --  already up to date
         end if;

         if Remote_Id_Text'Length > 0 and then not Force then
            raise Ada.IO_Exceptions.Data_Error
              with "cannot overwrite existing tag: " & Tag_Name;
         end if;

         declare
            Pack_Path  : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.pack");
            Index_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.idx");
            Objects    :
              constant Version.Objects.Object_Id_Vectors.Vector :=
                Version.History.Reachable_Objects
                  (Repo => Repo, Root_Id => Object_Id);
         begin
            Write_Push_Temporary_Pack
              (Repo       => Repo,
               Object_Ids => Objects,
               Pack_Path  => Pack_Path,
               Index_Path => Index_Path);

            begin
               declare
                  Request           : constant Stream_Element_Array :=
                    Build_Request_From_Pack_File
                      (Old_Id       => Old_Id,
                       New_Id       => To_String (Object_Id),
                       Ref_Name     => Ref_Name,
                       Capabilities => Capabilities,
                       Pack_Path    => Pack_Path);
                  Response_Consumer : Collecting_Consumer;
               begin
                  Version.Transport.Http.Receive_Pack
                    (Url      => Url,
                     Request  => Request,
                     Consumer => Response_Consumer);

                  Parse_Report_Status
                    (Response_Bytes => Collected (Response_Consumer),
                     Ref_Name       => Ref_Name);
               end;
            exception
               when others =>
                  Delete_Push_Temporary_Pack
                    (Pack_Path  => Pack_Path,
                     Index_Path => Index_Path);
                  raise;
            end;

            Delete_Push_Temporary_Pack
              (Pack_Path  => Pack_Path,
               Index_Path => Index_Path);
         end;
      end;
   end Push_Tag;

   procedure Push_Tag_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Tag_Name    : String;
      Object_Id   : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False)
   is
      Capabilities      : constant String := Push_Capabilities (Repo);
      Ref_Name          : constant String := "refs/tags/" & Tag_Name;
      Stream            : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Unbounded_String;
      Buffer            : Stream_Element_Array (1 .. 8192);
      Last              : Stream_Element_Offset;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Tag_Name (Tag_Name);

      Version.Transport.Ssh.Open_Receive_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Unbounded.Index (Raw_Advertisement, "0000") /= 0;
      end loop;

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Advertisement (To_Stream (To_String (Raw_Advertisement)));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
         Old_Id         : constant String :=
           (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
      begin
         if Remote_Id_Text = To_String (Object_Id) then
            Version.Transport.Ssh.Close (Stream);
            return;  --  already up to date
         end if;

         if Remote_Id_Text'Length > 0 and then not Force then
            Version.Transport.Ssh.Close (Stream);
            raise Ada.IO_Exceptions.Data_Error
              with "cannot overwrite existing tag: " & Tag_Name;
         end if;

         declare
            Pack_Path  : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.pack");
            Index_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.idx");
            Objects    :
              constant Version.Objects.Object_Id_Vectors.Vector :=
                Version.History.Reachable_Objects
                  (Repo => Repo, Root_Id => Object_Id);
         begin
            Write_Push_Temporary_Pack
              (Repo       => Repo,
               Object_Ids => Objects,
               Pack_Path  => Pack_Path,
               Index_Path => Index_Path);

            begin
               declare
                  Request  : constant Stream_Element_Array :=
                    Build_Request_From_Pack_File
                      (Old_Id       => Old_Id,
                       New_Id       => To_String (Object_Id),
                       Ref_Name     => Ref_Name,
                       Capabilities => Capabilities,
                       Pack_Path    => Pack_Path);
                  Response : Unbounded_String;
               begin
                  Version.Transport.Ssh.Write (Stream, Request);

                  loop
                     Version.Transport.Ssh.Read_Some
                       (Stream => Stream, Buffer => Buffer, Last => Last);

                     exit when Last < Buffer'First;

                     Append
                       (Response,
                        To_String (Buffer (Buffer'First .. Last)));
                  end loop;

                  Version.Transport.Ssh.Close (Stream);

                  Parse_Report_Status
                    (Response_Bytes => To_Stream (To_String (Response)),
                     Ref_Name       => Ref_Name);
               end;
            exception
               when others =>
                  Delete_Push_Temporary_Pack
                    (Pack_Path  => Pack_Path,
                     Index_Path => Index_Path);
                  Version.Transport.Ssh.Close (Stream);
                  raise;
            end;

            Delete_Push_Temporary_Pack
              (Pack_Path  => Pack_Path,
               Index_Path => Index_Path);
         end;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Push_Tag_Ssh;

   --  A delete-only receive-pack request: just the command (new id = zero)
   --  and a flush; no pack data is sent.
   function Build_Delete_Request
     (Repo         : Version.Repository.Repository_Handle;
      Old_Id       : String;
      Ref_Name     : String;
      Capabilities : String) return Stream_Element_Array
   is
   begin
      return Build_Update_Command
               (Old_Id       => Old_Id,
                New_Id       => Null_Id (Repo),
                Ref_Name     => Ref_Name,
                Capabilities => Capabilities)
             & Version.Pkt_Line.Encode_Flush;
   end Build_Delete_Request;

   procedure Delete_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String)
   is
      Capabilities       : constant String :=
        (if Version.Repository.Algorithm (Repo) = Version.Hash.Sha256
         then "report-status agent=version object-format=sha256"
         else "report-status agent=version");
      Discovery_Consumer : Collecting_Consumer;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      Version.Transport.Http.Discover_Receive_Pack
        (Url => Url, Consumer => Discovery_Consumer);

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Discovery (Collected (Discovery_Consumer));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
      begin
         if Remote_Id_Text'Length = 0 then
            raise Ada.IO_Exceptions.Data_Error
              with "remote ref does not exist: " & Ref_Name;
         end if;

         declare
            Request           : constant Stream_Element_Array :=
              Build_Delete_Request
                (Repo         => Repo,
                 Old_Id       => Remote_Id_Text,
                 Ref_Name     => Ref_Name,
                 Capabilities => Capabilities);
            Response_Consumer : Collecting_Consumer;
         begin
            Version.Transport.Http.Receive_Pack
              (Url      => Url,
               Request  => Request,
               Consumer => Response_Consumer);

            Parse_Report_Status
              (Response_Bytes => Collected (Response_Consumer),
               Ref_Name       => Ref_Name);
         end;
      end;
   end Delete_Ref;

   procedure Delete_Ref_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String)
   is
      Capabilities      : constant String :=
        (if Version.Repository.Algorithm (Repo) = Version.Hash.Sha256
         then "report-status agent=version object-format=sha256"
         else "report-status agent=version");
      Stream            : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Unbounded_String;
      Buffer            : Stream_Element_Array (1 .. 8192);
      Last              : Stream_Element_Offset;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      Version.Transport.Ssh.Open_Receive_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Unbounded.Index (Raw_Advertisement, "0000") /= 0;
      end loop;

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Advertisement (To_Stream (To_String (Raw_Advertisement)));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
      begin
         if Remote_Id_Text'Length = 0 then
            Version.Transport.Ssh.Close (Stream);
            raise Ada.IO_Exceptions.Data_Error
              with "remote ref does not exist: " & Ref_Name;
         end if;

         declare
            Request  : constant Stream_Element_Array :=
              Build_Delete_Request
                (Repo         => Repo,
                 Old_Id       => Remote_Id_Text,
                 Ref_Name     => Ref_Name,
                 Capabilities => Capabilities);
            Response : Unbounded_String;
         begin
            Version.Transport.Ssh.Write (Stream, Request);

            loop
               Version.Transport.Ssh.Read_Some
                 (Stream => Stream, Buffer => Buffer, Last => Last);

               exit when Last < Buffer'First;

               Append
                 (Response,
                  To_String (Buffer (Buffer'First .. Last)));
            end loop;

            Version.Transport.Ssh.Close (Stream);

            Parse_Report_Status
              (Response_Bytes => To_Stream (To_String (Response)),
               Ref_Name       => Ref_Name);
         end;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Delete_Ref_Ssh;

   procedure Push_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String;
      New_Id      : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False)
   is
      Capabilities       : constant String := Push_Capabilities (Repo);
      Discovery_Consumer : Collecting_Consumer;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      Version.Transport.Http.Discover_Receive_Pack
        (Url => Url, Consumer => Discovery_Consumer);

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Discovery (Collected (Discovery_Consumer));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
         Old_Id         : constant String :=
           (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
      begin
         if Remote_Id_Text = To_String (New_Id) then
            return;  --  already up to date
         end if;

         if Remote_Id_Text'Length > 0 and then not Force then
            if not Version.History.Is_Ancestor
                     (Repo       => Repo,
                      Base_Id    =>
                        Version.Objects.To_Object_Id (Remote_Id_Text),
                      Derived_Id => New_Id)
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "cannot push: non-fast-forward update to " & Ref_Name;
            end if;
         end if;

         declare
            Pack_Path  : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.pack");
            Index_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.idx");
            Objects    :
              constant Version.Objects.Object_Id_Vectors.Vector :=
                Version.History.Reachable_Objects
                  (Repo => Repo, Root_Id => New_Id);
         begin
            Write_Push_Temporary_Pack
              (Repo       => Repo,
               Object_Ids => Objects,
               Pack_Path  => Pack_Path,
               Index_Path => Index_Path);

            begin
               declare
                  Request           : constant Stream_Element_Array :=
                    Build_Request_From_Pack_File
                      (Old_Id       => Old_Id,
                       New_Id       => To_String (New_Id),
                       Ref_Name     => Ref_Name,
                       Capabilities => Capabilities,
                       Pack_Path    => Pack_Path);
                  Response_Consumer : Collecting_Consumer;
               begin
                  Version.Transport.Http.Receive_Pack
                    (Url      => Url,
                     Request  => Request,
                     Consumer => Response_Consumer);

                  Parse_Report_Status
                    (Response_Bytes => Collected (Response_Consumer),
                     Ref_Name       => Ref_Name);
               end;
            exception
               when others =>
                  Delete_Push_Temporary_Pack
                    (Pack_Path  => Pack_Path,
                     Index_Path => Index_Path);
                  raise;
            end;

            Delete_Push_Temporary_Pack
              (Pack_Path  => Pack_Path,
               Index_Path => Index_Path);
         end;
      end;
   end Push_Ref;

   procedure Push_Ref_Ssh
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Url         : String;
      Ref_Name    : String;
      New_Id      : Version.Objects.Hex_Object_Id;
      Force       : Boolean := False)
   is
      Capabilities      : constant String := Push_Capabilities (Repo);
      Stream            : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Unbounded_String;
      Buffer            : Stream_Element_Array (1 .. 8192);
      Last              : Stream_Element_Offset;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      Version.Transport.Ssh.Open_Receive_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Unbounded.Index (Raw_Advertisement, "0000") /= 0;
      end loop;

      declare
         Discovery      : constant Discovery_Result :=
           Parse_Advertisement (To_Stream (To_String (Raw_Advertisement)));
         Remote_Id_Text : constant String :=
           Find_Remote_Ref (Discovery, Ref_Name);
         Old_Id         : constant String :=
           (if Remote_Id_Text'Length = 0 then Null_Id (Repo) else Remote_Id_Text);
      begin
         if Remote_Id_Text = To_String (New_Id) then
            Version.Transport.Ssh.Close (Stream);
            return;  --  already up to date
         end if;

         if Remote_Id_Text'Length > 0 and then not Force then
            if not Version.History.Is_Ancestor
                     (Repo       => Repo,
                      Base_Id    =>
                        Version.Objects.To_Object_Id (Remote_Id_Text),
                      Derived_Id => New_Id)
            then
               Version.Transport.Ssh.Close (Stream);
               raise Ada.IO_Exceptions.Data_Error
                 with "cannot push: non-fast-forward update to " & Ref_Name;
            end if;
         end if;

         declare
            Pack_Path  : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.pack");
            Index_Path : constant String :=
              Version.Files.Join
                (Version.Repository.Common_Git_Dir (Repo),
                 "objects/pack/version-push-temp.idx");
            Objects    :
              constant Version.Objects.Object_Id_Vectors.Vector :=
                Version.History.Reachable_Objects
                  (Repo => Repo, Root_Id => New_Id);
         begin
            Write_Push_Temporary_Pack
              (Repo       => Repo,
               Object_Ids => Objects,
               Pack_Path  => Pack_Path,
               Index_Path => Index_Path);

            begin
               declare
                  Request  : constant Stream_Element_Array :=
                    Build_Request_From_Pack_File
                      (Old_Id       => Old_Id,
                       New_Id       => To_String (New_Id),
                       Ref_Name     => Ref_Name,
                       Capabilities => Capabilities,
                       Pack_Path    => Pack_Path);
                  Response : Unbounded_String;
               begin
                  Version.Transport.Ssh.Write (Stream, Request);

                  loop
                     Version.Transport.Ssh.Read_Some
                       (Stream => Stream, Buffer => Buffer, Last => Last);

                     exit when Last < Buffer'First;

                     Append
                       (Response,
                        To_String (Buffer (Buffer'First .. Last)));
                  end loop;

                  Version.Transport.Ssh.Close (Stream);

                  Parse_Report_Status
                    (Response_Bytes => To_Stream (To_String (Response)),
                     Ref_Name       => Ref_Name);
               end;
            exception
               when others =>
                  Delete_Push_Temporary_Pack
                    (Pack_Path  => Pack_Path,
                     Index_Path => Index_Path);
                  Version.Transport.Ssh.Close (Stream);
                  raise;
            end;

            Delete_Push_Temporary_Pack
              (Pack_Path  => Pack_Path,
               Index_Path => Index_Path);
         end;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Push_Ref_Ssh;

end Version.Receive_Pack;
