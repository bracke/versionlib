with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with GNAT.OS_Lib;
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;

with Version.Files;
with Version.Fetch.Internal;
with Version.Config;
with Version.Objects; use Version.Objects;
with Version.Transport;
with Version.Transport.Http;
with Version.Transport.Local;
with Version.Transport.Ssh;
with Version.Upload_Pack;
with Version.Write;
with Version.History;
with Version.Pack;
with Version.Packed_Refs;
with Version.Repository_Format;
with Version.Pkt_Line; use Version.Pkt_Line;
with Version.Ref_Transaction;
with Version.Ref_Names;
with Version.Shallow;
with Version.Unsupported;
with Version.Availability;

package body Version.Fetch is

   use Ada.Strings.Unbounded;

   package Object_Id_Sets is new
     Ada.Containers.Ordered_Sets
       (Element_Type => Version.Objects.Object_Id_Storage);

   function Invalid_Packed_Ref_Line_Diagnostic return String is
   begin
      return "invalid packed ref line";
   end Invalid_Packed_Ref_Line_Diagnostic;

   function Invalid_Loose_Tag_Object_Id_Diagnostic return String is
   begin
      return "invalid loose tag object id";
   end Invalid_Loose_Tag_Object_Id_Diagnostic;

   function Invalid_Loose_Branch_Object_Id_Diagnostic return String is
   begin
      return "invalid loose branch object id";
   end Invalid_Loose_Branch_Object_Id_Diagnostic;

   function Invalid_Packed_Tag_Object_Id_Diagnostic return String is
   begin
      return "invalid packed tag object id";
   end Invalid_Packed_Tag_Object_Id_Diagnostic;

   function Invalid_Packed_Branch_Object_Id_Diagnostic return String is
   begin
      return "invalid packed branch object id";
   end Invalid_Packed_Branch_Object_Id_Diagnostic;

   type Ref_Update is record
      Name      : Unbounded_String;
      Object_Id : Version.Objects.Object_Id_Storage;
   end record;

   package Ref_Update_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Ref_Update);

   procedure Apply_Ref_Updates (Updates : Ref_Update_Vectors.Vector) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Tx   : Version.Ref_Transaction.Transaction;
   begin
      if Updates.Is_Empty then
         return;
      end if;

      Version.Ref_Transaction.Start (Tx, Repo);

      for I in Updates.First_Index .. Updates.Last_Index loop
         declare
            Update : constant Ref_Update := Updates.Element (I);
         begin
            Version.Fetch.Internal.Add_Update_With_Current_Old
              (Tx       => Tx,
               Repo     => Repo,
               Ref_Name => To_String (Update.Name),
               New_Id   => Update.Object_Id);
         end;
      end loop;

      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Apply_Ref_Updates;

   function Remote_Url
     (Repo : Version.Repository.Repository_Handle;
      Name : String)
      return String
   is
      Items : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);
      Section_Name : constant String := "remote """ & Name & """";
   begin
      Version.Ref_Names.Require_Remote_Name (Name);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry := Items.Element (I);
            begin
               if To_String (Item.Section) = Section_Name
                 and then To_String (Item.Key) = "url"
               then
                  return To_String (Item.Value);
               end if;
            end;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error with
        Version.Availability.No_Remote_Configured (Name);
   end Remote_Url;

   function Remote_Url
     (Name : String)
      return String
   is
   begin
      return Remote_Url (Version.Repository.Open, Name);
   end Remote_Url;

   procedure Validate_Local_Head_Updates
     (Updates : Ref_Update_Vectors.Vector)
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if Updates.Is_Empty then
         return;
      end if;

      for I in Updates.First_Index .. Updates.Last_Index loop
         declare
            Update : constant Ref_Update := Updates.Element (I);
            Name   : constant String := To_String (Update.Name);
         begin
            if Ada.Strings.Fixed.Index (Name, "refs/remotes/") = 1 then
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Objects.Read_Object (Repo, Update.Object_Id);
               begin
                  if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
                     raise Ada.IO_Exceptions.Data_Error
                       with "fetched branch object is not a commit";
                  end if;
               exception
                  when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
                     raise Ada.IO_Exceptions.Data_Error
                       with "fetched branch object is unavailable or corrupt";
               end;
            end if;
         end;
      end loop;
   end Validate_Local_Head_Updates;

   function Remote_Git_Dir_For
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String) return String
   is
      Url : constant String := Remote_Url (Repo, Remote_Name);
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport       =>
            return
              Version.Transport.Local.Resolve_Git_Dir
                (Version.Transport.Strip_File_Scheme (Url));

         when Version.Transport.Http_Transport        =>
            raise Ada.IO_Exceptions.Use_Error
              with "HTTP transport does not have a local .git directory";

         when Version.Transport.Ssh_Transport         =>
            raise Ada.IO_Exceptions.Use_Error
              with "SSH transport does not have a local .git directory";

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with Version.Unsupported.Remote_Url;
      end case;
   end Remote_Git_Dir_For;

   procedure Collect_Remote_Tag_Refs
     (Remote_Git_Dir : String;
      Local_Git_Dir  : String;
      Updates        : in out Ref_Update_Vectors.Vector)
   is
      Remote_Tags : constant String :=
        Version.Files.Join (Remote_Git_Dir, "refs/tags");

      pragma Unreferenced (Local_Git_Dir);
      procedure Copy_Tags_In_Directory (Source_Dir : String; Prefix : String)
      is
         Search   : Ada.Directories.Search_Type;
         Dir_Item : Ada.Directories.Directory_Entry_Type;
         Opened   : Boolean := False;
      begin
         if not Ada.Directories.Exists (Source_Dir) then
            return;
         end if;

         Ada.Directories.Start_Search
           (Search    => Search,
            Directory => Source_Dir,
            Pattern   => "*",
            Filter    =>
              [Ada.Directories.Ordinary_File => True,
               Ada.Directories.Directory     => True,
               Ada.Directories.Special_File  => True]);

         Opened := True;

         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Item);

            declare
               Name : constant String :=
                 Ada.Directories.Simple_Name (Dir_Item);

               Source_Path : constant String :=
                 Ada.Directories.Full_Name (Dir_Item);

               Ref_Name : constant String :=
                 (if Prefix'Length = 0 then Name else Prefix & "/" & Name);
            begin
               if Name = "." or else Name = ".." then
                  null;

               elsif GNAT.OS_Lib.Is_Symbolic_Link
                       (Version.Files.To_Native_Path (Source_Path))
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid loose ref entry: " & Source_Path;

               elsif Ada.Directories.Kind (Dir_Item)
                 = Ada.Directories.Special_File
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid loose ref entry: " & Source_Path;

               elsif Ada.Directories.Kind (Dir_Item)
                 = Ada.Directories.Directory
               then
                  Copy_Tags_In_Directory
                    (Source_Dir => Source_Path, Prefix => Ref_Name);

               elsif Name'Length >= 5
                 and then Name (Name'Last - 4 .. Name'Last) = ".lock"
               then
                  null;

               else
                  Version.Ref_Names.Require_Tag_Name (Ref_Name);

                  declare
                     Object_Id : constant String :=
                       Version.Transport.Local.Read_First_Line (Source_Path);
                  begin
                     if not Version.Objects.Is_Valid_Hex_Object_Id (Object_Id)
                     then
                        raise Ada.IO_Exceptions.Data_Error
                          with Invalid_Loose_Tag_Object_Id_Diagnostic;
                     end if;

                     Updates.Append
                       (Ref_Update'(Name      =>
                          To_Unbounded_String ("refs/tags/" & Ref_Name),
                        Object_Id =>
                          Version.Objects.To_Object_Id (Object_Id)));
                  end;
               end if;
            end;
         end loop;

         Ada.Directories.End_Search (Search);

      exception
         when others =>
            if Opened then
               Ada.Directories.End_Search (Search);
            end if;

            raise;
      end Copy_Tags_In_Directory;
   begin
      Copy_Tags_In_Directory (Source_Dir => Remote_Tags, Prefix => "");
   end Collect_Remote_Tag_Refs;

   function Read_Remote_Packed_Refs
     (Remote_Git_Dir : String)
      return Version.Packed_Refs.Packed_Ref_Vectors.Vector
   is
      Remote_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open_Git_Dir (Remote_Git_Dir);
   begin
      return Version.Packed_Refs.Read_All (Remote_Repo);
   exception
      when Ada.IO_Exceptions.Data_Error =>
         raise Ada.IO_Exceptions.Data_Error with Invalid_Packed_Ref_Line_Diagnostic;
   end Read_Remote_Packed_Refs;

   procedure Collect_Remote_Packed_Tag_Refs
     (Remote_Git_Dir : String;
      Local_Git_Dir  : String;
      Updates        : in out Ref_Update_Vectors.Vector)
   is
      pragma Unreferenced (Local_Git_Dir);
      Items       : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Read_Remote_Packed_Refs (Remote_Git_Dir);
      Tags_Prefix : constant String := "refs/tags/";
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Items.Element (I).Name);
         begin
            if Ref_Name'Length >= Tags_Prefix'Length
              and then
                Ref_Name (Ref_Name'First .. Ref_Name'First + Tags_Prefix'Length - 1)
                = Tags_Prefix
            then
               declare
                  Tag_Name : constant String :=
                    Ref_Name (Ref_Name'First + Tags_Prefix'Length .. Ref_Name'Last);
               begin
                  Version.Ref_Names.Require_Tag_Name (Tag_Name);

                  Updates.Append
                    (Ref_Update'(Name      =>
                        To_Unbounded_String ("refs/tags/" & Tag_Name),
                      Object_Id => Items.Element (I).Id));
               end;
            end if;
         end;
      end loop;
   end Collect_Remote_Packed_Tag_Refs;

   procedure Collect_Remote_Head_Refs
     (Remote_Name    : String;
      Remote_Git_Dir : String;
      Local_Git_Dir  : String;
      Updates        : in out Ref_Update_Vectors.Vector)
   is
      Remote_Heads : constant String :=
        Version.Files.Join (Remote_Git_Dir, "refs/heads");

      pragma Unreferenced (Local_Git_Dir);
      procedure Copy_Heads_In_Directory (Source_Dir : String; Prefix : String)
      is
         Search   : Ada.Directories.Search_Type;
         Dir_Item : Ada.Directories.Directory_Entry_Type;
         Opened   : Boolean := False;
      begin
         if not Ada.Directories.Exists (Source_Dir) then
            return;
         end if;

         Ada.Directories.Start_Search
           (Search    => Search,
            Directory => Source_Dir,
            Pattern   => "*",
            Filter    =>
              [Ada.Directories.Ordinary_File => True,
               Ada.Directories.Directory     => True,
               Ada.Directories.Special_File  => True]);

         Opened := True;

         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Dir_Item);

            declare
               Name : constant String :=
                 Ada.Directories.Simple_Name (Dir_Item);

               Source_Path : constant String :=
                 Ada.Directories.Full_Name (Dir_Item);

               Ref_Name : constant String :=
                 (if Prefix'Length = 0 then Name else Prefix & "/" & Name);
            begin
               if Name = "." or else Name = ".." then
                  null;

               elsif GNAT.OS_Lib.Is_Symbolic_Link
                       (Version.Files.To_Native_Path (Source_Path))
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid loose ref entry: " & Source_Path;

               elsif Ada.Directories.Kind (Dir_Item)
                 = Ada.Directories.Special_File
               then
                  raise Ada.IO_Exceptions.Data_Error with
                    "invalid loose ref entry: " & Source_Path;

               elsif Ada.Directories.Kind (Dir_Item)
                 = Ada.Directories.Directory
               then
                  Copy_Heads_In_Directory
                    (Source_Dir => Source_Path, Prefix => Ref_Name);

               elsif Name'Length >= 5
                 and then Name (Name'Last - 4 .. Name'Last) = ".lock"
               then
                  null;

               else
                  Version.Ref_Names.Require_Branch_Name (Ref_Name);

                  declare
                     Commit_Id : constant String :=
                       Version.Transport.Local.Read_First_Line (Source_Path);
                  begin
                     if not Version.Objects.Is_Valid_Hex_Object_Id (Commit_Id)
                     then
                        raise Ada.IO_Exceptions.Data_Error
                          with Invalid_Loose_Branch_Object_Id_Diagnostic;
                     end if;
                     Updates.Append
                       (Ref_Update'(Name      =>
                          To_Unbounded_String
                            ("refs/remotes/" & Remote_Name & "/" & Ref_Name),
                        Object_Id =>
                          Version.Objects.To_Object_Id (Commit_Id)));
                  end;
               end if;
            end;
         end loop;

         Ada.Directories.End_Search (Search);

      exception
         when others =>
            if Opened then
               Ada.Directories.End_Search (Search);
            end if;

            raise;
      end Copy_Heads_In_Directory;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      Copy_Heads_In_Directory (Source_Dir => Remote_Heads, Prefix => "");
   end Collect_Remote_Head_Refs;

   procedure Collect_Remote_Packed_Head_Refs
     (Remote_Name    : String;
      Remote_Git_Dir : String;
      Local_Git_Dir  : String;
      Updates        : in out Ref_Update_Vectors.Vector)
   is
      pragma Unreferenced (Local_Git_Dir);
      Items        : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Read_Remote_Packed_Refs (Remote_Git_Dir);
      Heads_Prefix : constant String := "refs/heads/";
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Items.Element (I).Name);
         begin
            if Ref_Name'Length >= Heads_Prefix'Length
              and then
                Ref_Name (Ref_Name'First .. Ref_Name'First + Heads_Prefix'Length - 1)
                = Heads_Prefix
            then
               declare
                  Branch_Name : constant String :=
                    Ref_Name
                      (Ref_Name'First + Heads_Prefix'Length .. Ref_Name'Last);
               begin
                  Version.Ref_Names.Require_Branch_Name (Branch_Name);

                  Updates.Append
                    (Ref_Update'(Name      =>
                        To_Unbounded_String
                          ("refs/remotes/" & Remote_Name & "/" & Branch_Name),
                      Object_Id => Items.Element (I).Id));
               end;
            end if;
         end;
      end loop;
   end Collect_Remote_Packed_Head_Refs;

   type Collecting_Consumer is limited new Version.Transport.Http.Byte_Consumer
   with record
      Data : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding
   procedure Consume
     (Item : in out Collecting_Consumer;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      for I in Data'Range loop
         Ada.Strings.Unbounded.Append (Item.Data, Character'Val (Data (I)));
      end loop;
   end Consume;

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

   function Stream_To_String
     (Data : Ada.Streams.Stream_Element_Array) return String
   is
      Result : String (1 .. Natural (Data'Length));
      J      : Natural := Result'First;
   begin
      for I in Data'Range loop
         Result (J) := Character'Val (Data (I));
         J := J + 1;
      end loop;

      return Result;
   end Stream_To_String;

   type Pack_File_Consumer is limited new Version.Transport.Http.Byte_Consumer
   with record
      Path   : Unbounded_String;
      File   : Ada.Streams.Stream_IO.File_Type;
      Opened : Boolean := False;
      Wrote  : Boolean := False;
   end record;

   overriding
   procedure Consume
     (Item : in out Pack_File_Consumer;
      Data : Ada.Streams.Stream_Element_Array);

   procedure Close_Pack_File (Item : in out Pack_File_Consumer) is
   begin
      if Item.Opened then
         Ada.Streams.Stream_IO.Close (Item.File);
         Item.Opened := False;
      end if;
   end Close_Pack_File;

   overriding
   procedure Consume
     (Item : in out Pack_File_Consumer;
      Data : Ada.Streams.Stream_Element_Array) is
   begin
      if Data'Length = 0 then
         return;
      end if;

      if not Item.Opened then
         Ada.Streams.Stream_IO.Create
           (File => Item.File,
            Mode => Ada.Streams.Stream_IO.Out_File,
            Name => Version.Files.To_Native_Path (To_String (Item.Path)));
         Item.Opened := True;
      end if;

      Ada.Streams.Stream_IO.Write (Item.File, Data);
      Item.Wrote := True;
   end Consume;

   type Upload_Pack_Demux_Consumer
     (Downstream : not null access Version.Transport.Http.Byte_Consumer'Class)
   is limited new Version.Transport.Http.Byte_Consumer with record
      Parser : Version.Pkt_Line.Parser;
      Update : Version.Upload_Pack.Shallow_Update;
   end record;

   overriding
   procedure Consume
     (Item : in out Upload_Pack_Demux_Consumer;
      Data : Ada.Streams.Stream_Element_Array);

   procedure Consume_Demuxed_Packet
     (Item    : in out Upload_Pack_Demux_Consumer;
      Payload : Ada.Streams.Stream_Element_Array) is
      LF      : constant Character := Character'Val (10);
      Text    : constant String := Stream_To_String (Payload);
      Matched : Boolean := False;
   begin
      Version.Upload_Pack.Parse_Shallow_Line
        (Payload => Text, Update => Item.Update, Matched => Matched);

      if Matched then
         return;
      elsif Text = "NAK" & LF
        or else
          (Text'Length >= 4
           and then Text (Text'First .. Text'First + 3) = "ACK ")
      then
         return;
      elsif Payload'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error
           with "empty upload-pack response packet";
      end if;

      declare
         Channel : constant Natural := Natural (Payload (Payload'First));
      begin
         case Channel is
            when 1      =>
               if Payload'Last > Payload'First then
                  Item.Downstream.Consume
                    (Payload (Payload'First + 1 .. Payload'Last));
               end if;

            when 2      =>
               null;

            when 3      =>
               if Payload'Last > Payload'First then
                  raise Ada.IO_Exceptions.Data_Error
                    with
                      "upload-pack fatal: "
                      & Stream_To_String
                          (Payload (Payload'First + 1 .. Payload'Last));
               else
                  raise Ada.IO_Exceptions.Data_Error with "upload-pack fatal";
               end if;

            when others =>
               raise Ada.IO_Exceptions.Data_Error
                 with "unknown upload-pack sideband channel";
         end case;
      end;
   end Consume_Demuxed_Packet;

   overriding
   procedure Consume
     (Item : in out Upload_Pack_Demux_Consumer; Data : Ada.Streams.Stream_Element_Array) is
      Kind   : Version.Pkt_Line.Packet_Kind;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65_520);
      Last   : Ada.Streams.Stream_Element_Offset;
      Status : Version.Pkt_Line.Parse_Status;
   begin
      Version.Pkt_Line.Feed (Item.Parser, Data);

      loop
         Status := Version.Pkt_Line.Next (Item.Parser, Kind, Buffer, Last);

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
            Consume_Demuxed_Packet
              (Item => Item, Payload => Buffer (Buffer'First .. Last));
         end if;
      end loop;
   end Consume;

   function Select_Default_Want
     (Discovery : Version.Upload_Pack.Discovery_Result)
      return Version.Objects.Hex_Object_Id
   is
      Head_Target : constant String := To_String (Discovery.Head_Target);
   begin
      if Head_Target'Length > 0 and then not Discovery.Refs.Is_Empty then
         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            if To_String (Discovery.Refs.Element (I).Name) = Head_Target then
               return Discovery.Refs.Element (I).Id;
            end if;
         end loop;
      end if;

      if not Discovery.Refs.Is_Empty then
         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            declare
               Name : constant String :=
                 To_String (Discovery.Refs.Element (I).Name);
            begin
               if Name = "HEAD" then
                  return Discovery.Refs.Element (I).Id;
               end if;
            end;
         end loop;

         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            declare
               Name   : constant String :=
                 To_String (Discovery.Refs.Element (I).Name);
               Prefix : constant String := "refs/heads/";
            begin
               if Name'Length >= Prefix'Length
                 and then
                   Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
               then
                  return Discovery.Refs.Element (I).Id;
               end if;
            end;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error
        with "upload-pack discovery did not advertise a fetchable ref";
   end Select_Default_Want;

   procedure Update_Advertised_Remote_Refs
     (Remote_Name   : String;
      Local_Git_Dir : String;
      Discovery     : Version.Upload_Pack.Discovery_Result;
      Fetched_Id    : Version.Objects.Hex_Object_Id)
   is
      pragma Unreferenced (Local_Git_Dir);

      Heads_Prefix    : constant String := "refs/heads/";
      Tags_Prefix     : constant String := "refs/tags/";
      Repo            : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Tx              : Version.Ref_Transaction.Transaction;
      Has_Ref_Update  : Boolean := False;

      function Object_Available
        (Id : Version.Objects.Hex_Object_Id) return Boolean
      is
         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Id);
         pragma Unreferenced (Obj);
      begin
         return True;
      exception
         when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
            return False;
      end Object_Available;

      function Is_Peeled_Tag_Advertisement (Name : String) return Boolean is
         Suffix : constant String := "^{}";
      begin
         return Name'Length >= Tags_Prefix'Length + Suffix'Length
           and then Name (Name'First .. Name'First + Tags_Prefix'Length - 1)
                    = Tags_Prefix
           and then Name (Name'Last - Suffix'Length + 1 .. Name'Last)
                    = Suffix;
      end Is_Peeled_Tag_Advertisement;
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);

      if Discovery.Refs.Is_Empty then
         return;
      end if;

      Version.Ref_Transaction.Start (Tx, Repo);

      for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
         declare
            Ref : constant Version.Upload_Pack.Advertised_Ref :=
              Discovery.Refs.Element (I);

            Name : constant String := To_String (Ref.Name);
         begin
            if Name'Length >= Heads_Prefix'Length
              and then
                Name (Name'First .. Name'First + Heads_Prefix'Length - 1)
                = Heads_Prefix
            then
               if Ref.Id = Fetched_Id then
                  declare
                     Branch_Name : constant String :=
                       Name (Name'First + Heads_Prefix'Length .. Name'Last);
                  begin
                     Version.Ref_Names.Require_Branch_Name (Branch_Name);

                     Version.Fetch.Internal.Add_Update_With_Current_Old
                       (Tx       => Tx,
                        Repo     => Repo,
                        Ref_Name =>
                          "refs/remotes/" & Remote_Name & "/" & Branch_Name,
                        New_Id   => Ref.Id);
                     Has_Ref_Update := True;
                  end;
               end if;

            elsif Is_Peeled_Tag_Advertisement (Name) then
               null;

            elsif Name'Length >= Tags_Prefix'Length
              and then
                Name (Name'First .. Name'First + Tags_Prefix'Length - 1)
                = Tags_Prefix
            then
               declare
                  Tag_Name : constant String :=
                    Name (Name'First + Tags_Prefix'Length .. Name'Last);
               begin
                  Version.Ref_Names.Require_Tag_Name (Tag_Name);

                  if Object_Available (Ref.Id) then
                     Version.Fetch.Internal.Add_Update_With_Current_Old
                       (Tx       => Tx,
                        Repo     => Repo,
                        Ref_Name => "refs/tags/" & Tag_Name,
                        New_Id   => Ref.Id);
                     Has_Ref_Update := True;
                  end if;
               end;
            end if;
         end;
      end loop;

      if Has_Ref_Update then
         Version.Ref_Transaction.Commit (Tx);
      else
         Version.Ref_Transaction.Cancel (Tx);
      end if;
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Update_Advertised_Remote_Refs;

   function Object_Available
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id) return Boolean
   is
   begin
      return Ada.Directories.Exists (Version.Objects.Loose_Object_Path (Repo, Id))
        or else Version.Pack.Contains (Repo, Id);
   end Object_Available;

   function Promisor_Pack_Path
     (Local_Git_Dir : String;
      Id            : Version.Objects.Hex_Object_Id) return String
   is
   begin
      return
        Version.Files.Join
          (Version.Files.Join
             (Version.Files.Join (Local_Git_Dir, "objects"), "pack"),
           "promisor-" & To_String (Id) & ".pack");
   end Promisor_Pack_Path;

   procedure Fetch_Http_Object
     (Repo          : Version.Repository.Repository_Handle;
      Url           : String;
      Local_Git_Dir : String;
      Want_Id       : Version.Objects.Hex_Object_Id)
   is
      Discovery_Raw : Collecting_Consumer;
   begin
      Version.Transport.Http.Discover_Upload_Pack
        (Url => Url, Consumer => Discovery_Raw);

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Discovery
             (To_Stream (To_String (Discovery_Raw.Data)));

         Request : constant Ada.Streams.Stream_Element_Array :=
           (if Version.Upload_Pack.Has_Capability
                 (To_String (Discovery.Capabilities), "filter")
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id     => Want_Id,
                    Filter_Spec => "blob:none",
                    Include_Tag => False)
            else Version.Upload_Pack.Build_Want_Request
                   (Want_Id     => Want_Id,
                    Include_Tag => False));

         Pack_Path : constant String := Promisor_Pack_Path (Local_Git_Dir, Want_Id);
         Pack_Idx_Path : constant String :=
           Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx";

         procedure Delete_Temporary_Pack_Artifacts is
         begin
            Version.Files.Delete_File_If_Exists (Pack_Path);
            Version.Files.Delete_File_If_Exists (Pack_Idx_Path);
         end Delete_Temporary_Pack_Artifacts;

         Pack_File : aliased Pack_File_Consumer :=
           (Path   => To_Unbounded_String (Pack_Path),
            File   => <>,
            Opened => False,
            Wrote  => False);

         Demuxer : Upload_Pack_Demux_Consumer (Pack_File'Access);
      begin
         Version.Files.Create_Directory_If_Missing
           (Version.Files.Join
              (Version.Files.Join (Local_Git_Dir, "objects"), "pack"));
         Delete_Temporary_Pack_Artifacts;

         begin
            Version.Transport.Http.Upload_Pack
              (Url => Url, Request => Request, Consumer => Demuxer);
         exception
            when others =>
               Close_Pack_File (Pack_File);
               Delete_Temporary_Pack_Artifacts;
               raise;
         end;

         Close_Pack_File (Pack_File);

         if Pack_File.Wrote then
            Version.Pack.Index_Pack (Repo => Repo, Pack_Path => Pack_Path);
         end if;

         if not Object_Available (Repo, Want_Id) then
            Delete_Temporary_Pack_Artifacts;
            raise Ada.IO_Exceptions.Data_Error with
              "upload-pack response did not provide requested object";
         end if;

      exception
         when others =>
            Close_Pack_File (Pack_File);
            if not Object_Available (Repo, Want_Id) then
               Delete_Temporary_Pack_Artifacts;
            end if;
            raise;
      end;
   end Fetch_Http_Object;

   procedure Fetch_Ssh_Object
     (Repo          : Version.Repository.Repository_Handle;
      Url           : String;
      Local_Git_Dir : String;
      Want_Id       : Version.Objects.Hex_Object_Id)
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Ada.Strings.Unbounded.Unbounded_String;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Version.Transport.Ssh.Open_Upload_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            Stream_To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Fixed.Index
           (To_String (Raw_Advertisement), "0000") /= 0;
      end loop;

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Advertisement
             (To_Stream (To_String (Raw_Advertisement)));

         Request : constant Ada.Streams.Stream_Element_Array :=
           (if Version.Upload_Pack.Has_Capability
                 (To_String (Discovery.Capabilities), "filter")
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id     => Want_Id,
                    Filter_Spec => "blob:none",
                    Include_Tag => False)
            else Version.Upload_Pack.Build_Want_Request
                   (Want_Id     => Want_Id,
                    Include_Tag => False));

         Pack_Path : constant String := Promisor_Pack_Path (Local_Git_Dir, Want_Id);
         Pack_Idx_Path : constant String :=
           Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx";

         procedure Delete_Temporary_Pack_Artifacts is
         begin
            Version.Files.Delete_File_If_Exists (Pack_Path);
            Version.Files.Delete_File_If_Exists (Pack_Idx_Path);
         end Delete_Temporary_Pack_Artifacts;

         Pack_File : aliased Pack_File_Consumer :=
           (Path   => To_Unbounded_String (Pack_Path),
            File   => <>,
            Opened => False,
            Wrote  => False);

         Demuxer : Upload_Pack_Demux_Consumer (Pack_File'Access);
      begin
         Version.Files.Create_Directory_If_Missing
           (Version.Files.Join
              (Version.Files.Join (Local_Git_Dir, "objects"), "pack"));
         Delete_Temporary_Pack_Artifacts;
         Version.Transport.Ssh.Write (Stream, Request);

         begin
            loop
               Version.Transport.Ssh.Read_Some
                 (Stream => Stream, Buffer => Buffer, Last => Last);

               exit when Last < Buffer'First;

               Demuxer.Consume (Buffer (Buffer'First .. Last));
            end loop;

            Version.Transport.Ssh.Close (Stream);
         exception
            when others =>
               Close_Pack_File (Pack_File);
               Delete_Temporary_Pack_Artifacts;
               Version.Transport.Ssh.Close (Stream);
               raise;
         end;

         Close_Pack_File (Pack_File);

         if Pack_File.Wrote then
            Version.Pack.Index_Pack (Repo => Repo, Pack_Path => Pack_Path);
         end if;

         if not Object_Available (Repo, Want_Id) then
            Delete_Temporary_Pack_Artifacts;
            raise Ada.IO_Exceptions.Data_Error with
              "upload-pack response did not provide requested object";
         end if;

      exception
         when others =>
            Close_Pack_File (Pack_File);
            if not Object_Available (Repo, Want_Id) then
               Delete_Temporary_Pack_Artifacts;
            end if;
            Version.Transport.Ssh.Close (Stream);
            raise;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Fetch_Ssh_Object;

   function Remote_Object_Format
     (Url : String)
      return Version.Hash.Hash_Algorithm is
   begin
      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport =>
            return Version.Repository_Format.Algorithm
              (Version.Repository_Format.Read
                 (Version.Transport.Local.Resolve_Git_Dir
                    (Version.Transport.Strip_File_Scheme (Url))));

         when Version.Transport.Http_Transport =>
            declare
               Discovery_Raw : Collecting_Consumer;
            begin
               Version.Transport.Http.Discover_Upload_Pack
                 (Url => Url, Consumer => Discovery_Raw);

               declare
                  Discovery : constant Version.Upload_Pack.Discovery_Result :=
                    Version.Upload_Pack.Parse_Discovery
                      (To_Stream (To_String (Discovery_Raw.Data)));
               begin
                  return Version.Upload_Pack.Advertised_Object_Format
                    (To_String (Discovery.Capabilities));
               end;
            end;

         when Version.Transport.Ssh_Transport =>
            declare
               Stream : Version.Transport.Ssh.Ssh_Stream;
               Raw_Advertisement : Ada.Strings.Unbounded.Unbounded_String;
               Buffer : Ada.Streams.Stream_Element_Array (1 .. 8192);
               Last   : Ada.Streams.Stream_Element_Offset;
            begin
               Version.Transport.Ssh.Open_Upload_Pack (Url, Stream);

               loop
                  Version.Transport.Ssh.Read_Some
                    (Stream => Stream, Buffer => Buffer, Last => Last);
                  exit when Last < Buffer'First;
                  Append
                    (Raw_Advertisement,
                     Stream_To_String (Buffer (Buffer'First .. Last)));
                  exit when Ada.Strings.Fixed.Index
                    (To_String (Raw_Advertisement), "0000") /= 0;
               end loop;

               Version.Transport.Ssh.Close (Stream);

               declare
                  Discovery : constant Version.Upload_Pack.Discovery_Result :=
                    Version.Upload_Pack.Parse_Advertisement
                      (To_Stream (To_String (Raw_Advertisement)));
               begin
                  return Version.Upload_Pack.Advertised_Object_Format
                    (To_String (Discovery.Capabilities));
               end;
            end;

         when Version.Transport.Unsupported_Transport =>
            return Version.Hash.Sha1;
      end case;

   exception
      when others =>
         --  Any discovery failure here defers to the subsequent Fetch, which
         --  surfaces the real error; assume the common sha1 default meanwhile.
         return Version.Hash.Sha1;
   end Remote_Object_Format;

   procedure Fetch_Http
     (Remote_Name   : String;
      Url           : String;
      Local_Git_Dir : String;
      Has_Depth     : Boolean;
      Depth         : Positive;
      Filter_Spec   : String := "")
   is
      Discovery_Raw : Collecting_Consumer;
   begin
      Version.Transport.Http.Discover_Upload_Pack
        (Url => Url, Consumer => Discovery_Raw);

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Discovery
             (To_Stream (To_String (Discovery_Raw.Data)));

         Want_Id : constant Version.Objects.Hex_Object_Id :=
           Select_Default_Want (Discovery);

         Include_Tag : constant Boolean :=
           Version.Upload_Pack.Has_Capability
             (To_String (Discovery.Capabilities), "include-tag");

         Use_Filter : constant Boolean :=
           Filter_Spec'Length > 0 and then not Has_Depth
           and then Version.Upload_Pack.Has_Capability
                      (To_String (Discovery.Capabilities), "filter");

         Request : constant Ada.Streams.Stream_Element_Array :=
           (if Has_Depth
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Depth, Include_Tag)
            elsif Use_Filter
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Filter_Spec, Include_Tag)
            else Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Include_Tag));

         Pack_Path : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Local_Git_Dir, "objects"), "pack"),
              "tmp-version-fetch.pack");

         Pack_Idx_Path : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Local_Git_Dir, "objects"), "pack"),
              "tmp-version-fetch.idx");

         procedure Delete_Temporary_Pack_Artifacts is
         begin
            Version.Files.Delete_File_If_Exists (Pack_Path);
            Version.Files.Delete_File_If_Exists (Pack_Idx_Path);
         end Delete_Temporary_Pack_Artifacts;

         Pack_File : aliased Pack_File_Consumer :=
           (Path   => To_Unbounded_String (Pack_Path),
            File   => <>,
            Opened => False,
            Wrote  => False);

         Demuxer : Upload_Pack_Demux_Consumer (Pack_File'Access);

         Shallow_Update : Version.Upload_Pack.Shallow_Update;
      begin
         if Has_Depth
           and then
             not Version.Upload_Pack.Has_Capability
                   (To_String (Discovery.Capabilities), "shallow")
         then
            raise Ada.IO_Exceptions.Data_Error
              with "server does not advertise shallow fetch support";
         end if;

         Delete_Temporary_Pack_Artifacts;

         begin
            Version.Transport.Http.Upload_Pack
              (Url => Url, Request => Request, Consumer => Demuxer);
         exception
            when others =>
               Close_Pack_File (Pack_File);
               Delete_Temporary_Pack_Artifacts;
               raise;
         end;

         Close_Pack_File (Pack_File);
         Shallow_Update := Demuxer.Update;

         if Pack_File.Wrote then
            Version.Pack.Index_Pack
              (Repo => Version.Repository.Open, Pack_Path => Pack_Path);
         end if;

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            if Version.Objects.Kind
                 (Version.Objects.Read_Object (Repo, Want_Id))
              /= Version.Objects.Commit_Object
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "fetched upload-pack object is not a commit";
            end if;
         exception
            when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
               raise Ada.IO_Exceptions.Data_Error
                 with "upload-pack response did not provide requested commit";
         end;

         declare
            Repo          : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Shallow_Items : Version.Objects.Object_Id_Vectors.Vector :=
              Version.Shallow.Read (Repo);
            Existing      : Object_Id_Sets.Set;
            Unshallow_Set : Object_Id_Sets.Set;
         begin
            if not Shallow_Items.Is_Empty then
               for I in Shallow_Items.First_Index .. Shallow_Items.Last_Index
               loop
                  Existing.Include (Shallow_Items.Element (I));
               end loop;
            end if;

            if not Shallow_Update.Shallow.Is_Empty then
               for I in
                 Shallow_Update.Shallow.First_Index
                 .. Shallow_Update.Shallow.Last_Index
               loop
                  declare
                     Id : constant Version.Objects.Hex_Object_Id :=
                       Shallow_Update.Shallow.Element (I);
                  begin
                     if Version.Objects.Kind
                          (Version.Objects.Read_Object (Repo, Id))
                       /= Version.Objects.Commit_Object
                     then
                        raise Ada.IO_Exceptions.Data_Error
                          with "shallow boundary object is not commit";
                     end if;

                     if not Existing.Contains (Id) then
                        Existing.Include (Id);
                        Shallow_Items.Append (Id);
                     end if;
                  end;
               end loop;
            end if;

            if not Shallow_Update.Unshallow.Is_Empty then
               for I in
                 Shallow_Update.Unshallow.First_Index
                 .. Shallow_Update.Unshallow.Last_Index
               loop
                  Unshallow_Set.Include (Shallow_Update.Unshallow.Element (I));
               end loop;

               declare
                  Filtered : Version.Objects.Object_Id_Vectors.Vector;
               begin
                  if not Shallow_Items.Is_Empty then
                     for I in
                       Shallow_Items.First_Index .. Shallow_Items.Last_Index
                     loop
                        if not Unshallow_Set.Contains
                                 (Shallow_Items.Element (I))
                        then
                           Filtered.Append (Shallow_Items.Element (I));
                        end if;
                     end loop;
                  end if;
                  Shallow_Items := Filtered;
               end;
            end if;

            if Has_Depth
              or else not Shallow_Update.Shallow.Is_Empty
              or else not Shallow_Update.Unshallow.Is_Empty
            then
               Version.Shallow.Write (Repo, Shallow_Items);
            end if;
         end;

         Update_Advertised_Remote_Refs
           (Remote_Name   => Remote_Name,
            Local_Git_Dir => Local_Git_Dir,
            Discovery     => Discovery,
            Fetched_Id    => Want_Id);

      exception
         when others =>
            Close_Pack_File (Pack_File);
            Delete_Temporary_Pack_Artifacts;
            raise;
      end;
   end Fetch_Http;

   procedure Fetch_Ssh
     (Remote_Name   : String;
      Url           : String;
      Local_Git_Dir : String;
      Has_Depth     : Boolean;
      Depth         : Positive;
      Filter_Spec   : String := "")
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Raw_Advertisement : Ada.Strings.Unbounded.Unbounded_String;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Version.Transport.Ssh.Open_Upload_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         Append
           (Raw_Advertisement,
            Stream_To_String (Buffer (Buffer'First .. Last)));

         exit when Ada.Strings.Fixed.Index
           (To_String (Raw_Advertisement), "0000") /= 0;
      end loop;

      declare
         Discovery : constant Version.Upload_Pack.Discovery_Result :=
           Version.Upload_Pack.Parse_Advertisement
             (To_Stream (To_String (Raw_Advertisement)));

         Want_Id : constant Version.Objects.Hex_Object_Id :=
           Select_Default_Want (Discovery);

         Include_Tag : constant Boolean :=
           Version.Upload_Pack.Has_Capability
             (To_String (Discovery.Capabilities), "include-tag");

         Use_Filter : constant Boolean :=
           Filter_Spec'Length > 0 and then not Has_Depth
           and then Version.Upload_Pack.Has_Capability
                      (To_String (Discovery.Capabilities), "filter");

         Request : constant Ada.Streams.Stream_Element_Array :=
           (if Has_Depth
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Depth, Include_Tag)
            elsif Use_Filter
            then Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Filter_Spec, Include_Tag)
            else Version.Upload_Pack.Build_Want_Request
                   (Want_Id, Include_Tag));

         Pack_Path : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Local_Git_Dir, "objects"), "pack"),
              "tmp-version-fetch.pack");

         Pack_Idx_Path : constant String :=
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join (Local_Git_Dir, "objects"), "pack"),
              "tmp-version-fetch.idx");

         procedure Delete_Temporary_Pack_Artifacts is
         begin
            Version.Files.Delete_File_If_Exists (Pack_Path);
            Version.Files.Delete_File_If_Exists (Pack_Idx_Path);
         end Delete_Temporary_Pack_Artifacts;

         Pack_File : aliased Pack_File_Consumer :=
           (Path   => To_Unbounded_String (Pack_Path),
            File   => <>,
            Opened => False,
            Wrote  => False);

         Demuxer : Upload_Pack_Demux_Consumer (Pack_File'Access);

         Shallow_Update : Version.Upload_Pack.Shallow_Update;
      begin
         if Has_Depth
           and then
             not Version.Upload_Pack.Has_Capability
                   (To_String (Discovery.Capabilities), "shallow")
         then
            raise Ada.IO_Exceptions.Data_Error
              with "server does not advertise shallow fetch support";
         end if;

         Delete_Temporary_Pack_Artifacts;
         Version.Transport.Ssh.Write (Stream, Request);

         begin
            loop
               Version.Transport.Ssh.Read_Some
                 (Stream => Stream, Buffer => Buffer, Last => Last);

               exit when Last < Buffer'First;

               Demuxer.Consume (Buffer (Buffer'First .. Last));
            end loop;

            Version.Transport.Ssh.Close (Stream);
         exception
            when others =>
               Close_Pack_File (Pack_File);
               Delete_Temporary_Pack_Artifacts;
               Version.Transport.Ssh.Close (Stream);
               raise;
         end;

         Close_Pack_File (Pack_File);
         Shallow_Update := Demuxer.Update;

         if Pack_File.Wrote then
            Version.Pack.Index_Pack
              (Repo => Version.Repository.Open, Pack_Path => Pack_Path);
         end if;

         declare
            Repo : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
         begin
            if Version.Objects.Kind
                 (Version.Objects.Read_Object (Repo, Want_Id))
              /= Version.Objects.Commit_Object
            then
               raise Ada.IO_Exceptions.Data_Error
                 with "fetched upload-pack object is not a commit";
            end if;
         exception
            when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
               raise Ada.IO_Exceptions.Data_Error
                 with "upload-pack response did not provide requested commit";
         end;

         declare
            Repo          : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Shallow_Items : Version.Objects.Object_Id_Vectors.Vector :=
              Version.Shallow.Read (Repo);
            Existing      : Object_Id_Sets.Set;
            Unshallow_Set : Object_Id_Sets.Set;
         begin
            if not Shallow_Items.Is_Empty then
               for I in Shallow_Items.First_Index .. Shallow_Items.Last_Index
               loop
                  Existing.Include (Shallow_Items.Element (I));
               end loop;
            end if;

            if not Shallow_Update.Shallow.Is_Empty then
               for I in
                 Shallow_Update.Shallow.First_Index
                 .. Shallow_Update.Shallow.Last_Index
               loop
                  declare
                     Id : constant Version.Objects.Hex_Object_Id :=
                       Shallow_Update.Shallow.Element (I);
                  begin
                     if Version.Objects.Kind
                          (Version.Objects.Read_Object (Repo, Id))
                       /= Version.Objects.Commit_Object
                     then
                        raise Ada.IO_Exceptions.Data_Error
                          with "shallow boundary object is not commit";
                     end if;

                     if not Existing.Contains (Id) then
                        Existing.Include (Id);
                        Shallow_Items.Append (Id);
                     end if;
                  end;
               end loop;
            end if;

            if not Shallow_Update.Unshallow.Is_Empty then
               for I in
                 Shallow_Update.Unshallow.First_Index
                 .. Shallow_Update.Unshallow.Last_Index
               loop
                  Unshallow_Set.Include (Shallow_Update.Unshallow.Element (I));
               end loop;

               declare
                  Filtered : Version.Objects.Object_Id_Vectors.Vector;
               begin
                  if not Shallow_Items.Is_Empty then
                     for I in
                       Shallow_Items.First_Index .. Shallow_Items.Last_Index
                     loop
                        if not Unshallow_Set.Contains
                                 (Shallow_Items.Element (I))
                        then
                           Filtered.Append (Shallow_Items.Element (I));
                        end if;
                     end loop;
                  end if;
                  Shallow_Items := Filtered;
               end;
            end if;

            if Has_Depth
              or else not Shallow_Update.Shallow.Is_Empty
              or else not Shallow_Update.Unshallow.Is_Empty
            then
               Version.Shallow.Write (Repo, Shallow_Items);
            end if;
         end;

         Update_Advertised_Remote_Refs
           (Remote_Name   => Remote_Name,
            Local_Git_Dir => Local_Git_Dir,
            Discovery     => Discovery,
            Fetched_Id    => Want_Id);

      exception
         when others =>
            Close_Pack_File (Pack_File);
            Delete_Temporary_Pack_Artifacts;
            Version.Transport.Ssh.Close (Stream);
            raise;
      end;
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Fetch_Ssh;

   procedure Fetch_Object
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Id          : Version.Objects.Hex_Object_Id)
   is
      Local_Git_Dir : constant String := Version.Repository.Common_Git_Dir (Repo);
      Url : constant String := Remote_Url (Repo, Remote_Name);
   begin
      if Object_Available (Repo, Id) then
         return;
      end if;

      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport       =>
            declare
               Remote_Git_Dir : constant String :=
                 Remote_Git_Dir_For (Repo, Remote_Name);
               Source_Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open_Git_Dir (Remote_Git_Dir);
            begin
               --  Copy only the requested object (selective lazy fetch), so a
               --  partial clone stays partial across promisor materialization.
               Version.Write.Copy_Object (Source_Repo, Repo, Id);

               if not Object_Available (Repo, Id) then
                  raise Ada.IO_Exceptions.Data_Error with
                    "promisor remote did not provide requested object: "
                    & To_String (Id);
               end if;
            end;

         when Version.Transport.Http_Transport        =>
            Fetch_Http_Object
              (Repo          => Repo,
               Url           => Url,
               Local_Git_Dir => Local_Git_Dir,
               Want_Id       => Id);

         when Version.Transport.Ssh_Transport         =>
            Fetch_Ssh_Object
              (Repo          => Repo,
               Url           => Url,
               Local_Git_Dir => Local_Git_Dir,
               Want_Id       => Id);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with Version.Unsupported.Remote_Url;
      end case;
   end Fetch_Object;

   --  True when Filter_Spec is a partial-clone filter version can evaluate
   --  locally (blob:none or blob:limit=<n>).
   function Local_Filter_Supported (Filter_Spec : String) return Boolean is
      Limit_Prefix : constant String := "blob:limit=";
   begin
      return Filter_Spec = "blob:none"
        or else
          (Filter_Spec'Length > Limit_Prefix'Length
           and then Filter_Spec
                      (Filter_Spec'First
                       .. Filter_Spec'First + Limit_Prefix'Length - 1)
                    = Limit_Prefix);
   end Local_Filter_Supported;

   --  Selectively copy objects reachable from the fetched refs, omitting
   --  blobs per Filter_Spec (the rest of a local partial clone). Omitted
   --  blobs are materialized later on demand by the promisor lazy fetch.
   procedure Copy_Filtered_Objects
     (Remote_Git_Dir : String;
      Target_Repo    : Version.Repository.Repository_Handle;
      Ref_Updates    : Ref_Update_Vectors.Vector;
      Filter_Spec    : String)
   is
      Source_Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open_Git_Dir (Remote_Git_Dir);
      Seen        : Object_Id_Sets.Set;

      function Keep_Blob (Size : Natural) return Boolean is
         Limit_Prefix : constant String := "blob:limit=";
      begin
         if Filter_Spec = "blob:none" then
            return False;
         end if;

         declare
            Digits_Text : constant String :=
              Filter_Spec
                (Filter_Spec'First + Limit_Prefix'Length .. Filter_Spec'Last);
         begin
            return Size < Natural'Value (Digits_Text);
         exception
            when Constraint_Error =>
               raise Ada.IO_Exceptions.Data_Error
                 with "invalid blob:limit filter: " & Filter_Spec;
         end;
      end Keep_Blob;
   begin
      if not Local_Filter_Supported (Filter_Spec) then
         raise Ada.IO_Exceptions.Data_Error with
           "filter is not supported for local clones (use an HTTP/SSH remote): "
           & Filter_Spec;
      end if;

      for U of Ref_Updates loop
         for Obj_Id of Version.History.Reachable_Objects
                         (Source_Repo, U.Object_Id)
         loop
            if not Seen.Contains (Obj_Id) then
               Seen.Insert (Obj_Id);

               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Objects.Read_Object (Source_Repo, Obj_Id);
               begin
                  if Version.Objects.Kind (Obj) /=
                       Version.Objects.Blob_Object
                    or else Keep_Blob (Version.Objects.Content (Obj)'Length)
                  then
                     Version.Write.Copy_Object (Source_Repo, Target_Repo, Obj_Id);
                  end if;
               end;
            end if;
         end loop;
      end loop;
   end Copy_Filtered_Objects;

   procedure Fetch
     (Remote_Name : String; Has_Depth : Boolean; Depth : Positive;
      Filter_Spec : String := "")
   is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Local_Git_Dir : constant String :=
        Version.Repository.Common_Git_Dir (Repo);

      Url : constant String := Remote_Url (Remote_Name);
   begin
      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport       =>
            if Has_Depth then
               raise Ada.IO_Exceptions.Data_Error
                 with "shallow fetch is only supported for smart transports";
            end if;

            declare
               Remote_Git_Dir : constant String :=
                 Remote_Git_Dir_For (Repo, Remote_Name);

               Ref_Updates    : Ref_Update_Vectors.Vector;
               Copied_Targets : Version.Transport.Local.Copied_Object_Vectors.Vector;
            begin
               Collect_Remote_Tag_Refs
                 (Remote_Git_Dir => Remote_Git_Dir,
                  Local_Git_Dir  => Local_Git_Dir,
                  Updates        => Ref_Updates);

               Collect_Remote_Packed_Tag_Refs
                 (Remote_Git_Dir => Remote_Git_Dir,
                  Local_Git_Dir  => Local_Git_Dir,
                  Updates        => Ref_Updates);

               Collect_Remote_Head_Refs
                 (Remote_Name    => Remote_Name,
                  Remote_Git_Dir => Remote_Git_Dir,
                  Local_Git_Dir  => Local_Git_Dir,
                  Updates        => Ref_Updates);

               Collect_Remote_Packed_Head_Refs
                 (Remote_Name    => Remote_Name,
                  Remote_Git_Dir => Remote_Git_Dir,
                  Local_Git_Dir  => Local_Git_Dir,
                  Updates        => Ref_Updates);

               if Filter_Spec = "" then
                  Version.Transport.Local.Copy_Object_Store
                    (Source_Git_Dir => Remote_Git_Dir,
                     Target_Git_Dir => Local_Git_Dir,
                     Copied_Targets => Copied_Targets);
               else
                  Copy_Filtered_Objects
                    (Remote_Git_Dir => Remote_Git_Dir,
                     Target_Repo    => Repo,
                     Ref_Updates    => Ref_Updates,
                     Filter_Spec    => Filter_Spec);
               end if;

               begin
                  Validate_Local_Head_Updates (Ref_Updates);
                  Apply_Ref_Updates (Ref_Updates);
               exception
                  when others =>
                     if Filter_Spec = "" then
                        Version.Transport.Local.Rollback_Copied_Objects
                          (Copied_Targets);
                     end if;
                     raise;
               end;
            end;

         when Version.Transport.Http_Transport        =>
            Fetch_Http
              (Remote_Name   => Remote_Name,
               Url           => Url,
               Local_Git_Dir => Local_Git_Dir,
               Has_Depth     => Has_Depth,
               Depth         => Depth,
               Filter_Spec   => Filter_Spec);

         when Version.Transport.Ssh_Transport         =>
            Fetch_Ssh
              (Remote_Name   => Remote_Name,
               Url           => Url,
               Local_Git_Dir => Local_Git_Dir,
               Has_Depth     => Has_Depth,
               Depth         => Depth,
               Filter_Spec   => Filter_Spec);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with Version.Unsupported.Remote_Url;
      end case;
   end Fetch;

   procedure Fetch (Remote_Name : String) is
   begin
      Fetch (Remote_Name, False, 1);
   end Fetch;

   procedure Fetch (Remote_Name : String; Filter_Spec : String) is
   begin
      Fetch (Remote_Name, False, 1, Filter_Spec);
   end Fetch;

   procedure Fetch (Remote_Name : String; Depth : Positive) is
   begin
      Version.Shallow.Validate_Depth (Depth);
      Fetch (Remote_Name, True, Depth);
   end Fetch;

end Version.Fetch;
