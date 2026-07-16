with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Directories; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Strings.Fixed;

with Version.Files;
with Version.Repository;
with Version.Config;
with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Remotes.Test_Hooks;
with Version.Transport;
with Version.Transport.Http;
with Version.Transport.Local;
with Version.Transport.Ssh;
with Version.Upload_Pack;
with Version.Objects;
with Version.Packed_Refs;
with Version.Unsupported;

package body Version.Remotes is
   use Version.Objects;

   function Invalid_Remote_Name_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "invalid remote name: " & Name;
   end Invalid_Remote_Name_Diagnostic;

   function Remote_Already_Exists_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "remote already exists: " & Name;
   end Remote_Already_Exists_Diagnostic;

   function Remote_Does_Not_Exist_Diagnostic
     (Name : String)
      return String
   is
   begin
      return "remote does not exist: " & Name;
   end Remote_Does_Not_Exist_Diagnostic;

   function Is_Valid_Remote_Name (Name : String) return Boolean is
   begin
      return Version.Ref_Names.Is_Valid_Remote_Name (Name);
   end Is_Valid_Remote_Name;

   procedure Add_Remote (Name : String; Url : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Entries : Version.Config.Config_Entry_Vectors.Vector;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Require_Config_Scalar (Name, "remote name");
      Version.Config.Require_Config_Scalar (Url, "remote url");
      Version.Transport.Require_Supported_Url (Url);

      declare
         Existing : constant Remote_Vectors.Vector := List_Remotes;
      begin
         if not Existing.Is_Empty then
            for I in Existing.First_Index .. Existing.Last_Index loop
               if To_String (Existing.Element (I).Name) = Name then
                  raise Ada.IO_Exceptions.Data_Error
                    with Remote_Already_Exists_Diagnostic (Name);
               end if;
            end loop;
         end if;
      end;

      Entries.Append
        (Version.Config.Config_Entry'
           (Section =>
              Ada.Strings.Unbounded.To_Unbounded_String
                ("remote """ & Name & """"),

            Key     => Ada.Strings.Unbounded.To_Unbounded_String ("url"),

            Value   => Ada.Strings.Unbounded.To_Unbounded_String (Url)));

      Entries.Append
        (Version.Config.Config_Entry'
           (Section =>
              Ada.Strings.Unbounded.To_Unbounded_String
                ("remote """ & Name & """"),

            Key     => Ada.Strings.Unbounded.To_Unbounded_String ("fetch"),

            Value   =>
              Ada.Strings.Unbounded.To_Unbounded_String
                ("+refs/heads/*:refs/remotes/" & Name & "/*")));

      Version.Config.Replace_Section
        (Repo    => Repo,
         Section => "remote """ & Name & """",
         Entries => Entries);
   end Add_Remote;


   procedure Set_Url (Name : String; Url : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Existing : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);

      Entries : Version.Config.Config_Entry_Vectors.Vector;

      Section : constant String := "remote """ & Name & """";

      Found_Remote : Boolean := False;
      Found_Url    : Boolean := False;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Require_Config_Scalar (Name, "remote name");
      Version.Config.Require_Config_Scalar (Url, "remote url");
      Version.Transport.Require_Supported_Url (Url);

      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry :=
                 Existing.Element (I);

               Item_Section : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Section);

               Item_Key : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Key);
            begin
               if Item_Section = Section then
                  Found_Remote := True;

                  if Item_Key = "url" then
                     Found_Url := True;

                     Entries.Append
                       (Version.Config.Config_Entry'
                          (Section => Item.Section,
                           Key     => Item.Key,
                           Value   =>
                             Ada.Strings.Unbounded.To_Unbounded_String (Url)));
                  else
                     Entries.Append (Item);
                  end if;
               end if;
            end;
         end loop;
      end if;

      if not Found_Remote or else not Found_Url then
         raise Ada.IO_Exceptions.Data_Error
           with Remote_Does_Not_Exist_Diagnostic (Name);
      end if;

      Version.Config.Replace_Section
        (Repo => Repo, Section => Section, Entries => Entries);
   end Set_Url;

   procedure Rename_Remote (Old_Name : String; New_Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Existing : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);

      Entries : Version.Config.Config_Entry_Vectors.Vector;

      Old_Section : constant String := "remote """ & Old_Name & """";
      New_Section : constant String := "remote """ & New_Name & """";

      Found_Old : Boolean := False;
      Found_New : Boolean := False;
   begin
      if not Is_Valid_Remote_Name (Old_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Old_Name);
      end if;

      if not Is_Valid_Remote_Name (New_Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (New_Name);
      end if;

      Version.Config.Require_Config_Scalar (Old_Name, "remote name");
      Version.Config.Require_Config_Scalar (New_Name, "remote name");

      if not Existing.Is_Empty then
         for I in Existing.First_Index .. Existing.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry :=
                 Existing.Element (I);

               Item_Section : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Section);
            begin
               if Item_Section = Old_Section then
                  Found_Old := True;

                  Entries.Append
                    (Version.Config.Config_Entry'
                       (Section =>
                          Ada.Strings.Unbounded.To_Unbounded_String
                            (New_Section),
                        Key     => Item.Key,
                        Value   => Item.Value));

               elsif Item_Section = New_Section then
                  Found_New := True;
               end if;
            end;
         end loop;
      end if;

      if not Found_Old then
         raise Ada.IO_Exceptions.Data_Error
           with Remote_Does_Not_Exist_Diagnostic (Old_Name);
      end if;

      if Found_New then
         raise Ada.IO_Exceptions.Data_Error
           with Remote_Already_Exists_Diagnostic (New_Name);
      end if;

      Version.Config.Replace_Section
        (Repo => Repo, Section => Old_Section, Entries => Entries);
   end Rename_Remote;

   function List_Remotes return Remote_Vectors.Vector is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;

      Items : constant Version.Config.Config_Entry_Vectors.Vector :=
        Version.Config.Read_All (Repo);

      Result : Remote_Vectors.Vector;

      Prefix : constant String := "remote """;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Item : constant Version.Config.Config_Entry :=
                 Items.Element (I);

               Section : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Section);

               Key : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Key);

               Value : constant String :=
                 Ada.Strings.Unbounded.To_String (Item.Value);
            begin
               if Section'Length > Prefix'Length
                 and then
                   Section (Section'First .. Section'First + Prefix'Length - 1)
                   = Prefix
                 and then Section (Section'Last) = '"'
                 and then Key = "url"
               then
                  declare
                     Name : constant String :=
                       Section
                         (Section'First + Prefix'Length .. Section'Last - 1);
                  begin
                     Result.Append
                       (Remote'
                          (Name =>
                             Ada.Strings.Unbounded.To_Unbounded_String (Name),

                           Url  =>
                             Ada.Strings.Unbounded.To_Unbounded_String
                               (Value)));
                  end;
               end if;
            end;
         end loop;
      end if;

      return Result;
   end List_Remotes;

   function Get_Url (Name : String) return String is
      Items : constant Remote_Vectors.Vector := List_Remotes;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Items.Element (I).Name) = Name
            then
               return Ada.Strings.Unbounded.To_String (Items.Element (I).Url);
            end if;
         end loop;
      end if;

      raise Ada.IO_Exceptions.Data_Error with Remote_Does_Not_Exist_Diagnostic (Name);
   end Get_Url;

   function Get_Url_Text (Name : String) return String is
   begin
      return Get_Url (Name) & Character'Val (10);
   end Get_Url_Text;

   function Remote_Exists (Name : String) return Boolean is
      Items : constant Remote_Vectors.Vector := List_Remotes;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Require_Config_Scalar (Name, "remote name");

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Ada.Strings.Unbounded.To_String (Items.Element (I).Name) = Name
            then
               return True;
            end if;
         end loop;
      end if;

      return False;
   end Remote_Exists;

   package String_Sets is new
     Ada.Containers.Indefinite_Ordered_Sets (Element_Type => String);

   package String_Maps is new
     Ada.Containers.Indefinite_Ordered_Maps
       (Key_Type     => String,
        Element_Type => String);

   type Collecting_Consumer is new Version.Transport.Http.Byte_Consumer
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

   function Branches_From_Upload_Pack_Refs
     (Discovery : Version.Upload_Pack.Discovery_Result) return String_Sets.Set
   is
      Prefix : constant String := "refs/heads/";
      Result : String_Sets.Set;
   begin
      if not Discovery.Refs.Is_Empty then
         for I in Discovery.Refs.First_Index .. Discovery.Refs.Last_Index loop
            declare
               Ref_Name : constant String :=
                 To_String (Discovery.Refs.Element (I).Name);
            begin
               if Ref_Name'Length > Prefix'Length
                 and then
                   Ref_Name
                     (Ref_Name'First .. Ref_Name'First + Prefix'Length - 1)
                   = Prefix
               then
                  declare
                     Branch : constant String :=
                       Ref_Name
                         (Ref_Name'First + Prefix'Length .. Ref_Name'Last);
                  begin
                     if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
                        Result.Include (Branch);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Branches_From_Upload_Pack_Refs;

   function Branches_From_Upload_Pack_Discovery
     (Data : Ada.Streams.Stream_Element_Array) return String_Sets.Set
   is
   begin
      return Branches_From_Upload_Pack_Refs
        (Version.Upload_Pack.Parse_Discovery (Data));
   end Branches_From_Upload_Pack_Discovery;

   function Branches_From_Upload_Pack_Advertisement
     (Data : Ada.Streams.Stream_Element_Array) return String_Sets.Set
   is
   begin
      return Branches_From_Upload_Pack_Refs
        (Version.Upload_Pack.Parse_Advertisement (Data));
   end Branches_From_Upload_Pack_Advertisement;

   procedure Include_Head_Refs_In_Directory
     (Base_Dir : String; Prefix : String; Result : in out String_Sets.Set)
   is
      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if not Ada.Directories.Exists (Base_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Base_Dir,
         Pattern   => "*",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Simple : constant String := Ada.Directories.Simple_Name (E);
            Full   : constant String := Ada.Directories.Full_Name (E);
            Name   : constant String :=
              (if Prefix'Length = 0 then Simple else Prefix & "/" & Simple);
         begin
            if Simple = "." or else Simple = ".." then
               null;
            elsif Ada.Directories.Kind (E) = Ada.Directories.Directory then
               Include_Head_Refs_In_Directory
                 (Base_Dir => Full, Prefix => Name, Result => Result);
            elsif Simple'Length >= 5
              and then Simple (Simple'Last - 4 .. Simple'Last) = ".lock"
            then
               null;
            elsif Version.Ref_Names.Is_Valid_Branch_Name (Name) then
               declare
                  Id_Text : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Full),
                       Ada.Strings.Both);
               begin
                  if Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                     Result.Include (Name);
                  end if;
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
   end Include_Head_Refs_In_Directory;

   procedure Include_Packed_Head_Refs
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String;
      Result : in out String_Sets.Set)
   is
      Items : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Items.Element (I).Name);
         begin
            if Ref_Name'Length > Prefix'Length
              and then
                Ref_Name (Ref_Name'First .. Ref_Name'First + Prefix'Length - 1)
                = Prefix
            then
               declare
                  Branch : constant String :=
                    Ref_Name (Ref_Name'First + Prefix'Length .. Ref_Name'Last);
               begin
                  if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
                     Result.Include (Branch);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Include_Packed_Head_Refs;

   function Local_Remote_Tracking_Branches
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String_Sets.Set
   is
      Result : String_Sets.Set;
      Prefix : constant String := "refs/remotes/" & Name & "/";
   begin
      Include_Head_Refs_In_Directory
        (Base_Dir =>
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Common_Git_Dir (Repo), "refs"),
                 "remotes"),
              Name),
         Prefix   => "",
         Result   => Result);

      Include_Packed_Head_Refs
        (Repo => Repo, Prefix => Prefix, Result => Result);

      Result.Exclude ("HEAD");
      return Result;
   end Local_Remote_Tracking_Branches;

   procedure Include_Head_Ref_Ids_In_Directory
     (Base_Dir : String; Prefix : String; Result : in out String_Maps.Map)
   is
      Search : Ada.Directories.Search_Type;
      Dir_Entry : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if not Ada.Directories.Exists (Base_Dir) then
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Base_Dir,
         Pattern   => "");
      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Dir_Entry);

         declare
            Simple : constant String := Ada.Directories.Simple_Name (Dir_Entry);
            Full   : constant String := Ada.Directories.Full_Name (Dir_Entry);
            Name   : constant String :=
              (if Prefix'Length = 0 then Simple else Prefix & "/" & Simple);
         begin
            if Simple = "." or else Simple = ".." then
               null;
            elsif Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Directory then
               Include_Head_Ref_Ids_In_Directory (Full, Name, Result);
            elsif Ada.Directories.Kind (Dir_Entry) = Ada.Directories.Ordinary_File
              and then Version.Ref_Names.Is_Valid_Branch_Name (Name)
            then
               declare
                  Id_Text : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Version.Transport.Local.Read_First_Line (Full),
                       Ada.Strings.Both);
               begin
                  if Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
                     Result.Include (Name, Id_Text);
                  end if;
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
   end Include_Head_Ref_Ids_In_Directory;

   procedure Include_Packed_Head_Ref_Ids
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String;
      Result : in out String_Maps.Map)
   is
      Items : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Items.Element (I).Name);
         begin
            if Ref_Name'Length > Prefix'Length
              and then
                Ref_Name (Ref_Name'First .. Ref_Name'First + Prefix'Length - 1)
                = Prefix
            then
               declare
                  Branch : constant String :=
                    Ref_Name (Ref_Name'First + Prefix'Length .. Ref_Name'Last);
               begin
                  if Version.Ref_Names.Is_Valid_Branch_Name (Branch)
                    and then not Result.Contains (Branch)
                  then
                     Result.Include (Branch, To_String (Items.Element (I).Id));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Include_Packed_Head_Ref_Ids;

   function Local_Remote_Tracking_Branch_Ids
     (Repo : Version.Repository.Repository_Handle; Name : String)
      return String_Maps.Map
   is
      Result : String_Maps.Map;
      Prefix : constant String := "refs/remotes/" & Name & "/";
   begin
      Include_Head_Ref_Ids_In_Directory
        (Base_Dir =>
           Version.Files.Join
             (Version.Files.Join
                (Version.Files.Join
                   (Version.Repository.Common_Git_Dir (Repo), "refs"),
                 "remotes"),
              Name),
         Prefix   => "",
         Result   => Result);

      Include_Packed_Head_Ref_Ids
        (Repo => Repo, Prefix => Prefix, Result => Result);

      Result.Exclude ("HEAD");
      return Result;
   end Local_Remote_Tracking_Branch_Ids;

   procedure Include_Packed_Head_Refs_From_Git_Dir
     (Git_Dir : String; Result : in out String_Sets.Set)
   is
      Repo         : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open_Git_Dir (Git_Dir);
      Items        : constant Version.Packed_Refs.Packed_Ref_Vectors.Vector :=
        Version.Packed_Refs.Read_All (Repo);
      Heads_Prefix : constant String := "refs/heads/";
   begin
      if Items.Is_Empty then
         return;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         declare
            Ref_Name : constant String := To_String (Items.Element (I).Name);
         begin
            if Ref_Name'Length > Heads_Prefix'Length
              and then
                Ref_Name (Ref_Name'First .. Ref_Name'First + Heads_Prefix'Length - 1)
                = Heads_Prefix
            then
               declare
                  Branch : constant String :=
                    Ref_Name
                      (Ref_Name'First + Heads_Prefix'Length .. Ref_Name'Last);
               begin
                  if Version.Ref_Names.Is_Valid_Branch_Name (Branch) then
                     Result.Include (Branch);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Include_Packed_Head_Refs_From_Git_Dir;

   function Local_Remote_Advertised_Branches
     (Remote_Git_Dir : String) return String_Sets.Set
   is
      Result : String_Sets.Set;
   begin
      Include_Head_Refs_In_Directory
        (Base_Dir => Version.Files.Join (Remote_Git_Dir, "refs/heads"),
         Prefix   => "",
         Result   => Result);

      Include_Packed_Head_Refs_From_Git_Dir
        (Git_Dir => Remote_Git_Dir,
         Result  => Result);

      return Result;
   end Local_Remote_Advertised_Branches;

   function Http_Remote_Advertised_Branches
     (Url : String) return String_Sets.Set
   is
      Consumer : Collecting_Consumer;
   begin
      Version.Transport.Http.Discover_Upload_Pack
        (Url => Url, Consumer => Consumer);

      return Branches_From_Upload_Pack_Discovery
        (To_Stream (To_String (Consumer.Data)));
   end Http_Remote_Advertised_Branches;

   function Ssh_Remote_Advertised_Branches
     (Url : String) return String_Sets.Set
   is
      Stream : Version.Transport.Ssh.Ssh_Stream;
      Data   : Ada.Strings.Unbounded.Unbounded_String;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 8192);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Version.Transport.Ssh.Open_Upload_Pack (Url, Stream);

      loop
         Version.Transport.Ssh.Read_Some
           (Stream => Stream, Buffer => Buffer, Last => Last);

         exit when Last < Buffer'First;

         for I in Buffer'First .. Last loop
            Ada.Strings.Unbounded.Append
              (Data, Character'Val (Buffer (I)));
         end loop;
      end loop;

      if Ada.Strings.Unbounded.Length (Data) > 0 then
         Version.Transport.Ssh.Write (Stream, To_Stream ("0000"));
      end if;

      begin
         Version.Transport.Ssh.Close (Stream);
      exception
         when Ada.IO_Exceptions.Use_Error =>
            if Ada.Strings.Unbounded.Length (Data) = 0 then
               raise;
            end if;
      end;

      return Branches_From_Upload_Pack_Advertisement
        (To_Stream (To_String (Data)));
   exception
      when others =>
         Version.Transport.Ssh.Close (Stream);
         raise;
   end Ssh_Remote_Advertised_Branches;

   function Advertised_Branches (Name : String) return String_Sets.Set is
      Url : constant String := Get_Url (Name);
   begin
      case Version.Transport.Detect_Transport (Url) is
         when Version.Transport.Local_Transport       =>
            return
              Local_Remote_Advertised_Branches
                (Version.Transport.Local.Resolve_Git_Dir
                   (Version.Transport.Strip_File_Scheme (Url)));

         when Version.Transport.Http_Transport        =>
            return Http_Remote_Advertised_Branches (Url);

         when Version.Transport.Ssh_Transport         =>
            return Ssh_Remote_Advertised_Branches (Url);

         when Version.Transport.Unsupported_Transport =>
            raise Ada.IO_Exceptions.Data_Error
              with Version.Unsupported.Remote_Url;
      end case;
   end Advertised_Branches;

   function Prune_Dry_Run_Text (Name : String) return String is
      Repo       : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Local      : String_Sets.Set;
      Advertised : String_Sets.Set;
      Result     : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Require_Config_Scalar (Name, "remote name");

      if not Remote_Exists (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Remote_Does_Not_Exist_Diagnostic (Name);
      end if;

      Local := Local_Remote_Tracking_Branches (Repo, Name);
      Advertised := Advertised_Branches (Name);

      for Branch of Local loop
         if not Advertised.Contains (Branch) then
            Ada.Strings.Unbounded.Append
              (Result,
               "would prune " & Name & "/" & Branch & Character'Val (10));
         end if;
      end loop;

      return To_String (Result);
   end Prune_Dry_Run_Text;

   procedure Delete_Stale_Remote_Tracking_Refs
     (Repo     : Version.Repository.Repository_Handle;
      Name     : String;
      Branches : String_Maps.Map)
   is
      Tx : Version.Ref_Transaction.Transaction;
   begin
      if Branches.Is_Empty then
         return;
      end if;

      Version.Ref_Transaction.Start (Tx, Repo);

      for Cursor in Branches.Iterate loop
         declare
            Branch : constant String := String_Maps.Key (Cursor);
         begin
            Version.Ref_Transaction.Add_Delete
              (Item         => Tx,
               Ref_Name     => "refs/remotes/" & Name & "/" & Branch,
               Expected_Old => String_Maps.Element (Cursor));
         end;
      end loop;

      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Delete_Stale_Remote_Tracking_Refs;

   procedure Delete_Remote (Name : String) is
      Repo : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Remove_Section
        (Repo => Repo, Section => "remote """ & Name & """");

      --  `git remote remove` drops the remote-tracking refs along with the
      --  configuration; leaving refs/remotes/<name>/* behind would keep the
      --  deleted remote visible to `show-ref`, `branch -r`, and gc.
      Delete_Stale_Remote_Tracking_Refs
        (Repo     => Repo,
         Name     => Name,
         Branches => Local_Remote_Tracking_Branch_Ids (Repo, Name));
   end Delete_Remote;

   function Prune_Text (Name : String) return String is
      Repo       : constant Version.Repository.Repository_Handle :=
        Version.Repository.Open;
      Local      : String_Maps.Map;
      Advertised : String_Sets.Set;
      Stale      : String_Maps.Map;
      Result     : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if not Is_Valid_Remote_Name (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Invalid_Remote_Name_Diagnostic (Name);
      end if;

      Version.Config.Require_Config_Scalar (Name, "remote name");

      if not Remote_Exists (Name) then
         raise Ada.IO_Exceptions.Data_Error
           with Remote_Does_Not_Exist_Diagnostic (Name);
      end if;

      Local := Local_Remote_Tracking_Branch_Ids (Repo, Name);
      Advertised := Advertised_Branches (Name);

      for Cursor in Local.Iterate loop
         declare
            Branch : constant String := String_Maps.Key (Cursor);
         begin
            if not Advertised.Contains (Branch) then
               Stale.Include (Branch, String_Maps.Element (Cursor));
               Ada.Strings.Unbounded.Append
                 (Result, "pruned " & Name & "/" & Branch & Character'Val (10));
            end if;
         end;
      end loop;

      if not Stale.Is_Empty then
         Version.Remotes.Test_Hooks.Run_Prune_Before_Delete_Hook;
      end if;

      Delete_Stale_Remote_Tracking_Refs
        (Repo => Repo, Name => Name, Branches => Stale);

      return To_String (Result);
   end Prune_Text;

   function Remote_Line (Item : Remote) return String is
   begin
      return
        Ada.Strings.Unbounded.To_String (Item.Name)
        & Character'Val (9)
        & Ada.Strings.Unbounded.To_String (Item.Url);
   end Remote_Line;

   function List_Text return String is
      Items  : constant Remote_Vectors.Vector := List_Remotes;
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            Ada.Strings.Unbounded.Append
              (Result, Remote_Line (Items.Element (I)) & Character'Val (10));
         end loop;
      end if;

      return Ada.Strings.Unbounded.To_String (Result);
   end List_Text;

end Version.Remotes;
