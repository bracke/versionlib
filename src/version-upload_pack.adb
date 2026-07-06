with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Version.Pkt_Line;

package body Version.Upload_Pack is
   use Version.Objects;

   use Ada.Streams;

   use type Version.Pkt_Line.Packet_Kind;
   use type Version.Pkt_Line.Parse_Status;

   LF  : constant Character := Character'Val (10);
   NUL : constant Character := Character'Val (0);

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

   function Capability_Value
     (Capabilities : String; Name : String) return String
   is
      Prefix : constant String := Name & "=";
      Start  : Natural := Capabilities'First;
   begin
      if Capabilities'Length = 0 then
         return "";
      end if;

      while Start <= Capabilities'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Capabilities'Last and then Capabilities (Stop) /= ' '
            loop
               Stop := Stop + 1;
            end loop;

            declare
               Token : constant String := Capabilities (Start .. Stop - 1);
            begin
               if Starts_With (Token, Prefix) then
                  return Token (Token'First + Prefix'Length .. Token'Last);
               end if;
            end;

            Start := Stop + 1;
         end;
      end loop;

      return "";
   end Capability_Value;

   function Advertised_Object_Format
     (Capabilities : String)
      return Version.Hash.Hash_Algorithm is
     (if Capability_Value (Capabilities, "object-format") = "sha256"
      then Version.Hash.Sha256
      else Version.Hash.Sha1);

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
                 with "malformed upload-pack advertised ref separator";
            end if;

            declare
               Id_Text : constant String :=
                 Ref_Text (Ref_Text'First .. Sep - 1);
               Name    : constant String :=
                 Ref_Text (Sep + 1 .. Ref_Text'Last);
            begin
               if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                  raise Ada.IO_Exceptions.Data_Error
                    with "invalid upload-pack advertised object id";
               end if;

               Result.Refs.Append
                 (Advertised_Ref'(Name => To_Unbounded_String (Name),
                                  Id   => To_Object_Id (Id_Text)));
            end;
         end;
      end;
   end Append_Advertised_Ref;

   procedure Extract_Head_Target (Result : in out Discovery_Result) is
      Symref : constant String :=
        Capability_Value (To_String (Result.Capabilities), "symref");
      Prefix : constant String := "HEAD:";
   begin
      if Starts_With (Symref, Prefix) then
         Result.Head_Target :=
           To_Unbounded_String
             (Symref (Symref'First + Prefix'Length .. Symref'Last));
      end if;
   end Extract_Head_Target;

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
                 with "malformed upload-pack advertisement pkt-line";
         end case;

         if Kind = Version.Pkt_Line.Flush_Packet then
            exit;

         elsif Kind = Version.Pkt_Line.Data_Packet then
            if Last < Buffer'First then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty upload-pack advertised ref";
            end if;

            Append_Advertised_Ref
              (Result  => Result,
               Payload => To_String (Buffer (Buffer'First .. Last)),
               First   => First_Ref);
            First_Ref := False;
            Saw_Ref := True;

         else
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected upload-pack advertisement packet kind";
         end if;
      end loop;

      if not Saw_Ref then
         raise Ada.IO_Exceptions.Data_Error
           with "empty upload-pack advertisement";
      end if;

      Extract_Head_Target (Result);
      return Result;
   end Parse_Advertisement;

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
                 with "malformed upload-pack discovery pkt-line";
         end case;

         if not Saw_Service then
            if Kind /= Version.Pkt_Line.Data_Packet or else Last < Buffer'First
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "upload-pack discovery missing service header";
            end if;

            declare
               Service : constant String :=
                 To_String (Buffer (Buffer'First .. Last));
            begin
               if Trim_LF (Service) /= "# service=git-upload-pack" then
                  raise Ada.IO_Exceptions.Data_Error
                    with "unexpected upload-pack discovery service header";
               end if;
            end;

            Saw_Service := True;

         elsif not Saw_Service_Flush then
            if Kind /= Version.Pkt_Line.Flush_Packet then
               raise Ada.IO_Exceptions.Data_Error
                 with "upload-pack discovery missing service flush";
            end if;

            Saw_Service_Flush := True;

         elsif Kind = Version.Pkt_Line.Flush_Packet then
            exit;

         elsif Kind = Version.Pkt_Line.Data_Packet then
            if Last < Buffer'First then
               raise Ada.IO_Exceptions.Data_Error
                 with "empty upload-pack advertised ref";
            end if;

            Append_Advertised_Ref
              (Result  => Result,
               Payload => To_String (Buffer (Buffer'First .. Last)),
               First   => First_Ref);
            First_Ref := False;

         else
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected upload-pack discovery packet kind";
         end if;
      end loop;

      if not Saw_Service or else not Saw_Service_Flush then
         raise Ada.IO_Exceptions.Data_Error
           with "incomplete upload-pack discovery";
      end if;

      Extract_Head_Target (Result);
      return Result;
   end Parse_Discovery;

   function Is_Branch_Ref (Name : String) return Boolean is
      Prefix : constant String := "refs/heads/";
   begin
      return
        Name'Length > Prefix'Length
        and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix;
   end Is_Branch_Ref;

   function Branch_Name (Ref_Name : String) return String is
      Prefix : constant String := "refs/heads/";
   begin
      return Ref_Name (Ref_Name'First + Prefix'Length .. Ref_Name'Last);
   end Branch_Name;

   function Branch_Rank (Branch : String) return Natural is
   begin
      if Branch = "main" then
         return 0;
      elsif Branch = "master" then
         return 1;
      else
         return 2;
      end if;
   end Branch_Rank;

   function Prefer_Branch (Candidate : String; Current : String) return Boolean
   is
      Candidate_Rank : constant Natural := Branch_Rank (Candidate);
      Current_Rank   : constant Natural := Branch_Rank (Current);
   begin
      if Current'Length = 0 then
         return True;
      elsif Candidate_Rank < Current_Rank then
         return True;
      elsif Candidate_Rank > Current_Rank then
         return False;
      else
         return Candidate < Current;
      end if;
   end Prefer_Branch;

   function Default_Branch_From_Advertisements
     (Refs : Advertised_Ref_Vectors.Vector) return String
   is
      Head_Id         : Version.Objects.Hex_Object_Id :=
        Version.Objects.Zero_Object_Id;
      Have_Head       : Boolean := False;
      Branch_Count    : Natural := 0;
      Head_Matches    : Natural := 0;
      Only_Head_Match : Unbounded_String;
      Preferred_Head  : Unbounded_String;
      Fallback        : Unbounded_String;
   begin
      if not Refs.Is_Empty then
         for I in Refs.First_Index .. Refs.Last_Index loop
            if To_String (Refs.Element (I).Name) = "HEAD" then
               Head_Id := Refs.Element (I).Id;
               Have_Head := True;
               exit;
            end if;
         end loop;

         for I in Refs.First_Index .. Refs.Last_Index loop
            declare
               Ref_Name : constant String := To_String (Refs.Element (I).Name);
            begin
               if Is_Branch_Ref (Ref_Name) then
                  declare
                     Short : constant String := Branch_Name (Ref_Name);
                  begin
                     Branch_Count := Branch_Count + 1;

                     if Prefer_Branch (Short, To_String (Fallback)) then
                        Fallback := To_Unbounded_String (Short);
                     end if;

                     if Have_Head and then Refs.Element (I).Id = Head_Id then
                        Head_Matches := Head_Matches + 1;
                        Only_Head_Match := To_Unbounded_String (Short);

                        if Prefer_Branch (Short, To_String (Preferred_Head))
                        then
                           Preferred_Head := To_Unbounded_String (Short);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end if;

      if Branch_Count = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "upload-pack discovery advertised no branch refs";
      end if;

      if Have_Head and then Head_Matches = 1 then
         return To_String (Only_Head_Match);
      elsif Have_Head and then Head_Matches > 1 then
         return To_String (Preferred_Head);
      else
         return To_String (Fallback);
      end if;
   end Default_Branch_From_Advertisements;

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Include_Tag : Boolean := False) return Stream_Element_Array
   is
      Capabilities : constant String :=
        "side-band-64k ofs-delta"
        & (if Include_Tag then " include-tag" else "")
        & " agent=version";

      Want_Line : constant String :=
        "want "
        & To_String (Want_Id)
        & " " & Capabilities
        & LF;

      Done_Line : constant String := "done" & LF;

      Want  : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Want_Line));
      Flush : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Done  : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Done_Line));

      Result :
        Stream_Element_Array
          (1
           ..
             Stream_Element_Offset (Want'Length + Flush'Length + Done'Length));
      Pos    : Stream_Element_Offset := Result'First;
   begin
      for I in Want'Range loop
         Result (Pos) := Want (I);
         Pos := Pos + 1;
      end loop;

      for I in Flush'Range loop
         Result (Pos) := Flush (I);
         Pos := Pos + 1;
      end loop;

      for I in Done'Range loop
         Result (Pos) := Done (I);
         Pos := Pos + 1;
      end loop;

      return Result;
   end Build_Want_Request;

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Filter_Spec : String;
      Include_Tag : Boolean := False) return Stream_Element_Array
   is
      Capabilities : constant String :=
        "side-band-64k ofs-delta"
        & (if Include_Tag then " include-tag" else "")
        & " agent=version";

      Want_Line : constant String :=
        "want "
        & To_String (Want_Id)
        & " " & Capabilities
        & LF;

      Filter_Line : constant String := "filter " & Filter_Spec & LF;
      Done_Line   : constant String := "done" & LF;

      Want   : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Want_Line));
      Filter : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Filter_Line));
      Flush  : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Done   : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Done_Line));

      Result :
        Stream_Element_Array
          (1
           ..
             Stream_Element_Offset
               (Want'Length + Filter'Length + Flush'Length + Done'Length));
      Pos    : Stream_Element_Offset := Result'First;
   begin
      for I in Want'Range loop
         Result (Pos) := Want (I);
         Pos := Pos + 1;
      end loop;

      for I in Filter'Range loop
         Result (Pos) := Filter (I);
         Pos := Pos + 1;
      end loop;

      for I in Flush'Range loop
         Result (Pos) := Flush (I);
         Pos := Pos + 1;
      end loop;

      for I in Done'Range loop
         Result (Pos) := Done (I);
         Pos := Pos + 1;
      end loop;

      return Result;
   end Build_Want_Request;

   function Build_Want_Request
     (Want_Id     : Version.Objects.Hex_Object_Id;
      Depth       : Positive;
      Include_Tag : Boolean := False)
      return Stream_Element_Array
   is
      Depth_Text : constant String :=
        Ada.Strings.Fixed.Trim (Positive'Image (Depth), Ada.Strings.Both);

      Capabilities : constant String :=
        "side-band-64k ofs-delta"
        & (if Include_Tag then " include-tag" else "")
        & " agent=version";

      Want_Line : constant String :=
        "want "
        & To_String (Want_Id)
        & " " & Capabilities
        & LF;

      Deepen_Line : constant String := "deepen " & Depth_Text & LF;
      Done_Line   : constant String := "done" & LF;

      Want   : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Want_Line));
      Deepen : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Deepen_Line));
      Flush  : constant Stream_Element_Array := Version.Pkt_Line.Encode_Flush;
      Done   : constant Stream_Element_Array :=
        Version.Pkt_Line.Encode_Data (To_Stream (Done_Line));

      Result :
        Stream_Element_Array
          (1
           ..
             Stream_Element_Offset
               (Want'Length + Deepen'Length + Flush'Length + Done'Length));
      Pos    : Stream_Element_Offset := Result'First;
   begin
      for I in Want'Range loop
         Result (Pos) := Want (I);
         Pos := Pos + 1;
      end loop;

      for I in Deepen'Range loop
         Result (Pos) := Deepen (I);
         Pos := Pos + 1;
      end loop;

      for I in Flush'Range loop
         Result (Pos) := Flush (I);
         Pos := Pos + 1;
      end loop;

      for I in Done'Range loop
         Result (Pos) := Done (I);
         Pos := Pos + 1;
      end loop;

      return Result;
   end Build_Want_Request;

   procedure Append_Update
     (Items : in out Version.Objects.Object_Id_Vectors.Vector;
      Id    : Version.Objects.Hex_Object_Id) is
   begin
      if Items.Is_Empty then
         Items.Append (Id);
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if Items.Element (I) = Id then
            return;
         end if;
      end loop;

      Items.Append (Id);
   end Append_Update;

   procedure Parse_Shallow_Line
     (Payload : String; Update : in out Shallow_Update; Matched : out Boolean)
   is
      Clean            : constant String := Trim_LF (Payload);
      Shallow_Prefix   : constant String := "shallow ";
      Unshallow_Prefix : constant String := "unshallow ";
   begin
      Matched := False;

      if Starts_With (Clean, Shallow_Prefix) then
         declare
            Id_Text : constant String :=
              Clean (Clean'First + Shallow_Prefix'Length .. Clean'Last);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "invalid shallow response object id";
            end if;
            Append_Update
              (Update.Shallow, Version.Objects.To_Object_Id (Id_Text));
            Matched := True;
         end;
      elsif Starts_With (Clean, Unshallow_Prefix) then
         declare
            Id_Text : constant String :=
              Clean (Clean'First + Unshallow_Prefix'Length .. Clean'Last);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "invalid unshallow response object id";
            end if;
            Append_Update
              (Update.Unshallow, Version.Objects.To_Object_Id (Id_Text));
            Matched := True;
         end;
      end if;
   end Parse_Shallow_Line;

   function Parse_Shallow_Update
     (Data : Stream_Element_Array) return Shallow_Update
   is
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Buffer  : Stream_Element_Array (1 .. 65_520);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
      Result  : Shallow_Update;
      Matched : Boolean;
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
                 with "malformed upload-pack shallow response pkt-line";
         end case;

         if Kind = Version.Pkt_Line.Data_Packet and then Last >= Buffer'First
         then
            Parse_Shallow_Line
              (Payload => To_String (Buffer (Buffer'First .. Last)),
               Update  => Result,
               Matched => Matched);
         end if;
      end loop;

      return Result;
   end Parse_Shallow_Update;

   procedure Demux_Response
     (Data     : Stream_Element_Array;
      Consumer : in out Version.Transport.Http.Byte_Consumer'Class;
      Update   : out Shallow_Update)
   is
      Parser  : Version.Pkt_Line.Parser;
      Kind    : Version.Pkt_Line.Packet_Kind;
      Buffer  : Stream_Element_Array (1 .. 65_520);
      Last    : Stream_Element_Offset;
      Status  : Version.Pkt_Line.Parse_Status;
      Matched : Boolean;
   begin
      Update.Shallow.Clear;
      Update.Unshallow.Clear;
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
                 with "malformed upload-pack response pkt-line";
         end case;

         if Kind = Version.Pkt_Line.Flush_Packet then
            null;

         elsif Kind /= Version.Pkt_Line.Data_Packet then
            raise Ada.IO_Exceptions.Data_Error
              with "unexpected upload-pack response packet kind";

         elsif Last < Buffer'First then
            raise Ada.IO_Exceptions.Data_Error
              with "empty upload-pack response packet";

         else
            declare
               Payload : constant String :=
                 To_String (Buffer (Buffer'First .. Last));
            begin
               Parse_Shallow_Line (Payload, Update, Matched);

               if Matched then
                  null;
               elsif Payload = "NAK" & LF
                 or else Starts_With (Trim_LF (Payload), "ACK ")
               then
                  null;
               else
                  declare
                     Channel : constant Natural :=
                       Natural (Buffer (Buffer'First));
                  begin
                     case Channel is
                        when 1      =>
                           if Last > Buffer'First then
                              Consumer.Consume
                                (Buffer (Buffer'First + 1 .. Last));
                           end if;

                        when 2      =>
                           null;

                        when 3      =>
                           if Last > Buffer'First then
                              raise Ada.IO_Exceptions.Data_Error
                                with
                                  "upload-pack fatal: "
                                  & To_String
                                      (Buffer (Buffer'First + 1 .. Last));
                           else
                              raise Ada.IO_Exceptions.Data_Error
                                with "upload-pack fatal";
                           end if;

                        when others =>
                           raise Ada.IO_Exceptions.Data_Error
                             with "unknown upload-pack sideband channel";
                     end case;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Demux_Response;

   procedure Demux_Response
     (Data     : Stream_Element_Array;
      Consumer : in out Version.Transport.Http.Byte_Consumer'Class)
   is
      Ignored : Shallow_Update;
   begin
      Demux_Response (Data, Consumer, Ignored);
   end Demux_Response;

end Version.Upload_Pack;
