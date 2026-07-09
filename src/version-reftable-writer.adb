with Ada.Containers.Vectors;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.IO_Exceptions;
with Interfaces;              use Interfaces;
with Zlib;
with Version.Files;
with Version.Hash;

package body Version.Reftable.Writer is

   package Merge_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Ref_Record);

   procedure Auto_Compact (Repo : Version.Repository.Repository_Handle);
   procedure Merge_Two
     (Repo : Version.Repository.Repository_Handle; Older, Newer : String);

   Block_Size    : constant := 4096;
   Restart_Every : constant := 16;

   --  ---- byte emitters -------------------------------------------------

   procedure Put_Byte (Buf : in out Unbounded_String; B : Unsigned_8) is
   begin
      Append (Buf, Character'Val (Integer (B)));
   end Put_Byte;

   procedure Put_U16 (Buf : in out Unbounded_String; V : Natural) is
   begin
      Put_Byte (Buf, Unsigned_8 (V / 256 mod 256));
      Put_Byte (Buf, Unsigned_8 (V mod 256));
   end Put_U16;

   procedure Put_U24 (Buf : in out Unbounded_String; V : Natural) is
   begin
      Put_Byte (Buf, Unsigned_8 (V / 65_536 mod 256));
      Put_Byte (Buf, Unsigned_8 (V / 256 mod 256));
      Put_Byte (Buf, Unsigned_8 (V mod 256));
   end Put_U24;

   procedure Put_U64 (Buf : in out Unbounded_String; V : Long_Long_Integer) is
      Rem_V : Long_Long_Integer := V;
      Bytes : array (0 .. 7) of Unsigned_8;
   begin
      for I in reverse 0 .. 7 loop
         Bytes (I) := Unsigned_8 (Rem_V mod 256);
         Rem_V := Rem_V / 256;
      end loop;
      for I in 0 .. 7 loop
         Put_Byte (Buf, Bytes (I));
      end loop;
   end Put_U64;

   --  git reftable put_var_int: emit most-significant first, continuation bit
   --  on all but the last byte, with the "-1" bias (inverse of Get_Varint).
   procedure Put_Varint (Buf : in out Unbounded_String; Value : Unsigned_64) is
      Tmp : array (0 .. 9) of Unsigned_8 := [others => 0];
      I   : Integer := 9;
      V   : Unsigned_64 := Value;
   begin
      Tmp (9) := Unsigned_8 (V and 16#7F#);
      loop
         V := Shift_Right (V, 7);
         exit when V = 0;
         V := V - 1;
         I := I - 1;
         Tmp (I) := 16#80# or Unsigned_8 (V and 16#7F#);
      end loop;
      for K in I .. 9 loop
         Put_Byte (Buf, Tmp (K));
      end loop;
   end Put_Varint;

   function Crc32 (Data : String) return Unsigned_32 is
      C : Unsigned_32 := 16#FFFFFFFF#;
   begin
      for Ch of Data loop
         C := C xor Unsigned_32 (Character'Pos (Ch));
         for K in 1 .. 8 loop
            if (C and 1) /= 0 then
               C := Shift_Right (C, 1) xor 16#EDB88320#;
            else
               C := Shift_Right (C, 1);
            end if;
         end loop;
      end loop;
      return not C;
   end Crc32;

   --  ---- sorting -------------------------------------------------------

   function Before (Left, Right : Ref_Record) return Boolean is
     (To_String (Left.Name) < To_String (Right.Name));

   package Sorting is new Ref_Record_Vectors.Generic_Sorting ("<" => Before);

   function Common_Prefix (A, B : String) return Natural is
      N : constant Natural := Natural'Min (A'Length, B'Length);
   begin
      for I in 0 .. N - 1 loop
         if A (A'First + I) /= B (B'First + I) then
            return I;
         end if;
      end loop;
      return N;
   end Common_Prefix;

   --  ---- log helpers ---------------------------------------------------

   --  Log records sort by refname ascending, then update index descending, so
   --  that within a ref the newest reflog entry comes first. The on-disk key
   --  achieves this via refname + NUL + 8-byte big-endian (~update_index).
   function Log_Before (Left, Right : Log_Record) return Boolean is
     (if Left.Ref_Name = Right.Ref_Name
      then Left.Update_Index > Right.Update_Index
      else To_String (Left.Ref_Name) < To_String (Right.Ref_Name));

   package Log_Sorting is
     new Log_Record_Vectors.Generic_Sorting ("<" => Log_Before);

   function Log_Key (L : Log_Record) return String is
      Reversed : constant Unsigned_64 :=
        not Unsigned_64 (L.Update_Index);
      Bytes    : String (1 .. 8);
   begin
      for I in reverse 0 .. 7 loop
         Bytes (8 - I) :=
           Character'Val (Integer (Shift_Right (Reversed, I * 8) and 16#FF#));
      end loop;
      return To_String (L.Ref_Name) & Character'Val (0) & Bytes;
   end Log_Key;

   function Deflate_To_String (Raw : String) return String is
      use type Zlib.Status_Code;
      In_Arr : Zlib.Byte_Array (0 .. Raw'Length - 1);
      Status : Zlib.Status_Code;
   begin
      for I in In_Arr'Range loop
         In_Arr (I) := Zlib.Byte (Character'Pos (Raw (Raw'First + I)));
      end loop;
      declare
         Out_Arr : constant Zlib.Byte_Array :=
           Zlib.Deflate (In_Arr, Status => Status);
      begin
         if Status /= Zlib.Ok then
            raise Ada.IO_Exceptions.Data_Error
              with "reftable: log block deflate failed";
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
   end Deflate_To_String;

   --  ---- serialization -------------------------------------------------

   function Serialize
     (Refs       : Ref_Record_Vectors.Vector;
      Logs             : Log_Record_Vectors.Vector;
      Min_Update_Index : Long_Long_Integer;
      Raw_Length       : Positive)
      return String
   is
      pragma Unreferenced (Raw_Length);
      Sorted : Ref_Record_Vectors.Vector := Refs;

      package Offset_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Natural);
      Restarts : Offset_Vectors.Vector;

      Recs      : Unbounded_String;   --  record bytes (start at file offset 28)
      Prev_Key  : Unbounded_String;
      Rec_Index : Natural := 0;
   begin
      Sorting.Sort (Sorted);

      for R of Sorted loop
         declare
            Key        : constant String := To_String (R.Name);
            Is_Restart : constant Boolean :=
              (Rec_Index mod Restart_Every) = 0;
            Prefix_Len : constant Natural :=
              (if Is_Restart then 0
               else Common_Prefix (To_String (Prev_Key), Key));
            Suffix     : constant String :=
              Key (Key'First + Prefix_Len .. Key'Last);
            Val_Type   : constant Natural :=
              (case R.Kind is
                  when Ref_Direct  => 1,
                  when Ref_Peeled  => 2,
                  when Ref_Symref  => 3,
                  when Ref_Deletion => 0);
            Delta_Idx  : constant Long_Long_Integer :=
              (if R.Update_Index > Min_Update_Index
               then R.Update_Index - Min_Update_Index else 0);
         begin
            if Is_Restart then
               Restarts.Append (28 + Length (Recs));
            end if;

            Put_Varint (Recs, Unsigned_64 (Prefix_Len));
            Put_Varint (Recs, Unsigned_64 (Suffix'Length * 8 + Val_Type));
            Append (Recs, Suffix);
            Put_Varint (Recs, Unsigned_64 (Delta_Idx));

            case R.Kind is
               when Ref_Direct =>
                  Append (Recs, Version.Objects.To_Raw (R.Id));
               when Ref_Peeled =>
                  Append (Recs, Version.Objects.To_Raw (R.Id));
                  Append (Recs, Version.Objects.To_Raw (R.Peeled));
               when Ref_Symref =>
                  declare
                     Target : constant String := To_String (R.Target);
                  begin
                     Put_Varint (Recs, Unsigned_64 (Target'Length));
                     Append (Recs, Target);
                  end;
               when Ref_Deletion =>
                  null;
            end case;

            Prev_Key  := To_Unbounded_String (Key);
            Rec_Index := Rec_Index + 1;
         end;
      end loop;

      declare
         RC        : constant Natural := Natural (Restarts.Length);
         Block_Len : constant Natural := 28 + Length (Recs) + 3 * RC + 2;
         File       : Unbounded_String;
         Footer     : Unbounded_String;
         Log_Offset : Natural := 0;
         Max_Update : Long_Long_Integer := Min_Update_Index;
      begin
         --  Header and footer must agree on max_update_index, so derive it
         --  before writing the header (records may carry indices above the
         --  table's base).
         for R of Sorted loop
            if R.Update_Index > Max_Update then
               Max_Update := R.Update_Index;
            end if;
         end loop;
         for L of Logs loop
            if L.Update_Index > Max_Update then
               Max_Update := L.Update_Index;
            end if;
         end loop;

         --  File header (24 bytes).
         Append (File, "REFT");
         Put_Byte (File, 1);            --  version 1
         Put_U24 (File, Block_Size);
         Put_U64 (File, Min_Update_Index);
         Put_U64 (File, Max_Update);    --  max_update_index

         --  Ref block: 'r' + uint24 length (spans the file header) + records
         --  + restart offsets + restart count. Skipped entirely for a
         --  reflog-only table (an empty ref block with restart_count 0 is
         --  invalid); the log block then becomes block 0.
         if RC > 0 then
            Put_Byte (File, Character'Pos ('r'));
            Put_U24 (File, Block_Len);
            Append (File, To_String (Recs));
            for Off of Restarts loop
               Put_U24 (File, Off);
            end loop;
            Put_U16 (File, RC);
         end if;

         --  Log block: sorted (refname asc, update index desc), prefix-
         --  compressed like ref records, then zlib-compressed. Key is
         --  refname + NUL + 8-byte big-endian (~update_index).
         if not Logs.Is_Empty then
            declare
               Sorted_Logs : Log_Record_Vectors.Vector := Logs;
               Payload   : Unbounded_String;
               Prev_Key  : Unbounded_String;
               LRestarts : Offset_Vectors.Vector;
               LIndex    : Natural := 0;
            begin
               Log_Sorting.Sort (Sorted_Logs);
               for L of Sorted_Logs loop
                  declare
                     Key : constant String := Log_Key (L);
                     Is_Restart : constant Boolean :=
                       (LIndex mod Restart_Every) = 0;
                     Prefix_Len : constant Natural :=
                       (if Is_Restart then 0
                        else Common_Prefix (To_String (Prev_Key), Key));
                     Suffix : constant String :=
                       Key (Key'First + Prefix_Len .. Key'Last);
                     Val_Type : constant Natural :=
                       (if L.Is_Deletion then 0 else 1);
                  begin
                     if Is_Restart then
                        --  Log restart offsets are relative to the block start,
                        --  which includes the 4-byte block header that is not
                        --  part of the compressed payload.
                        LRestarts.Append (4 + Length (Payload));
                     end if;
                     Put_Varint (Payload, Unsigned_64 (Prefix_Len));
                     Put_Varint
                       (Payload, Unsigned_64 (Suffix'Length * 8 + Val_Type));
                     Append (Payload, Suffix);
                     if not L.Is_Deletion then
                        Append (Payload, Version.Objects.To_Raw (L.Old_Id));
                        Append (Payload, Version.Objects.To_Raw (L.New_Id));
                        declare
                           N : constant String := To_String (L.Committer_Name);
                           E : constant String := To_String (L.Committer_Email);
                           M : constant String := To_String (L.Message);
                           TZ : constant Integer :=
                             (if L.TZ_Offset < 0
                              then L.TZ_Offset + 65_536 else L.TZ_Offset);
                        begin
                           Put_Varint (Payload, Unsigned_64 (N'Length));
                           Append (Payload, N);
                           Put_Varint (Payload, Unsigned_64 (E'Length));
                           Append (Payload, E);
                           Put_Varint (Payload, Unsigned_64 (L.Time_Seconds));
                           Put_U16 (Payload, TZ);
                           Put_Varint (Payload, Unsigned_64 (M'Length));
                           Append (Payload, M);
                        end;
                     end if;
                     Prev_Key := To_Unbounded_String (Key);
                     LIndex := LIndex + 1;
                  end;
               end loop;

               for Off of LRestarts loop
                  Put_U24 (Payload, Off);
               end loop;
               Put_U16 (Payload, Natural (LRestarts.Length));

               Log_Offset := Length (File);
               Put_Byte (File, Character'Pos ('g'));
               Put_U24 (File, 4 + Length (Payload));
               Append (File, Deflate_To_String (To_String (Payload)));
            end;
         end if;

         --  Footer (68 bytes): header echo + section offsets + crc32.
         Append (Footer, "REFT");
         Put_Byte (Footer, 1);
         Put_U24 (Footer, Block_Size);
         Put_U64 (Footer, Min_Update_Index);
         Put_U64 (Footer, Max_Update);        --  max_update_index
         Put_U64 (Footer, 0);                 --  ref_index_offset
         Put_U64 (Footer, 0);                 --  obj_offset (obj_id_len = 0)
         Put_U64 (Footer, 0);                 --  obj_index_offset
         Put_U64 (Footer, Long_Long_Integer (Log_Offset));
         Put_U64 (Footer, 0);                 --  log_index_offset

         declare
            C : constant Unsigned_32 := Crc32 (To_String (Footer));
         begin
            Put_Byte (Footer, Unsigned_8 (Shift_Right (C, 24) and 16#FF#));
            Put_Byte (Footer, Unsigned_8 (Shift_Right (C, 16) and 16#FF#));
            Put_Byte (Footer, Unsigned_8 (Shift_Right (C, 8) and 16#FF#));
            Put_Byte (Footer, Unsigned_8 (C and 16#FF#));
         end;

         Append (File, To_String (Footer));
         return To_String (File);
      end;
   end Serialize;

   --  ---- stack rewrite -------------------------------------------------

   function Hex8 (V : Unsigned_32) return String is
      Digits_Set : constant String := "0123456789abcdef";
      R : String (1 .. 8);
      X : Unsigned_32 := V;
   begin
      for I in reverse 1 .. 8 loop
         R (I) := Digits_Set (Integer (X and 16#F#) + 1);
         X := Shift_Right (X, 4);
      end loop;
      return R;
   end Hex8;

   --  Write Image as the sole table of the stack at RT_Dir and publish it in
   --  tables.list. Returns the new table's file name.
   function Publish_Single_Table
     (RT_Dir : String; Image : String) return String
   is
      Name : constant String :=
        "0x000000000001-0x000000000001-" & Hex8 (Crc32 (Image)) & ".ref";
   begin
      if not Ada.Directories.Exists (RT_Dir) then
         Ada.Directories.Create_Path (RT_Dir);
      end if;
      Version.Files.Write_Binary_File
        (Version.Files.Join (RT_Dir, Name), Image);
      Version.Files.Write_Binary_File
        (Version.Files.Join (RT_Dir, "tables.list"),
         Name & Character'Val (10));
      return Name;
   end Publish_Single_Table;

   procedure Initialize_Stack
     (Common_Git_Dir : String;
      Default_Branch : String;
      Raw_Length     : Positive)
   is
      RT_Dir : constant String :=
        Version.Files.Join (Common_Git_Dir, "reftable");
      Refs   : Ref_Record_Vectors.Vector;
   begin
      Refs.Append
        (Ref_Record'
           (Name   => To_Unbounded_String ("HEAD"),
            Kind   => Ref_Symref,
            Target => To_Unbounded_String ("refs/heads/" & Default_Branch),
            others => <>));
      declare
         Name : constant String :=
           Publish_Single_Table
             (RT_Dir,
              Serialize
                (Refs, Log_Record_Vectors.Empty_Vector, 1, Raw_Length));
         pragma Unreferenced (Name);
      begin
         null;
      end;
   end Initialize_Stack;

   procedure Write_Stack
     (Repo : Version.Repository.Repository_Handle;
      Refs : Ref_Record_Vectors.Vector;
      Logs : Log_Record_Vectors.Vector := Log_Record_Vectors.Empty_Vector)
   is
      RT_Dir : constant String :=
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "reftable");
      RL     : constant Positive :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
      Image  : constant String := Serialize (Refs, Logs, 1, RL);
      List_Path : constant String := Version.Files.Join (RT_Dir, "tables.list");

      Old_Tables : Ref_Record_Vectors.Vector;
   begin
      --  Remember the current stack (before publishing overwrites the list) so
      --  we can drop the superseded tables afterwards.
      if Ada.Directories.Exists (List_Path) then
         declare
            Content : constant String :=
              Version.Files.Read_Binary_File (List_Path);
            Start   : Natural := Content'First;
         begin
            for I in Content'Range loop
               if Content (I) = Character'Val (10) then
                  if I > Start then
                     Old_Tables.Append
                       (Ref_Record'(Name => To_Unbounded_String
                                      (Content (Start .. I - 1)),
                                    others => <>));
                  end if;
                  Start := I + 1;
               end if;
            end loop;
            if Start <= Content'Last then
               Old_Tables.Append
                 (Ref_Record'(Name => To_Unbounded_String
                                (Content (Start .. Content'Last)),
                              others => <>));
            end if;
         end;
      end if;

      declare
         Name : constant String := Publish_Single_Table (RT_Dir, Image);
      begin
         --  Remove superseded tables (never the one we just wrote).
         for T of Old_Tables loop
            if To_String (T.Name) /= Name then
               declare
                  P : constant String :=
                    Version.Files.Join (RT_Dir, To_String (T.Name));
               begin
                  if Ada.Directories.Exists (P) then
                     Ada.Directories.Delete_File (P);
                  end if;
               end;
            end if;
         end loop;
      end;
   end Write_Stack;

   --  ---- incremental append + geometric compaction ---------------------

   function Hex12 (V : Long_Long_Integer) return String is
      Digits_Set : constant String := "0123456789abcdef";
      R : String (1 .. 12);
      X : Long_Long_Integer := V;
   begin
      for I in reverse 1 .. 12 loop
         R (I) := Digits_Set (Integer (X mod 16) + 1);
         X := X / 16;
      end loop;
      return R;
   end Hex12;

   --  A table file name encoding its update-index range, as git writes them.
   function Table_Name
     (Min_Idx, Max_Idx : Long_Long_Integer; Image : String) return String is
     ("0x" & Hex12 (Min_Idx) & "-0x" & Hex12 (Max_Idx)
      & "-" & Hex8 (Crc32 (Image)) & ".ref");

   --  Append File_Name as a new newest entry in tables.list.
   procedure Append_To_List (RT_Dir : String; File_Name : String) is
      List_Path : constant String :=
        Version.Files.Join (RT_Dir, "tables.list");
      Existing  : constant String :=
        (if Ada.Directories.Exists (List_Path)
         then Version.Files.Read_Binary_File (List_Path) else "");
   begin
      Version.Files.Write_Binary_File
        (List_Path, Existing & File_Name & Character'Val (10));
   end Append_To_List;

   procedure Append_Table
     (Repo    : Version.Repository.Repository_Handle;
      Refs    : Ref_Record_Vectors.Vector;
      Deleted : Ref_Record_Vectors.Vector := Ref_Record_Vectors.Empty_Vector;
      Logs    : Log_Record_Vectors.Vector := Log_Record_Vectors.Empty_Vector)
   is
      RT_Dir : constant String :=
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "reftable");
      RL     : constant Positive :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
      New_Idx : constant Long_Long_Integer :=
        Version.Reftable.Current_Max_Update_Index (Repo) + 1;
      Combined_Refs : Ref_Record_Vectors.Vector;
      Combined_Logs : Log_Record_Vectors.Vector;
   begin
      for R of Refs loop
         declare
            RR : Ref_Record := R;
         begin
            RR.Update_Index := New_Idx;
            Combined_Refs.Append (RR);
         end;
      end loop;
      for D of Deleted loop
         Combined_Refs.Append
           (Ref_Record'(Name         => D.Name,
                        Kind         => Ref_Deletion,
                        Update_Index => New_Idx,
                        others       => <>));
      end loop;
      for L of Logs loop
         declare
            LL : Log_Record := L;
         begin
            LL.Update_Index := New_Idx;
            Combined_Logs.Append (LL);
         end;
      end loop;

      declare
         Image : constant String :=
           Serialize (Combined_Refs, Combined_Logs, New_Idx, RL);
      begin
         if not Ada.Directories.Exists (RT_Dir) then
            Ada.Directories.Create_Path (RT_Dir);
         end if;
         Version.Files.Write_Binary_File
           (Version.Files.Join (RT_Dir, Table_Name (New_Idx, New_Idx, Image)),
            Image);
         Append_To_List (RT_Dir, Table_Name (New_Idx, New_Idx, Image));
      end;

      Auto_Compact (Repo);
   end Append_Table;

   --  Merge two adjacent tables (Older below Newer) into one, preserving
   --  tombstones so older tables underneath stay masked. Rewrites tables.list
   --  to replace the pair with the merged table and deletes the two files.
   procedure Merge_Two
     (Repo : Version.Repository.Repository_Handle;
      Older, Newer : String)
   is
      RL : constant Positive :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
      RT_Dir : constant String :=
        Version.Files.Join
          (Version.Repository.Common_Git_Dir (Repo), "reftable");
      Older_Bytes : constant String :=
        Version.Files.Read_Binary_File
          (Version.Reftable.Table_Path (Repo, Older));
      Newer_Bytes : constant String :=
        Version.Files.Read_Binary_File
          (Version.Reftable.Table_Path (Repo, Newer));

      Map     : Merge_Maps.Map;
      Refs    : Ref_Record_Vectors.Vector;
      Logs    : Log_Record_Vectors.Vector;
      Min_Idx : Long_Long_Integer := Long_Long_Integer'Last;
      Max_Idx : Long_Long_Integer := 0;
   begin
      --  Newer wins on name collisions.
      for R of Parse_Table (Newer_Bytes, RL) loop
         if not Map.Contains (To_String (R.Name)) then
            Map.Insert (To_String (R.Name), R);
         end if;
      end loop;
      for R of Parse_Table (Older_Bytes, RL) loop
         if not Map.Contains (To_String (R.Name)) then
            Map.Insert (To_String (R.Name), R);
         end if;
      end loop;

      for C in Map.Iterate loop
         declare
            R : constant Ref_Record := Merge_Maps.Element (C);
         begin
            Refs.Append (R);
            if R.Update_Index < Min_Idx then
               Min_Idx := R.Update_Index;
            end if;
            if R.Update_Index > Max_Idx then
               Max_Idx := R.Update_Index;
            end if;
         end;
      end loop;

      for L of Parse_Log_Records (Newer_Bytes, RL) loop
         Logs.Append (L);
      end loop;
      for L of Parse_Log_Records (Older_Bytes, RL) loop
         Logs.Append (L);
      end loop;
      for L of Logs loop
         if L.Update_Index < Min_Idx then
            Min_Idx := L.Update_Index;
         end if;
         if L.Update_Index > Max_Idx then
            Max_Idx := L.Update_Index;
         end if;
      end loop;

      if Min_Idx = Long_Long_Integer'Last then
         Min_Idx := 1;
      end if;

      declare
         Image : constant String := Serialize (Refs, Logs, Min_Idx, RL);
         New_Name : constant String := Table_Name (Min_Idx, Max_Idx, Image);
         Names : constant Version.Reftable.Name_Vectors.Vector :=
           Version.Reftable.Stack_Table_Names (Repo);
         Rebuilt : Unbounded_String;
      begin
         Version.Files.Write_Binary_File
           (Version.Files.Join (RT_Dir, New_Name), Image);

         --  Replace the Older/Newer pair (adjacent, Older then Newer) with the
         --  merged table, preserving order of the rest.
         for N of Names loop
            declare
               S : constant String := To_String (N);
            begin
               if S = Older then
                  Append (Rebuilt, New_Name & Character'Val (10));
               elsif S = Newer then
                  null;  --  dropped; represented by New_Name at Older's slot
               else
                  Append (Rebuilt, S & Character'Val (10));
               end if;
            end;
         end loop;
         Version.Files.Write_Binary_File
           (Version.Files.Join (RT_Dir, "tables.list"), To_String (Rebuilt));

         declare
            procedure Del (S : String) is
               P : constant String := Version.Reftable.Table_Path (Repo, S);
            begin
               if S /= New_Name and then Ada.Directories.Exists (P) then
                  Ada.Directories.Delete_File (P);
               end if;
            end Del;
         begin
            Del (Older);
            Del (Newer);
         end;
      end;
   end Merge_Two;

   procedure Auto_Compact
     (Repo : Version.Repository.Repository_Handle)
   is
      function Size_Of (Name : Unbounded_String) return Long_Long_Integer is
         P : constant String :=
           Version.Reftable.Table_Path (Repo, To_String (Name));
      begin
         if Ada.Directories.Exists (P) then
            return Long_Long_Integer (Ada.Directories.Size (P));
         end if;
         return 0;
      end Size_Of;
   begin
      --  Maintain a geometric stack: each table at least twice the byte size
      --  of the one above it. Merge the two newest while that is violated.
      loop
         declare
            Names : constant Version.Reftable.Name_Vectors.Vector :=
              Version.Reftable.Stack_Table_Names (Repo);
            N : constant Natural := Natural (Names.Length);
         begin
            exit when N < 2;
            declare
               Newer : constant Unbounded_String := Names.Element (N);
               Older : constant Unbounded_String := Names.Element (N - 1);
            begin
               exit when Size_Of (Older) >= 2 * Size_Of (Newer);
               Merge_Two (Repo, To_String (Older), To_String (Newer));
            end;
         end;
      end loop;
   end Auto_Compact;

end Version.Reftable.Writer;
