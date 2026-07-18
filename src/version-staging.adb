with Ada.Directories;
with Ada.Environment_Variables; use Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Calendar;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Containers; use Ada.Containers;
with Version.Objects; use Version.Objects;
with Version.Hash;
with Version.Path_Safety;
with Version.Files;
with Version.Platform;
with Version.Timestamps;

package body Version.Staging is

   use Ada.Streams;

   function Join (Left, Right : String) return String renames Version.Files.Join;

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
              "could not read complete index file";
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
      return Natural
   is
   begin
      if Pos + 3 > Data'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt index: truncated u32";
      end if;

      return
        Natural (Data (Pos)) * 16#1000000#
        + Natural (Data (Pos + 1)) * 16#10000#
        + Natural (Data (Pos + 2)) * 16#100#
        + Natural (Data (Pos + 3));
   end U32_BE;

   function Scan_Index_Extensions
     (Data       : Stream_Element_Array;
      Pos        : Stream_Element_Offset;
      Raw_Length : Natural)
      return Boolean
   is
      Cursor  : Stream_Element_Offset := Pos;
      Last_Extension_Byte : constant Stream_Element_Offset :=
        Data'Last - Stream_Element_Offset (Raw_Length);
      Sparse_Index : Boolean := False;

      function Signature return String is
         Result : String (1 .. 4);
      begin
         for I in Result'Range loop
            Result (I) :=
              Character'Val (Data (Cursor + Stream_Element_Offset (I - 1)));
         end loop;

         return Result;
      end Signature;
   begin
      while Cursor <= Last_Extension_Byte loop
         if Cursor + 7 > Last_Extension_Byte then
            raise Ada.IO_Exceptions.Data_Error with
              "corrupt index: truncated extension header";
         end if;

         declare
            Ext_Name : constant String := Signature;
            Ext_Size : constant Natural := U32_BE (Data, Cursor + 4);
            Payload_Start : constant Stream_Element_Offset := Cursor + 8;
         begin
            if Payload_Start + Stream_Element_Offset (Ext_Size) - 1
              > Last_Extension_Byte
            then
               raise Ada.IO_Exceptions.Data_Error with
                 "corrupt index: extension overruns checksum";
            end if;

            if Ext_Name = "sdir" then
               Sparse_Index := True;
            end if;

            Cursor := Payload_Start + Stream_Element_Offset (Ext_Size);
         end;
      end loop;

      return Sparse_Index;
   end Scan_Index_Extensions;

   function Raw_Id_To_Hex
     (Data       : Stream_Element_Array;
      Pos        : Stream_Element_Offset;
      Raw_Length : Natural)
      return Version.Objects.Hex_Object_Id
   is
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. Raw_Length * 2);
      Outpos : Natural := 1;
      Last   : constant Stream_Element_Offset :=
        Pos + Stream_Element_Offset (Raw_Length) - 1;
   begin
      if Last > Data'Last then
         raise Ada.IO_Exceptions.Data_Error with
           "corrupt index: truncated object id";
      end if;

      for I in Pos .. Last loop
         declare
            V : constant Natural := Natural (Data (I));
         begin
            Result (Outpos)     := Hex ((V / 16) + 1);
            Result (Outpos + 1) := Hex ((V mod 16) + 1);
            Outpos := Outpos + 2;
         end;
      end loop;

      return Version.Objects.To_Object_Id (Result);
   end Raw_Id_To_Hex;

   function Mode_Image
     (Mode : Natural)
      return String
   is
   begin
      case Mode is
         when 16#81A4# =>
            return "100644";
         when 16#81ED# =>
            return "100755";
         when 16#4000# =>
            return "40000";
         when 16#A000# =>
            return "120000";
         when 16#E000# =>
            return "160000";
         when others =>
            return Natural'Image (Mode);
      end case;
   end Mode_Image;

   function Strip_Trailing_Slash (Path : String) return String is
   begin
      if Path'Length > 0 and then Path (Path'Last) = '/' then
         if Path'Length = 1 then
            return "";
         else
            return Path (Path'First .. Path'Last - 1);
         end if;
      else
         return Path;
      end if;
   end Strip_Trailing_Slash;

   function Expand_Sparse_Index
     (Repo         : Version.Repository.Repository_Handle;
      Entries      : Index_Entry_Vectors.Vector;
      Sparse_Index : Boolean)
      return Index_Entry_Vectors.Vector
   is
      Result : Index_Entry_Vectors.Vector;
   begin
      if Entries.Is_Empty then
         return Result;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         declare
            Index_Item : constant Index_Entry := Entries.Element (I);
            Mode_Text  : constant String := To_String (Index_Item.Mode);
         begin
            if Mode_Text = "40000" then
               if not Sparse_Index then
                  raise Ada.IO_Exceptions.Data_Error with
                    "unsupported index mode: " & Mode_Text;
               elsif Index_Item.Stage /= 0 then
                  raise Ada.IO_Exceptions.Data_Error with
                    "corrupt sparse index: staged sparse directory";
               end if;

               declare
                  Prefix : constant String :=
                    Strip_Trailing_Slash (To_String (Index_Item.Path));
                  Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                    Version.Objects.Flatten_Tree (Repo, Index_Item.Id);
               begin
                  if not Tree_Items.Is_Empty then
                     for J in Tree_Items.First_Index .. Tree_Items.Last_Index loop
                        declare
                           Tree_Item : constant Version.Objects.Tree_Entry :=
                             Tree_Items.Element (J);
                           Child_Path : constant String :=
                             To_String (Tree_Item.Path);
                           Full_Path : constant String :=
                             (if Prefix'Length = 0
                              then Child_Path
                              else Version.Files.Join (Prefix, Child_Path));
                        begin
                           Result.Append
                             (Index_Entry'
                                (Path  => To_Unbounded_String
                                   (Version.Path_Safety.Normalize_Relative_Path
                                      (Full_Path)),
                                 Id    => Tree_Item.Id,
                                 Mode  => Tree_Item.Mode,
                                 Stage => 0, Skip_Worktree => False));
                        end;
                     end loop;
                  end if;
               end;
            else
               Result.Append (Index_Item);
            end if;
         end;
      end loop;

      Sort_By_Path (Result);
      return Result;
   end Expand_Sparse_Index;

   --  git lets GIT_INDEX_FILE point the index somewhere else -- `filter-branch
   --  --index-filter` and `read-tree` into a temporary index depend on it.
   function Index_File_Path
     (Repo : Version.Repository.Repository_Handle)
      return String
   is
   begin
      if Ada.Environment_Variables.Exists ("GIT_INDEX_FILE")
        and then Ada.Environment_Variables.Value ("GIT_INDEX_FILE") /= ""
      then
         return Ada.Environment_Variables.Value ("GIT_INDEX_FILE");
      end if;

      return Join (Version.Repository.Git_Dir (Repo), "index");
   end Index_File_Path;

   function Load
     (Repo : Version.Repository.Repository_Handle)
      return Index_Entry_Vectors.Vector
   is
      Path : constant String := Index_File_Path (Repo);

      Result : Index_Entry_Vectors.Vector;

      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
      RL : constant Stream_Element_Offset :=
        Stream_Element_Offset (Raw_Length);
   begin
      if not Ada.Directories.Exists (Path) then
         return Result;
      end if;

      declare
         Data : constant Stream_Element_Array := Read_File (Path);
         Pos  : Stream_Element_Offset := Data'First;
      begin
         if Data'Length < 12 then
            raise Ada.IO_Exceptions.Data_Error with
              "corrupt index: too small";
         end if;

         if Character'Val (Data (Pos)) /= 'D'
           or else Character'Val (Data (Pos + 1)) /= 'I'
           or else Character'Val (Data (Pos + 2)) /= 'R'
           or else Character'Val (Data (Pos + 3)) /= 'C'
         then
            raise Ada.IO_Exceptions.Data_Error with
              "corrupt index: missing DIRC signature";
         end if;

         declare
            V : constant Natural := U32_BE (Data, Pos + 4);
            Count   : constant Natural := U32_BE (Data, Pos + 8);
         begin
            if V not in 2 | 3 then
               raise Ada.IO_Exceptions.Data_Error with
                 "unsupported index: only versions 2 and 3 are supported";
            end if;

            Pos := Pos + 12;

            for E_No in 1 .. Count loop
               declare
                  E_Start : constant Stream_Element_Offset := Pos;
               begin
                  if Pos + 41 + RL > Data'Last then
                     raise Ada.IO_Exceptions.Data_Error with
                       "corrupt index: truncated E";
                  end if;

                  declare
                     Mode        : constant Natural := U32_BE (Data, Pos + 24);
                     Id          : constant Version.Objects.Hex_Object_Id :=
                       Raw_Id_To_Hex (Data, Pos + 40, Raw_Length);
                     Flags       : constant Natural :=
                       Natural (Data (Pos + 40 + RL)) * 16#100#
                       + Natural (Data (Pos + 41 + RL));
                     Extended    : constant Boolean :=
                       (Flags / 16#4000#) mod 2 = 1;
                     Extra_Flags_Length : constant Stream_Element_Offset :=
                       (if Extended then 2 else 0);
                     Name_Len    : constant Natural := Flags mod 16#1000#;
                     Stage       : constant Natural := (Flags / 16#1000#) mod 4;
                     Name_Start  : constant Stream_Element_Offset :=
                       Pos + 42 + RL + Extra_Flags_Length;
                     Name_End    : Stream_Element_Offset;
                     Skip_Worktree : Boolean := False;
                  begin
                     if Extended and then Pos + 43 + RL > Data'Last then
                        raise Ada.IO_Exceptions.Data_Error with
                          "corrupt index: truncated extended flags";
                     end if;

                     Skip_Worktree :=
                       Extended
                       and then
                         ((Natural (Data (Pos + 42 + RL)) * 16#100#
                           + Natural (Data (Pos + 43 + RL)))
                          / 16#4000#) mod 2 = 1;

                     if Name_Len = 16#FFF# then
                        Name_End := Name_Start;

                        while Name_End <= Data'Last
                          and then Data (Name_End) /= 0
                        loop
                           Name_End := Name_End + 1;
                        end loop;

                        if Name_End > Data'Last then
                           raise Ada.IO_Exceptions.Data_Error with
                             "corrupt index: unterminated long path";
                        end if;

                        Name_End := Name_End - 1;
                     else
                        Name_End :=
                          Name_Start + Stream_Element_Offset (Name_Len) - 1;
                     end if;

                     if Name_End > Data'Last then
                        raise Ada.IO_Exceptions.Data_Error with
                          "corrupt index: truncated path";
                     end if;

                     declare
                        Name : String
                          (1 .. Integer (Name_End - Name_Start + 1));
                        J    : Natural := Name'First;
                     begin
                        for I in Name_Start .. Name_End loop
                           Name (J) := Character'Val (Data (I));
                           J := J + 1;
                        end loop;

                        Result.Append
                          (Index_Entry'(Path  => To_Unbounded_String (Name),
                                        Id    => Id,
                                        Mode  => To_Unbounded_String (Mode_Image (Mode)),
                                        Stage => Stage,
                                        Skip_Worktree => Skip_Worktree));
                     end;

                     Pos := E_Start + 42 + RL + Extra_Flags_Length
                       + Stream_Element_Offset
                           ((Natural (Name_End - Name_Start + 1) + 1));

                     while (Natural (Pos - E_Start) mod 8) /= 0 loop
                        Pos := Pos + 1;
                     end loop;

                     if Pos > Data'Last then
                        raise Ada.IO_Exceptions.Data_Error with
                          "corrupt index: E overruns file";
                     end if;
                  end;
               end;
            end loop;

            declare
               Sparse_Index : constant Boolean := Scan_Index_Extensions (Data, Pos, Raw_Length);
            begin
               return Expand_Sparse_Index (Repo, Result, Sparse_Index);
            end;
         end;
      end;
   end Load;

   procedure Append_U32_BE
   (Buffer : in out Unbounded_String;
      Value  : Natural)
   is
   begin
      Append (Buffer, Character'Val ((Value / 16#1000000#) mod 256));
      Append (Buffer, Character'Val ((Value / 16#10000#) mod 256));
      Append (Buffer, Character'Val ((Value / 16#100#) mod 256));
      Append (Buffer, Character'Val (Value mod 256));
   end Append_U32_BE;

   function Mode_Value
   (Mode : String)
      return Natural
   is
   begin
      if Mode = "100644" then
         return 16#81A4#;
      elsif Mode = "100755" then
         return 16#81ED#;
      elsif Mode = "120000" then
         return 16#A000#;
      elsif Mode = "160000" then
         return 16#E000#;
      else
         raise Ada.IO_Exceptions.Data_Error with
         "unsupported index mode: " & Mode;
      end if;
   end Mode_Value;

   function Less_Index_Entry_By_Path
     (Left  : Index_Entry;
      Right : Index_Entry)
      return Boolean
   is
   begin
      if To_String (Left.Path) = To_String (Right.Path) then
         return Left.Stage < Right.Stage;
      else
         return To_String (Left.Path) < To_String (Right.Path);
      end if;
   end Less_Index_Entry_By_Path;

   procedure Sort_By_Path
   (Entries : in out Index_Entry_Vectors.Vector)
   is
      package Index_Sorting is new Index_Entry_Vectors.Generic_Sorting
        ("<" => Less_Index_Entry_By_Path);
   begin
      if Entries.Length < 2 then
         return;
      end if;

      Index_Sorting.Sort (Entries);
   end Sort_By_Path;

   procedure Write_String_File
   (Path    : String;
      Content : String)
   is
      File : Stream_IO.File_Type;
      Data : Stream_Element_Array
      (1 .. Stream_Element_Offset (Content'Length));
   begin
      for I in Content'Range loop
         Data (Stream_Element_Offset (I - Content'First + 1)) :=
         Stream_Element (Character'Pos (Content (I)));
      end loop;

      Version.Files.Create_Parent_Directories (Path);
      Stream_IO.Create (File, Stream_IO.Out_File, Version.Files.To_Native_Path (Path));
      Stream_IO.Write (File, Data);
      Stream_IO.Close (File);

   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;

         raise;
   end Write_String_File;

   function Unix_Time
   (T : Ada.Calendar.Time)
      return Natural
   is
   begin
      return Natural (Version.Timestamps.To_Unix (T));
   end Unix_Time;
   function File_Size_Natural
   (Path : String)
      return Natural
   is
   begin
      return Natural (Ada.Directories.Size (Path));
   end File_Size_Natural;

   function Blob_Size_Natural
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Natural;

   function Entry_Mtime
     (Path : String)
      return Natural;

   function Entry_File_Size
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      Id   : Version.Objects.Hex_Object_Id;
      Mode : String)
      return Natural;
   procedure Write
      (Repo    : Version.Repository.Repository_Handle;
       Entries : Index_Entry_Vectors.Vector)
   is
      Items  : Index_Entry_Vectors.Vector := Entries;
      Buffer : Unbounded_String;
      Paths  : Version.Path_Safety.Path_Vector;

      Index_Path : constant String := Index_File_Path (Repo);

      Lock_Path : constant String := Index_Path & ".lock";
   begin
      Sort_By_Path (Items);

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            if Items.Element (I).Stage = 0 then
               Paths.Append
                 (Version.Path_Safety.Normalize_Relative_Path
                    (To_String (Items.Element (I).Path)));
            end if;
         end loop;
      end if;

      Version.Path_Safety.Check_Case_Collisions
        (Paths            => Paths,
         Case_Insensitive => Version.Platform.Is_Case_Insensitive_Default);

      Append (Buffer, "DIRC");
      --  git requires index version 3 as soon as any entry carries an
      --  extended flag such as skip-worktree; otherwise stay at version 2.
      declare
         Any_Extended : Boolean := False;
      begin
         if not Items.Is_Empty then
            for I in Items.First_Index .. Items.Last_Index loop
               if Items.Element (I).Skip_Worktree then
                  Any_Extended := True;
                  exit;
               end if;
            end loop;
         end if;
         Append_U32_BE (Buffer, (if Any_Extended then 3 else 2));
      end;
      Append_U32_BE (Buffer, Natural (Items.Length));

      if not Items.Is_Empty then
         for I in Items.First_Index .. Items.Last_Index loop
            declare
               Index_Item : constant Index_Entry := Items.Element (I);
               Path_Text  : constant String :=
                 Version.Path_Safety.Normalize_Relative_Path
                   (To_String (Index_Item.Path));
               Mode_Text  : constant String := To_String (Index_Item.Mode);
               Work_Path : constant String :=
                 Join (Version.Repository.Root_Path (Repo), Path_Text);

               Mtime : constant Natural :=
                 Entry_Mtime (Work_Path);

               File_Size : constant Natural :=
                 Entry_File_Size (Repo, Work_Path, Index_Item.Id, Mode_Text);
               Entry_Start_Length : constant Natural := Length (Buffer);

               Name_Len : constant Natural :=
                 (if Path_Text'Length >= 16#FFF#
                  then 16#FFF#
                  else Path_Text'Length);
            begin
               --  Ctime seconds/nanoseconds
               --  Ada does not expose ctime portably; use mtime.
               Append_U32_BE (Buffer, Mtime);
               Append_U32_BE (Buffer, 0);

               --  Mtime seconds/nanoseconds
               Append_U32_BE (Buffer, Mtime);
               Append_U32_BE (Buffer, 0);

               --  Dev, ino
               --  Ada does not expose these portably; zero is acceptable.
               Append_U32_BE (Buffer, 0);
               Append_U32_BE (Buffer, 0);

               --  Mode
               Append_U32_BE (Buffer, Mode_Value (Mode_Text));

               --  Uid, gid, file size
               Append_U32_BE (Buffer, 0);
               Append_U32_BE (Buffer, 0);
               Append_U32_BE (Buffer, File_Size);

               --  Object id
               Append (Buffer, To_Raw (Index_Item.Id));

               --  Flags: lower 12 bits are name length, bits 12-13 are stage,
               --  bit 14 (0x4000) marks a following extended-flags word.
               declare
                  Stage : constant Natural :=
                    (if Index_Item.Stage > 3 then 3 else Index_Item.Stage);
                  Ext_Bit : constant Natural :=
                    (if Index_Item.Skip_Worktree then 16#4000# else 0);
                  Flags : constant Natural :=
                    Name_Len + Stage * 16#1000# + Ext_Bit;
               begin
                  Append
                    (Buffer,
                     Character'Val ((Flags / 16#100#) mod 256));
                  Append
                    (Buffer,
                     Character'Val (Flags mod 256));

                  --  Extended-flags word: skip-worktree is bit 14 (0x4000).
                  if Index_Item.Skip_Worktree then
                     Append (Buffer, Character'Val (16#40#));
                     Append (Buffer, Character'Val (16#00#));
                  end if;
               end;

               --  Path + NUL
               Append (Buffer, Path_Text);
               Append (Buffer, Character'Val (0));

               --  Pad entry to multiple of 8 bytes
               while ((Length (Buffer) - Entry_Start_Length) mod 8) /= 0 loop
                  Append (Buffer, Character'Val (0));
               end loop;
            end;
         end loop;
      end if;

      declare
         Body_Text : constant String := To_String (Buffer);
         Checksum  : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Hash.Object_Hash_Hex
               (Version.Repository.Algorithm (Repo), Body_Text));
         Final_Text : constant String := Body_Text & To_Raw (Checksum);
      begin
         if Ada.Directories.Exists (Lock_Path) then
            raise Ada.IO_Exceptions.Data_Error with
              "lock file already exists: " & Lock_Path;
         end if;

         Write_String_File (Lock_Path, Final_Text);

         Version.Files.Atomic_Replace (Lock_Path, Index_Path);
      end;
   end Write;

   function Blob_Size_Natural
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Natural
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Id);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Blob_Object then
         raise Ada.IO_Exceptions.Data_Error with
           "index entry does not reference blob object";
      end if;

      return Version.Objects.Content (Obj)'Length;
   end Blob_Size_Natural;

   function Entry_Mtime
     (Path : String)
      return Natural
   is
   begin
      if Ada.Directories.Exists (Path) then
         return Unix_Time (Ada.Directories.Modification_Time (Path));
      else
         return Unix_Time (Ada.Calendar.Clock);
      end if;
   end Entry_Mtime;

   function Entry_File_Size
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      Id   : Version.Objects.Hex_Object_Id;
      Mode : String)
      return Natural
   is
   begin
      if Mode = "160000" then
         --  Gitlinks/submodules point at commits from another repository.
         --  That object is not expected to exist in this object database.
         return 0;
      elsif Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File
      then
         return File_Size_Natural (Path);
      else
         return Blob_Size_Natural (Repo, Id);
      end if;
   end Entry_File_Size;

   function Find_Stage_Entry
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String;
      Stage   : Natural)
      return Natural
   is
   begin
      if Entries.Is_Empty then
         return Natural'Last;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if To_String (Entries.Element (I).Path) = Path
           and then Entries.Element (I).Stage = Stage
         then
            return I;
         end if;
      end loop;

      return Natural'Last;
   end Find_Stage_Entry;

   function Find_Entry
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String)
      return Natural
   is
   begin
      return Find_Stage_Entry (Entries, Path, 0);
   end Find_Entry;

   function Find_Path
     (Entries : Index_Entry_Vectors.Vector;
      Path    : String)
      return Natural
   is
   begin
      return Find_Entry (Entries, Path);
   end Find_Path;

   procedure Replace_Entry
     (Entries : in out Index_Entry_Vectors.Vector;
      Current_Entry   : Index_Entry)
   is
      Pos : constant Natural :=
        Find_Stage_Entry
          (Entries, To_String (Current_Entry.Path), Current_Entry.Stage);
   begin
      if Current_Entry.Stage = 0 then
         Remove_Path (Entries, To_String (Current_Entry.Path));
      end if;

      if Pos = Natural'Last or else Current_Entry.Stage = 0 then
         Entries.Append (Current_Entry);
         Sort_By_Path (Entries);
      else
         Entries.Replace_Element (Pos, Current_Entry);
      end if;
   end Replace_Entry;

   procedure Remove_Path
     (Entries : in out Index_Entry_Vectors.Vector;
      Path    : String)
   is
   begin
      if Entries.Is_Empty then
         return;
      end if;

      declare
         Pos : Natural := Entries.First_Index;
      begin
         while Pos <= Entries.Last_Index loop
            if To_String (Entries.Element (Pos).Path) = Path then
               Entries.Delete (Pos);
               if Entries.Is_Empty then
                  return;
               end if;
            else
               Pos := Pos + 1;
            end if;
         end loop;
      end;
   end Remove_Path;

   procedure Write_From_Tree
   (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id)
   is
      Tree_Items : constant Version.Objects.Tree_Entry_Vectors.Vector :=
      Version.Objects.Flatten_Tree
         (Repo    => Repo,
         Tree_Id => Tree_Id);

      Index_Items : Index_Entry_Vectors.Vector;
   begin
      if not Tree_Items.Is_Empty then
         for I in Tree_Items.First_Index .. Tree_Items.Last_Index loop
            declare
               Tree_Item : constant Version.Objects.Tree_Entry :=
               Tree_Items.Element (I);
            begin
               declare
                  Safe_Path : constant String :=
                    Version.Path_Safety.Normalize_Relative_Path
                      (Ada.Strings.Unbounded.To_String (Tree_Item.Path));
               begin
                  Index_Items.Append
                    (Index_Entry'
                       (Path  => Ada.Strings.Unbounded.To_Unbounded_String (Safe_Path),
                        Id    => Tree_Item.Id,
                        Mode  => Tree_Item.Mode,
                        Stage => 0, Skip_Worktree => False));
               end;
            end;
         end loop;
      end if;

      Write (Repo    => Repo, Entries => Index_Items);
   end Write_From_Tree;

end Version.Staging;
