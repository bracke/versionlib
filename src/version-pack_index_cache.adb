with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Interfaces;

with Version.Files;

package body Version.Pack_Index_Cache is
   use Version.Objects;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Interfaces;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   type Indexed_Entry is record
      Id         : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Pack_Path  : Unbounded_String;
      Offset     : U64 := 0;
      End_Offset : U64 := 0;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Indexed_Entry);

   function Less_By_Offset
     (Left  : Indexed_Entry;
      Right : Indexed_Entry)
      return Boolean
   is
   begin
      if Left.Offset = Right.Offset then
         return To_String (Left.Id) < To_String (Right.Id);
      end if;

      return Left.Offset < Right.Offset;
   end Less_By_Offset;

   package Entry_Sorting is new Entry_Vectors.Generic_Sorting
     ("<" => Less_By_Offset);

   function Read_File
     (Path : String)
      return Stream_Element_Array
   is
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Version.Files.To_Native_Path (Path));

      declare
         Size : constant Stream_IO.Count := Stream_IO.Size (File);
         Data : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
         Last : Stream_Element_Offset;
      begin
         Stream_IO.Read (File, Data, Last);
         Stream_IO.Close (File);

         if Last /= Data'Last then
            raise Ada.IO_Exceptions.Data_Error with
              "could not read complete pack index";
         end if;

         return Data;
      end;

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         raise;
   end Read_File;

   function U32_BE
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return U32
   is
   begin
      if Pos + 3 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt pack index: truncated u32";
      end if;

      return
        U32 (Data (Pos)) * 16#1000000#
        + U32 (Data (Pos + 1)) * 16#10000#
        + U32 (Data (Pos + 2)) * 16#100#
        + U32 (Data (Pos + 3));
   end U32_BE;

   function U64_BE
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return U64
   is
      Result : U64 := 0;
   begin
      if Pos + 7 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt pack index: truncated u64";
      end if;

      for I in 0 .. 7 loop
         Result :=
           Result * 256
           + U64 (Data (Pos + Stream_Element_Offset (I)));
      end loop;

      return Result;
   end U64_BE;

   function Hex_Byte
     (Data : Stream_Element_Array;
      Pos  : Stream_Element_Offset)
      return String
   is
      Hex : constant String := "0123456789abcdef";
      B   : constant Natural := Natural (Data (Pos));
   begin
      return String'
        (1 => Hex ((B / 16) + 1),
         2 => Hex ((B mod 16) + 1));
   end Hex_Byte;

   function Id_At
     (Data       : Stream_Element_Array;
      Pos        : Stream_Element_Offset;
      Raw_Length : Natural)
      return Version.Objects.Hex_Object_Id
   is
      Result : String (1 .. Raw_Length * 2);
      Outpos : Natural := Result'First;
   begin
      if Pos + Stream_Element_Offset (Raw_Length) - 1 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt pack index: truncated object name table";
      end if;

      for I in 0 .. Raw_Length - 1 loop
         declare
            Pair : constant String :=
              Hex_Byte (Data, Pos + Stream_Element_Offset (I));
         begin
            Result (Outpos) := Pair (1);
            Result (Outpos + 1) := Pair (2);
            Outpos := Outpos + 2;
         end;
      end loop;

      return Version.Objects.To_Object_Id (Result);
   end Id_At;

   function Offset_For_Index
     (Data         : Stream_Element_Array;
      Object_Count : Natural;
      Object_Index : Natural;
      Names_Start  : Stream_Element_Offset;
      Raw_Length   : Natural)
      return U64
   is
      Crc_Start : constant Stream_Element_Offset :=
        Names_Start + Stream_Element_Offset (Object_Count * Raw_Length);

      Offset_Start : constant Stream_Element_Offset :=
        Crc_Start + Stream_Element_Offset (Object_Count * 4);

      Offset_Pos : constant Stream_Element_Offset :=
        Offset_Start + Stream_Element_Offset (Object_Index * 4);

      Off32 : constant U32 := U32_BE (Data, Offset_Pos);
   begin
      if Offset_Start + Stream_Element_Offset (Object_Count * 4) - 1
        > Data'Last
      then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt pack index: truncated offset table";
      end if;

      if Off32 < 16#80000000# then
         return U64 (Off32);
      end if;

      declare
         Large_Index : constant Natural :=
           Natural (Off32 and 16#7FFFFFFF#);

         Large_Start : constant Stream_Element_Offset :=
           Offset_Start + Stream_Element_Offset (Object_Count * 4);

         Large_Pos : constant Stream_Element_Offset :=
           Large_Start + Stream_Element_Offset (Large_Index * 8);
      begin
         return U64_BE (Data, Large_Pos);
      end;
   end Offset_For_Index;

   procedure Load_Index
     (Item       : in out Cache;
      Index_Path : String;
      Pack_Path  : String;
      Algorithm  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1)
   is
      Data : constant Stream_Element_Array := Read_File (Index_Path);

      Magic : constant U32 := U32_BE (Data, Data'First);
      Ver   : constant U32 := U32_BE (Data, Data'First + 4);

      Fanout_Start : constant Stream_Element_Offset := Data'First + 8;
      Entries      : Entry_Vectors.Vector;

      Raw_Length : constant Natural := Version.Hash.Raw_Length (Algorithm);
      RL         : constant Stream_Element_Offset :=
        Stream_Element_Offset (Raw_Length);
   begin
      if Magic /= 16#FF744F63# then
         raise Ada.IO_Exceptions.Data_Error with
           "unsupported pack index: missing v2 magic";
      end if;

      if Ver /= 2 then
         raise Ada.IO_Exceptions.Data_Error with
           "unsupported pack index: only version 2 is supported";
      end if;

      if Data'Length < 8 + 256 * 4 then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt pack index: too small";
      end if;

      declare
         Object_Count : constant Natural :=
           Natural
             (U32_BE
                (Data,
                 Fanout_Start + Stream_Element_Offset (255 * 4)));

         Names_Start : constant Stream_Element_Offset :=
           Fanout_Start + Stream_Element_Offset (256 * 4);

         Pack_Size : constant U64 := U64 (Ada.Directories.Size (Pack_Path));
      begin
         if Names_Start + Stream_Element_Offset (Object_Count) * RL - 1
           > Data'Last
         then
            raise Ada.IO_Exceptions.Data_Error with
              "corrupt pack index: truncated object name table";
         end if;

         for I in 0 .. Object_Count - 1 loop
            Entries.Append
              (Indexed_Entry'(Id         =>
                   Id_At
                     (Data,
                      Names_Start + Stream_Element_Offset (I) * RL,
                      Raw_Length),
                Pack_Path  => To_Unbounded_String (Pack_Path),
                Offset     =>
                   Offset_For_Index
                     (Data         => Data,
                      Object_Count => Object_Count,
                      Object_Index => I,
                      Names_Start  => Names_Start,
                      Raw_Length   => Raw_Length),
                End_Offset => 0));
         end loop;

         if not Entries.Is_Empty then
            Entry_Sorting.Sort (Entries);

            for I in Entries.First_Index .. Entries.Last_Index loop
               declare
                  Current_Entry : Indexed_Entry := Entries.Element (I);
               begin
                  if I < Entries.Last_Index then
                     Current_Entry.End_Offset := Entries.Element (I + 1).Offset;
                  else
                     Current_Entry.End_Offset :=
                       Pack_Size - U64 (Raw_Length);
                  end if;

                  Item.Locations.Include
                    (Current_Entry.Id,
                     (Found      => True,
                      Pack_Path  => Current_Entry.Pack_Path,
                      Offset     => Current_Entry.Offset,
                      End_Offset => Current_Entry.End_Offset));
               end;
            end loop;
         end if;
      end;
   end Load_Index;

   procedure Clear (Item : in out Cache) is
   begin
      Item.Loaded := False;
      Item.Locations.Clear;
   end Clear;

   function Loaded
     (Item : Cache)
      return Boolean
   is
   begin
      return Item.Loaded;
   end Loaded;

   function Cached_Location_Count
     (Item : Cache)
      return Natural
   is
   begin
      return Natural (Item.Locations.Length);
   end Cached_Location_Count;

   procedure Load
     (Repo : Version.Repository.Repository_Handle;
      Item : in out Cache)
   is
      Pack_Dir : constant String :=
        Version.Files.Join
          (Version.Files.Join
             (Version.Repository.Common_Git_Dir (Repo), "objects"),
           "pack");

      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
   begin
      if Item.Loaded then
         return;
      end if;

      Item.Locations.Clear;

      if not Ada.Directories.Exists (Pack_Dir) then
         Item.Loaded := True;
         return;
      end if;

      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Pack_Dir,
         Pattern   => "*.idx",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => False,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Index_Path : constant String := Ada.Directories.Full_Name (E);
            Pack_Path  : constant String :=
              Index_Path (Index_Path'First .. Index_Path'Last - 3) & "pack";
         begin
            if Ada.Directories.Exists (Pack_Path) then
               Load_Index
                 (Item       => Item,
                  Index_Path => Index_Path,
                  Pack_Path  => Pack_Path,
                  Algorithm  => Version.Repository.Algorithm (Repo));
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      Item.Loaded := True;

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;

         raise;
   end Load;

   function Contains
     (Item : Cache;
      Id   : Version.Objects.Hex_Object_Id)
      return Boolean
   is
   begin
      return Item.Locations.Contains (Id);
   end Contains;

   function Locate
     (Item : Cache;
      Id   : Version.Objects.Hex_Object_Id)
      return Version.Pack.Pack_Location
   is
      Pos : constant Location_Maps.Cursor := Item.Locations.Find (Id);
   begin
      if Location_Maps.Has_Element (Pos) then
         return Location_Maps.Element (Pos);
      end if;

      return
        (Found      => False,
         Pack_Path  => Null_Unbounded_String,
         Offset     => 0,
         End_Offset => 0);
   end Locate;

   procedure Match_Prefix
     (Item   : Cache;
      Prefix : String;
      Count  : in out Natural;
      Match  : in out Version.Objects.Hex_Object_Id)
   is
      Prefix_Text : constant String := Ada.Characters.Handling.To_Lower (Prefix);
      Cursor      : Location_Maps.Cursor := Item.Locations.First;
   begin
      while Location_Maps.Has_Element (Cursor) loop
         declare
            Candidate      : constant Version.Objects.Hex_Object_Id :=
              Location_Maps.Key (Cursor);
            Candidate_Text : constant String := To_String (Candidate);
         begin
            if Candidate_Text'Length >= Prefix_Text'Length
              and then Candidate_Text
                (Candidate_Text'First .. Candidate_Text'First + Prefix_Text'Length - 1)
                = Prefix_Text
            then
               Count := Count + 1;
               Match := Candidate;
            end if;
         end;

         Location_Maps.Next (Cursor);
      end loop;
   end Match_Prefix;

end Version.Pack_Index_Cache;
