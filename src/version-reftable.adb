with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Containers.Indefinite_Ordered_Maps;
with Interfaces;              use Interfaces;
with Zlib;
with Version.Files;
with Version.Hash;

package body Version.Reftable is

   --  0-based byte access into a String buffer.
   function U8 (Data : String; I : Natural) return Unsigned_8 is
     (Unsigned_8 (Character'Pos (Data (Data'First + I))));

   function U64u (Data : String; I : Natural) return Unsigned_64 is
      V : Unsigned_64 := 0;
   begin
      for K in 0 .. 7 loop
         V := Shift_Left (V, 8) or Unsigned_64 (U8 (Data, I + K));
      end loop;
      return V;
   end U64u;

   function U16 (Data : String; I : Natural) return Natural is
     (Natural (U8 (Data, I)) * 256 + Natural (U8 (Data, I + 1)));

   function U24 (Data : String; I : Natural) return Natural is
     (Natural (U8 (Data, I)) * 65_536
      + Natural (U8 (Data, I + 1)) * 256
      + Natural (U8 (Data, I + 2)));

   function U64 (Data : String; I : Natural) return Long_Long_Integer is
      V : Long_Long_Integer := 0;
   begin
      for K in 0 .. 7 loop
         V := V * 256 + Long_Long_Integer (U8 (Data, I + K));
      end loop;
      return V;
   end U64;

   --  git reftable varint: 7 bits per byte, high bit continues, with the
   --  "+1" bias on each continuation (matching get_var_int in git).
   function Get_Varint
     (Data : String; Pos : in out Natural) return Long_Long_Integer
   is
      B   : Unsigned_8 := U8 (Data, Pos);
      Val : Unsigned_64 := Unsigned_64 (B and 16#7F#);
   begin
      Pos := Pos + 1;
      while (B and 16#80#) /= 0 loop
         B := U8 (Data, Pos);
         Pos := Pos + 1;
         Val := Shift_Left (Val + 1, 7) or Unsigned_64 (B and 16#7F#);
      end loop;
      return Long_Long_Integer (Val);
   end Get_Varint;

   --  Parse the ref records of one block. Region_Start is the block's byte
   --  offset; Header_Extra is 24 for the first block (its length field spans
   --  the file header) and 0 otherwise.
   procedure Parse_Ref_Block
     (Data             : String;
      Region_Start     : Natural;
      Header_Extra     : Natural;
      Min_Update_Index : Long_Long_Integer;
      Raw_Length       : Positive;
      Result           : in out Ref_Record_Vectors.Vector)
   is
      Hdr_At    : constant Natural := Region_Start + Header_Extra;
      Block_Len : constant Natural := U24 (Data, Hdr_At + 1);
      Region_End : constant Natural := Region_Start + Block_Len;
      Restart_Count : constant Natural := U16 (Data, Region_End - 2);
      Records_End   : constant Natural := Region_End - 2 - 3 * Restart_Count;
      Pos       : Natural := Hdr_At + 4;
      Prev_Key  : Unbounded_String;
   begin
      while Pos < Records_End loop
         declare
            Prefix_Len : constant Natural :=
              Natural (Get_Varint (Data, Pos));
            Sfx        : constant Long_Long_Integer := Get_Varint (Data, Pos);
            Val_Type   : constant Natural := Natural (Sfx mod 8);
            Suffix_Len : constant Natural := Natural (Sfx / 8);
            Key        : Unbounded_String;
            Rec        : Ref_Record;
         begin
            if Prefix_Len > 0 then
               Append (Key, Slice (Prev_Key, 1, Prefix_Len));
            end if;
            Append (Key, Data (Data'First + Pos .. Data'First + Pos
                                + Suffix_Len - 1));
            Pos := Pos + Suffix_Len;
            Prev_Key := Key;

            Rec.Name := Key;
            Rec.Update_Index :=
              Min_Update_Index + Get_Varint (Data, Pos);

            case Val_Type is
               when 0 =>
                  Rec.Kind := Ref_Deletion;
               when 1 =>
                  Rec.Kind := Ref_Direct;
                  Rec.Id := Version.Objects.To_Hex
                    (Data (Data'First + Pos
                           .. Data'First + Pos + Raw_Length - 1));
                  Pos := Pos + Raw_Length;
               when 2 =>
                  Rec.Kind := Ref_Peeled;
                  Rec.Id := Version.Objects.To_Hex
                    (Data (Data'First + Pos
                           .. Data'First + Pos + Raw_Length - 1));
                  Rec.Peeled := Version.Objects.To_Hex
                    (Data (Data'First + Pos + Raw_Length
                           .. Data'First + Pos + 2 * Raw_Length - 1));
                  Pos := Pos + 2 * Raw_Length;
               when 3 =>
                  Rec.Kind := Ref_Symref;
                  declare
                     Len : constant Natural := Natural (Get_Varint (Data, Pos));
                  begin
                     Rec.Target := To_Unbounded_String
                       (Data (Data'First + Pos
                              .. Data'First + Pos + Len - 1));
                     Pos := Pos + Len;
                  end;
               when others =>
                  raise Ada.IO_Exceptions.Data_Error with
                    "reftable: unknown ref value type";
            end case;

            Result.Append (Rec);
         end;
      end loop;
   end Parse_Ref_Block;

   function Parse_Table
     (Bytes      : String;
      Raw_Length : Positive)
      return Ref_Record_Vectors.Vector
   is
      Result : Ref_Record_Vectors.Vector;
   begin
      if Bytes'Length < 24
        or else Bytes (Bytes'First .. Bytes'First + 3) /= "REFT"
      then
         raise Ada.IO_Exceptions.Data_Error with "not a reftable file";
      end if;

      declare
         Block_Size       : constant Natural := U24 (Bytes, 5);
         Min_Update_Index : constant Long_Long_Integer := U64 (Bytes, 8);
      begin
         --  First block (type byte at offset 24, length spans the header).
         if U8 (Bytes, 24) = Character'Pos ('r') then
            Parse_Ref_Block
              (Bytes, 0, 24, Min_Update_Index, Raw_Length, Result);
         end if;

         --  Subsequent ref blocks are block-size aligned and come first; stop
         --  at the first non-ref (obj/log/index/padding) block.
         declare
            Off : Natural := Block_Size;
         begin
            while Off + 4 < Bytes'Length
              and then U8 (Bytes, Off) = Character'Pos ('r')
            loop
               Parse_Ref_Block
                 (Bytes, Off, 0, Min_Update_Index, Raw_Length, Result);
               Off := Off + Block_Size;
            end loop;
         end;
      end;

      return Result;
   end Parse_Table;

   ----------------------------------------------------------------------
   --  Log blocks (reflog)
   ----------------------------------------------------------------------

   function Inflate_To_String (Compressed : String) return String is
      use type Zlib.Status_Code;
      In_Arr : Zlib.Byte_Array (0 .. Compressed'Length - 1);
      Status : Zlib.Status_Code;
   begin
      for I in In_Arr'Range loop
         In_Arr (I) := Zlib.Byte (Character'Pos (Compressed (Compressed'First + I)));
      end loop;
      declare
         Out_Arr : constant Zlib.Byte_Array := Zlib.Inflate (In_Arr, Status);
      begin
         if Status /= Zlib.Ok then
            raise Ada.IO_Exceptions.Data_Error
              with "reftable: log block inflate failed";
         end if;
         declare
            R : String (1 .. Out_Arr'Length);
         begin
            for I in Out_Arr'Range loop
               R (R'First + (I - Out_Arr'First)) :=
                 Character'Val (Integer (Out_Arr (I)));
            end loop;
            return R;
         end;
      end;
   end Inflate_To_String;

   --  Parse the log records inside a decompressed log-block payload (records
   --  followed by restart offsets + count). Keys are refname + NUL + 8-byte
   --  big-endian (~update_index), prefix-compressed like ref records.
   procedure Parse_Log_Payload
     (Payload    : String;
      Raw_Length : Positive;
      Result     : in out Log_Record_Vectors.Vector)
   is
      Restart_Count : constant Natural := U16 (Payload, Payload'Length - 2);
      Records_End   : constant Natural := Payload'Length - 2 - 3 * Restart_Count;
      Pos      : Natural := 0;
      Prev_Key : Unbounded_String;
   begin
      while Pos < Records_End loop
         declare
            Prefix_Len : constant Natural := Natural (Get_Varint (Payload, Pos));
            Sfx        : constant Long_Long_Integer := Get_Varint (Payload, Pos);
            Val_Type   : constant Natural := Natural (Sfx mod 8);
            Suffix_Len : constant Natural := Natural (Sfx / 8);
            Key        : Unbounded_String;
            Rec        : Log_Record;
         begin
            if Prefix_Len > 0 then
               Append (Key, Slice (Prev_Key, 1, Prefix_Len));
            end if;
            Append (Key, Payload (Payload'First + Pos
                                  .. Payload'First + Pos + Suffix_Len - 1));
            Pos := Pos + Suffix_Len;
            Prev_Key := Key;

            declare
               K : constant String := To_String (Key);
               L : constant Natural := K'Length;
               Idx : constant Unsigned_64 :=
                 U64u (K, L - 8);  --  last 8 bytes (0-based within K)
            begin
               Rec.Ref_Name :=
                 To_Unbounded_String (K (K'First .. K'First + L - 10));
               Rec.Update_Index := Long_Long_Integer (not Idx);
            end;

            if Val_Type = 0 then
               Rec.Is_Deletion := True;
            else
               Rec.Old_Id := Version.Objects.To_Hex
                 (Payload (Payload'First + Pos
                           .. Payload'First + Pos + Raw_Length - 1));
               Pos := Pos + Raw_Length;
               Rec.New_Id := Version.Objects.To_Hex
                 (Payload (Payload'First + Pos
                           .. Payload'First + Pos + Raw_Length - 1));
               Pos := Pos + Raw_Length;
               declare
                  Name_Len : constant Natural :=
                    Natural (Get_Varint (Payload, Pos));
               begin
                  Rec.Committer_Name := To_Unbounded_String
                    (Payload (Payload'First + Pos
                              .. Payload'First + Pos + Name_Len - 1));
                  Pos := Pos + Name_Len;
               end;
               declare
                  Email_Len : constant Natural :=
                    Natural (Get_Varint (Payload, Pos));
               begin
                  Rec.Committer_Email := To_Unbounded_String
                    (Payload (Payload'First + Pos
                              .. Payload'First + Pos + Email_Len - 1));
                  Pos := Pos + Email_Len;
               end;
               Rec.Time_Seconds := Get_Varint (Payload, Pos);
               declare
                  TZ : constant Natural := U16 (Payload, Pos);
               begin
                  Rec.TZ_Offset :=
                    (if TZ >= 32_768 then TZ - 65_536 else TZ);
                  Pos := Pos + 2;
               end;
               declare
                  Msg_Len : constant Natural :=
                    Natural (Get_Varint (Payload, Pos));
               begin
                  Rec.Message := To_Unbounded_String
                    (Payload (Payload'First + Pos
                              .. Payload'First + Pos + Msg_Len - 1));
                  Pos := Pos + Msg_Len;
               end;
            end if;

            Result.Append (Rec);
         end;
      end loop;
   end Parse_Log_Payload;

   function Parse_Log_Records
     (Bytes      : String;
      Raw_Length : Positive)
      return Log_Record_Vectors.Vector
   is
      Result : Log_Record_Vectors.Vector;
   begin
      if Bytes'Length < 24 + 68
        or else Bytes (Bytes'First .. Bytes'First + 3) /= "REFT"
      then
         return Result;
      end if;

      declare
         Footer_Start : constant Natural := Bytes'Length - 68;
         Log_Offset   : constant Long_Long_Integer :=
           U64 (Bytes, Footer_Start + 48);
      begin
         if Log_Offset <= 0 then
            return Result;
         end if;

         declare
            Off : constant Natural := Natural (Log_Offset);
         begin
            if Off >= Footer_Start
              or else U8 (Bytes, Off) /= Character'Pos ('g')
            then
               return Result;
            end if;

            --  Single log block: the zlib stream runs from just after the
            --  4-byte block header to the start of the footer.
            declare
               Compressed : constant String :=
                 Bytes (Bytes'First + Off + 4 .. Bytes'First + Footer_Start - 1);
               Payload    : constant String := Inflate_To_String (Compressed);
            begin
               Parse_Log_Payload (Payload, Raw_Length, Result);
            end;
         end;
      end;
      return Result;
   end Parse_Log_Records;

   ----------------------------------------------------------------------
   --  Stack
   ----------------------------------------------------------------------

   function Reftable_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
     (Version.Files.Join
        (Version.Repository.Common_Git_Dir (Repo), "reftable"));

   function Is_Reftable
     (Repo : Version.Repository.Repository_Handle) return Boolean is
   begin
      return Ada.Directories.Exists
        (Version.Files.Join (Reftable_Dir (Repo), "tables.list"));
   end Is_Reftable;

   function Raw_Length_Of
     (Repo : Version.Repository.Repository_Handle) return Positive is
     (Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo)));

   package Name_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Ref_Record);

   --  Merge the whole stack newest-first into a name->record map (first writer
   --  wins because we walk newest to oldest); deletions are kept so they mask
   --  older tables, then filtered out by callers.
   procedure Merge_Stack
     (Repo : Version.Repository.Repository_Handle;
      Map  : out Name_Maps.Map)
   is
      List_Path : constant String :=
        Version.Files.Join (Reftable_Dir (Repo), "tables.list");
      RL : constant Positive := Raw_Length_Of (Repo);
   begin
      Map := Name_Maps.Empty_Map;
      if not Ada.Directories.Exists (List_Path) then
         return;
      end if;

      declare
         Content : constant String := Version.Files.Read_Binary_File (List_Path);
         --  Split into lines; walk newest (last) to oldest (first).
         Files   : Ref_Record_Vectors.Vector;  --  reuse Name field as filename
         Start   : Natural := Content'First;
      begin
         for I in Content'Range loop
            if Content (I) = Character'Val (10) then
               if I > Start then
                  Files.Append
                    (Ref_Record'(Name => To_Unbounded_String
                                   (Content (Start .. I - 1)), others => <>));
               end if;
               Start := I + 1;
            end if;
         end loop;
         if Start <= Content'Last then
            Files.Append
              (Ref_Record'(Name => To_Unbounded_String
                             (Content (Start .. Content'Last)), others => <>));
         end if;

         for Idx in reverse Files.First_Index .. Files.Last_Index loop
            declare
               Table_Path : constant String :=
                 Version.Files.Join
                   (Reftable_Dir (Repo), To_String (Files.Element (Idx).Name));
            begin
               if Ada.Directories.Exists (Table_Path) then
                  for R of Parse_Table
                    (Version.Files.Read_Binary_File (Table_Path), RL)
                  loop
                     if not Map.Contains (To_String (R.Name)) then
                        Map.Insert (To_String (R.Name), R);
                     end if;
                  end loop;
               end if;
            end;
         end loop;
      end;
   end Merge_Stack;

   function Live_Refs
     (Repo : Version.Repository.Repository_Handle)
      return Ref_Record_Vectors.Vector
   is
      Map    : Name_Maps.Map;
      Result : Ref_Record_Vectors.Vector;
   begin
      Merge_Stack (Repo, Map);
      for C in Map.Iterate loop
         if Name_Maps.Element (C).Kind /= Ref_Deletion then
            Result.Append (Name_Maps.Element (C));
         end if;
      end loop;
      return Result;   --  ordered map iterates by name
   end Live_Refs;

   procedure Set_In
     (Refs : in out Ref_Record_Vectors.Vector;
      Rec  : Ref_Record) is
   begin
      for I in Refs.First_Index .. Refs.Last_Index loop
         if To_String (Refs.Element (I).Name) = To_String (Rec.Name) then
            Refs.Replace_Element (I, Rec);
            return;
         end if;
      end loop;
      Refs.Append (Rec);
   end Set_In;

   procedure Delete_In
     (Refs : in out Ref_Record_Vectors.Vector;
      Name : String) is
   begin
      for I in Refs.First_Index .. Refs.Last_Index loop
         if To_String (Refs.Element (I).Name) = Name then
            Refs.Delete (I);
            return;
         end if;
      end loop;
   end Delete_In;

   function Find
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Found : out Boolean)
      return Ref_Record
   is
      Map : Name_Maps.Map;
   begin
      Merge_Stack (Repo, Map);
      if Map.Contains (Name)
        and then Map.Element (Name).Kind /= Ref_Deletion
      then
         Found := True;
         return Map.Element (Name);
      end if;
      Found := False;
      return Ref_Record'(others => <>);
   end Find;

   --  Table file names from tables.list, newest last.
   function Stack_Tables
     (Repo : Version.Repository.Repository_Handle)
      return Ref_Record_Vectors.Vector
   is
      List_Path : constant String :=
        Version.Files.Join (Reftable_Dir (Repo), "tables.list");
      Files : Ref_Record_Vectors.Vector;
   begin
      if not Ada.Directories.Exists (List_Path) then
         return Files;
      end if;
      declare
         Content : constant String :=
           Version.Files.Read_Binary_File (List_Path);
         Start   : Natural := Content'First;
      begin
         for I in Content'Range loop
            if Content (I) = Character'Val (10) then
               if I > Start then
                  Files.Append
                    (Ref_Record'(Name => To_Unbounded_String
                                   (Content (Start .. I - 1)), others => <>));
               end if;
               Start := I + 1;
            end if;
         end loop;
         if Start <= Content'Last then
            Files.Append
              (Ref_Record'(Name => To_Unbounded_String
                             (Content (Start .. Content'Last)), others => <>));
         end if;
      end;
      return Files;
   end Stack_Tables;

   function Stack_Table_Names
     (Repo : Version.Repository.Repository_Handle)
      return Name_Vectors.Vector
   is
      Result : Name_Vectors.Vector;
   begin
      for T of Stack_Tables (Repo) loop
         Result.Append (T.Name);
      end loop;
      return Result;
   end Stack_Table_Names;

   function Table_Path
     (Repo : Version.Repository.Repository_Handle;
      Name : String) return String is
     (Version.Files.Join (Reftable_Dir (Repo), Name));

   function Current_Max_Update_Index
     (Repo : Version.Repository.Repository_Handle) return Long_Long_Integer
   is
      Result : Long_Long_Integer := 0;
   begin
      for T of Stack_Tables (Repo) loop
         declare
            Path : constant String :=
              Table_Path (Repo, To_String (T.Name));
         begin
            if Ada.Directories.Exists (Path) then
               declare
                  Bytes : constant String :=
                    Version.Files.Read_Binary_File (Path);
               begin
                  if Bytes'Length >= 24 + 68 then
                     declare
                        Max : constant Long_Long_Integer :=
                          U64 (Bytes, Bytes'Length - 68 + 16);
                     begin
                        if Max > Result then
                           Result := Max;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Current_Max_Update_Index;

   function Live_Logs
     (Repo : Version.Repository.Repository_Handle)
      return Log_Record_Vectors.Vector
   is
      Tables : constant Ref_Record_Vectors.Vector := Stack_Tables (Repo);
      RL     : constant Positive := Raw_Length_Of (Repo);
      Result : Log_Record_Vectors.Vector;
   begin
      --  Newest table first so newer reflog entries lead.
      for Idx in reverse Tables.First_Index .. Tables.Last_Index loop
         declare
            Table_Path : constant String :=
              Version.Files.Join
                (Reftable_Dir (Repo), To_String (Tables.Element (Idx).Name));
         begin
            if Ada.Directories.Exists (Table_Path) then
               for L of Parse_Log_Records
                 (Version.Files.Read_Binary_File (Table_Path), RL)
               loop
                  if not L.Is_Deletion then
                     Result.Append (L);
                  end if;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Live_Logs;

   function Log_For
     (Repo     : Version.Repository.Repository_Handle;
      Ref_Name : String)
      return Log_Record_Vectors.Vector
   is
      Result : Log_Record_Vectors.Vector;
   begin
      for L of Live_Logs (Repo) loop
         if To_String (L.Ref_Name) = Ref_Name then
            Result.Append (L);
         end if;
      end loop;
      return Result;
   end Log_For;

end Version.Reftable;
