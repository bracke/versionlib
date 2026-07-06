with Ada.IO_Exceptions;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Objects;
with Version.Pkt_Line;
with Version.Files;
with Version.Init;
with Version.Receive_Pack.Internal;
with Version.Ref_Transaction;
with Version.Repository;
with Version.Test_Support;

package body Version.Receive_Pack.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Ada.Streams;

   use type Version.Pkt_Line.Packet_Kind;
   use type Version.Pkt_Line.Parse_Status;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

   Main_Id : constant String :=
     "1111111111111111111111111111111111111111";
   Next_Id : constant String :=
     "2222222222222222222222222222222222222222";
   Zero_Id : constant String :=
     "0000000000000000000000000000000000000000";

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

   function Discovery_Stream
     (Capabilities : String := "report-status ofs-delta agent=git/2.0")
      return Stream_Element_Array
   is
      Service : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream ("# service=git-receive-pack" & LF));
      Flush_1 : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Main    : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (Main_Id & " refs/heads/main" & NUL & Capabilities & LF));
      Other   : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (Next_Id & " refs/heads/other" & LF));
      Flush_2 : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
   begin
      return Concat (Concat (Concat (Concat (Service, Flush_1), Main), Other), Flush_2);
   end Discovery_Stream;

   procedure Parses_Discovery_Refs_And_Capabilities
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Result : constant Version.Receive_Pack.Discovery_Result :=
        Version.Receive_Pack.Parse_Discovery (Discovery_Stream);
   begin
      Assert (Natural (Result.Refs.Length) = 2,
              "receive-pack discovery should expose advertised refs");
      Assert (To_String (Result.Refs.Element (0).Name) = "refs/heads/main",
              "first branch ref should be parsed");
      Assert (Result.Refs.Element (0).Id = Main_Id,
              "first branch id should be preserved");
      Assert (To_String (Result.Refs.Element (1).Name) = "refs/heads/other",
              "second branch ref should be parsed");
      Assert (Ada.Strings.Unbounded.Index (Result.Capabilities, "report-status") /= 0,
              "capabilities should include report-status");
   end Parses_Discovery_Refs_And_Capabilities;

   procedure Parses_Raw_Ssh_Advertisement
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Main : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream
             (Main_Id & " refs/heads/main" & NUL
              & "report-status ofs-delta agent=git/2.0" & LF));
      Other : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data
          (To_Stream (Next_Id & " refs/heads/other" & LF));
      Result : constant Version.Receive_Pack.Discovery_Result :=
        Version.Receive_Pack.Parse_Advertisement
          (Concat (Concat (Main, Other), Version.Pkt_Line.Encode_Flush));
   begin
      Assert
        (Natural (Result.Refs.Length) = 2,
         "raw receive-pack advertisement should expose advertised refs");
      Assert
        (To_String (Result.Refs.Element (0).Name) = "refs/heads/main",
         "raw first branch ref should be parsed");
      Assert
        (Result.Refs.Element (0).Id = Main_Id,
         "raw first branch id should be preserved");
      Assert
        (Ada.Strings.Unbounded.Index (Result.Capabilities, "report-status") /= 0,
         "raw capabilities should include report-status");
   end Parses_Raw_Ssh_Advertisement;

   procedure Rejects_Discovery_Without_Report_Status
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         declare
            Result : constant Version.Receive_Pack.Discovery_Result :=
              Version.Receive_Pack.Parse_Discovery
                (Discovery_Stream ("ofs-delta agent=git/2.0"));
            pragma Unreferenced (Result);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "missing report-status capability must be rejected");
   end Rejects_Discovery_Without_Report_Status;

   procedure Builds_Update_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Receive_Pack.Build_Update_Command
          (Old_Id       => Main_Id,
           New_Id       => Next_Id,
           Ref_Name     => "refs/heads/main",
           Capabilities => "report-status ofs-delta agent=version");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "receive-pack command should parse");
      Assert (Kind = Version.Pkt_Line.Data_Packet, "receive-pack command should be data");
      Assert
        (To_String (Payload (Payload'First .. Last)) =
           Main_Id & " " & Next_Id & " refs/heads/main" & NUL
           & "report-status ofs-delta agent=version" & LF,
         "receive-pack update command should preserve ids, ref, and capabilities");
   end Builds_Update_Request;

   procedure Builds_Create_Request_With_Zero_Old_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Receive_Pack.Build_Update_Command
          (Old_Id       => Zero_Id,
           New_Id       => Next_Id,
           Ref_Name     => "refs/heads/new",
           Capabilities => "report-status agent=version");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "create command should parse");
      Assert
        (To_String (Payload (Payload'First .. Last)) =
           Zero_Id & " " & Next_Id & " refs/heads/new" & NUL
           & "report-status agent=version" & LF,
         "branch creation command should use all-zero old id");
   end Builds_Create_Request_With_Zero_Old_Id;

   procedure Builds_Tag_Update_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Receive_Pack.Build_Update_Command
          (Old_Id       => Zero_Id,
           New_Id       => Next_Id,
           Ref_Name     => "refs/tags/v1",
           Capabilities => "report-status agent=version");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "tag command should parse");
      Assert
        (To_String (Payload (Payload'First .. Last)) =
           Zero_Id & " " & Next_Id & " refs/tags/v1" & NUL
           & "report-status agent=version" & LF,
         "tag update command should target refs/tags/");
   end Builds_Tag_Update_Request;

   procedure Builds_Delete_Request_With_Zero_New_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Request : constant Stream_Element_Array :=
        Version.Receive_Pack.Build_Update_Command
          (Old_Id       => Main_Id,
           New_Id       => Zero_Id,
           Ref_Name     => "refs/heads/stale",
           Capabilities => "report-status agent=version");
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Parser, Request);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);

      Assert (Status = Version.Pkt_Line.Ok, "delete command should parse");
      Assert
        (To_String (Payload (Payload'First .. Last)) =
           Main_Id & " " & Zero_Id & " refs/heads/stale" & NUL
           & "report-status agent=version" & LF,
         "delete command should use all-zero new id");
   end Builds_Delete_Request_With_Zero_New_Id;

   procedure Request_Appends_Flush_And_Pack_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Pack : constant Stream_Element_Array :=
        [1 => Stream_Element (Character'Pos ('P')),
         2 => Stream_Element (Character'Pos ('A')),
         3 => Stream_Element (Character'Pos ('C')),
         4 => Stream_Element (Character'Pos ('K')),
         5 => 0,
         6 => 255];
      Request : constant Stream_Element_Array :=
        Version.Receive_Pack.Build_Request
          (Old_Id       => Main_Id,
           New_Id       => Next_Id,
           Ref_Name     => "refs/heads/main",
           Capabilities => "report-status agent=version",
           Pack         => Pack);
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Payload : Stream_Element_Array (1 .. 256);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
      Pack_Start : Stream_Element_Offset;
   begin
      Version.Pkt_Line.Feed (Parser, Request);
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok and then Kind = Version.Pkt_Line.Data_Packet,
              "request should begin with command pkt-line");
      Status := Version.Pkt_Line.Next (Parser, Kind, Payload, Last);
      Assert (Status = Version.Pkt_Line.Ok and then Kind = Version.Pkt_Line.Flush_Packet,
              "command should be followed by flush pkt-line");

      Pack_Start := Request'Last - Stream_Element_Offset (Pack'Length) + 1;
      Assert (Request (Pack_Start .. Request'Last) = Pack,
              "raw pack bytes should be appended exactly after flush");
   end Request_Appends_Flush_And_Pack_Bytes;

   procedure Request_From_Pack_File_Matches_In_Memory_Request
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Pack_Path : constant String := Version.Files.Join (Root, "receive-pack-test.pack");
      Pack : constant Stream_Element_Array :=
        [1 => Stream_Element (Character'Pos ('P')),
         2 => Stream_Element (Character'Pos ('A')),
         3 => Stream_Element (Character'Pos ('C')),
         4 => Stream_Element (Character'Pos ('K')),
         5 => 16#00#,
         6 => 16#00#,
         7 => 16#00#,
         8 => 16#02#,
         9 => 16#FF#,
         10 => 16#42#];
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File,
         Ada.Streams.Stream_IO.Out_File,
         Version.Files.To_Native_Path (Pack_Path));
      Ada.Streams.Stream_IO.Write (File, Pack);
      Ada.Streams.Stream_IO.Close (File);

      declare
         From_Memory : constant Stream_Element_Array :=
           Version.Receive_Pack.Build_Request
             (Old_Id       => Main_Id,
              New_Id       => Next_Id,
              Ref_Name     => "refs/heads/main",
              Capabilities => "report-status agent=version",
              Pack         => Pack);
         From_File : constant Stream_Element_Array :=
           Version.Receive_Pack.Build_Request_From_Pack_File
             (Old_Id       => Main_Id,
              New_Id       => Next_Id,
              Ref_Name     => "refs/heads/main",
              Capabilities => "report-status agent=version",
              Pack_Path    => Pack_Path);
      begin
         Assert (From_File = From_Memory,
                 "file-backed receive-pack request must match in-memory request");
      end;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         raise;
   end Request_From_Pack_File_Matches_In_Memory_Request;

   function Report_Status_Stream
     (Text : String)
      return Stream_Element_Array
   is
      Line  : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Text));
      Flush : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
   begin
      return Concat (Line, Flush);
   end Report_Status_Stream;

   function Report_Status_Two_Lines
     (A : String;
      B : String)
      return Stream_Element_Array
   is
   begin
      return Concat
        (Concat
           (Version.Pkt_Line.Encode_Data (To_Stream (A)),
            Version.Pkt_Line.Encode_Data (To_Stream (B))),
         Version.Pkt_Line.Encode_Flush);
   end Report_Status_Two_Lines;

   procedure Parses_Report_Status_Success
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Version.Receive_Pack.Parse_Report_Status
        (Response_Bytes =>
           Report_Status_Two_Lines
             ("unpack ok" & LF,
              "ok refs/heads/main" & LF),
         Ref_Name => "refs/heads/main");
   end Parses_Report_Status_Success;

   procedure Parses_Combined_Report_Status_Payload
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Version.Receive_Pack.Parse_Report_Status
        (Response_Bytes =>
           Report_Status_Stream
             ("unpack ok" & LF & "ok refs/heads/main" & LF),
         Ref_Name => "refs/heads/main");
   end Parses_Combined_Report_Status_Payload;

   procedure Parses_Sideband_Report_Status_Success
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Version.Receive_Pack.Parse_Report_Status
        (Response_Bytes =>
           Report_Status_Two_Lines
             (Character'Val (2) & "counting objects" & LF,
              Character'Val (1)
              & "unpack ok" & LF & "ok refs/heads/main" & LF),
         Ref_Name => "refs/heads/main");
   end Parses_Sideband_Report_Status_Success;

   procedure Parses_Leading_Flush_Report_Status
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Version.Receive_Pack.Parse_Report_Status
        (Response_Bytes =>
           Concat
             (Version.Pkt_Line.Encode_Flush,
              Report_Status_Two_Lines
                ("unpack ok" & LF,
                 "ok refs/heads/main" & LF)),
         Ref_Name => "refs/heads/main");
   end Parses_Leading_Flush_Report_Status;

   procedure Rejects_Missing_Ref_Ok
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Receive_Pack.Parse_Report_Status
           (Response_Bytes => Report_Status_Stream ("unpack ok" & LF),
            Ref_Name       => "refs/heads/main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "missing ok ref status should raise Data_Error");
   end Rejects_Missing_Ref_Ok;

   procedure Rejects_Unpack_Failure
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Receive_Pack.Parse_Report_Status
           (Response_Bytes => Report_Status_Stream ("unpack corrupt pack" & LF),
            Ref_Name       => "refs/heads/main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "unpack failure should raise Data_Error");
   end Rejects_Unpack_Failure;

   procedure Rejects_Ref_Ng
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         Version.Receive_Pack.Parse_Report_Status
           (Response_Bytes =>
              Report_Status_Two_Lines
                ("unpack ok" & LF,
                 "ng refs/heads/main non-fast-forward" & LF),
            Ref_Name => "refs/heads/main");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "ng ref status should raise Data_Error");
   end Rejects_Ref_Ng;

   procedure Remote_Tracking_Update_Rejects_Expected_Old_Mismatch
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo_Path : constant String := Version.Files.Join (Root, "tracking-mismatch");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Tracking_Dir : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Repo_Path, ".git"), "refs"),
              "remotes"),
           "origin");
      Tracking_Ref : constant String := Version.Files.Join (Tracking_Dir, "main");
      Expected_Id : constant String := "1111111111111111111111111111111111111111";
      Actual_Id   : constant String := "2222222222222222222222222222222222222222";
      New_Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("3333333333333333333333333333333333333333");
      Raised : Boolean := False;
   begin
      Ada.Directories.Create_Directory (Repo_Path);
      Version.Init.Init (Repo_Path);
      Ada.Directories.Create_Path (Tracking_Dir);
      Version.Test_Support.Write_Text_File (Tracking_Ref, Actual_Id);

      Ada.Directories.Set_Directory (Repo_Path);

      begin
         Version.Receive_Pack.Internal.Update_Remote_Tracking_Ref
           (Repo         => Version.Repository.Open,
            Remote_Name  => "origin",
            Branch_Name  => "main",
            Commit_Id    => New_Id,
            Expected_Old => Expected_Id);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Ref_Transaction.Expected_Old_Mismatch_Diagnostic
                   ("refs/remotes/origin/main"),
               "receive-pack stale tracking diagnostic changed: "
               & Ada.Exceptions.Exception_Message (E));
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "stale remote-tracking ref must be rejected");
      Assert
        (Version.Test_Support.Read_Text_File (Tracking_Ref) = Actual_Id,
         "stale receive-pack tracking update must preserve existing ref");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Remote_Tracking_Update_Rejects_Expected_Old_Mismatch;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Parses_Discovery_Refs_And_Capabilities'Access,
         "Receive_Pack: parses discovery refs and capabilities");
      Register_Routine
        (T,
         Parses_Raw_Ssh_Advertisement'Access,
         "Receive_Pack: parses raw SSH advertisement refs and capabilities");
      Register_Routine
        (T,
         Rejects_Discovery_Without_Report_Status'Access,
         "Receive_Pack: rejects discovery without report-status");
      Register_Routine
        (T,
         Builds_Update_Request'Access,
         "Receive_Pack: builds branch update command");
      Register_Routine
        (T,
         Builds_Create_Request_With_Zero_Old_Id'Access,
         "Receive_Pack: builds branch create command");
      Register_Routine
        (T,
         Builds_Tag_Update_Request'Access,
         "Receive_Pack: builds tag update command (refs/tags/)");
      Register_Routine
        (T,
         Builds_Delete_Request_With_Zero_New_Id'Access,
         "Receive_Pack: builds delete command (zero new id)");
      Register_Routine
        (T,
         Request_Appends_Flush_And_Pack_Bytes'Access,
         "Receive_Pack: request appends flush and pack bytes");
      Register_Routine
        (T,
         Request_From_Pack_File_Matches_In_Memory_Request'Access,
         "Receive_Pack: file-backed request matches in-memory request");
      Register_Routine
        (T,
         Remote_Tracking_Update_Rejects_Expected_Old_Mismatch'Access,
         "Receive_Pack: rejects stale remote-tracking update");
      Register_Routine
        (T,
         Parses_Report_Status_Success'Access,
         "Receive_Pack: parses report-status success");
      Register_Routine
        (T,
         Parses_Combined_Report_Status_Payload'Access,
         "Receive_Pack: parses combined report-status payload");

      Register_Routine
        (T,
         Parses_Sideband_Report_Status_Success'Access,
         "Receive_Pack: parses sideband report-status success");

      Register_Routine
        (T,
         Parses_Leading_Flush_Report_Status'Access,
         "Receive_Pack: parses leading-flush report-status success");
      Register_Routine
        (T,
         Rejects_Missing_Ref_Ok'Access,
         "Receive_Pack: rejects missing ref ok status");
      Register_Routine
        (T,
         Rejects_Unpack_Failure'Access,
         "Receive_Pack: rejects unpack failure");
      Register_Routine
        (T,
         Rejects_Ref_Ng'Access,
         "Receive_Pack: rejects ref ng failure");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Receive_Pack");
   end Name;

end Version.Receive_Pack.Tests;
