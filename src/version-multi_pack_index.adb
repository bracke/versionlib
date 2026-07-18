with Ada.Calendar;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;

with Interfaces;

with Version.Files;
with Version.Hash;

package body Version.Multi_Pack_Index is

   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Ada.Calendar.Time;

   type Entry_Record is record
      --  The object id, raw.
      Id     : Unbounded_String;
      Pack   : Natural;
      Offset : Interfaces.Unsigned_32;
      --  When two packs hold the same object, git keeps the copy in the pack
      --  that was written last (midx_oid_compare: preferred pack, then the
      --  newer mtime, then the lower pack id).
      Mtime  : Ada.Calendar.Time;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Entry_Record);

   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   function Pack_Dir
     (Repo : Version.Repository.Repository_Handle)
      return String
   is (Version.Files.Join
         (Version.Files.Join
            (Version.Repository.Common_Git_Dir (Repo), "objects"),
          "pack"));

   function Midx_Path
     (Repo : Version.Repository.Repository_Handle)
      return String
   is (Version.Files.Join (Pack_Dir (Repo), "multi-pack-index"));

   function BE32 (Value : Interfaces.Unsigned_32) return String is
      Result : String (1 .. 4);
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val
             (Interfaces.Shift_Right (Value, (4 - I) * 8) and 16#FF#);
      end loop;

      return Result;
   end BE32;

   function BE64 (Value : Interfaces.Unsigned_64) return String is
      Result : String (1 .. 8);
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val
             (Interfaces.Shift_Right (Value, (8 - I) * 8) and 16#FF#);
      end loop;

      return Result;
   end BE64;

   function Raw_Digest
     (Algorithm : Version.Hash.Hash_Algorithm;
      Content   : String)
      return String
   is (case Algorithm is
         when Version.Hash.Sha1   => Version.Hash.Sha1_Raw (Content),
         when Version.Hash.Sha256 => Version.Hash.Sha256_Raw (Content));

   --  The .idx files, in the order git lists them: by name.
   function Index_Names
     (Repo : Version.Repository.Repository_Handle)
      return Name_Vectors.Vector
   is
      Result : Name_Vectors.Vector;
      Dir    : constant String := Pack_Dir (Repo);
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Dir) then
         return Result;
      end if;

      Ada.Directories.Start_Search
        (Search, Dir, "",
         [Ada.Directories.Ordinary_File => True, others => False]);

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);

         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length > 4
              and then Name (Name'Last - 3 .. Name'Last) = ".idx"
            then
               Result.Append (To_Unbounded_String (Name));
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);

      --  Sorted, as the PNAM chunk must be.
      for I in Result.First_Index + 1 .. Result.Last_Index loop
         declare
            Item_I : constant Unbounded_String := Result.Element (I);
            J      : Integer := I - 1;
         begin
            while J >= Result.First_Index
              and then To_String (Result.Element (J)) > To_String (Item_I)
            loop
               Result.Replace_Element (J + 1, Result.Element (J));
               J := J - 1;
            end loop;

            Result.Replace_Element (J + 1, Item_I);
         end;
      end loop;

      return Result;
   end Index_Names;

   --  Every object one pack index lists, with where it sits in the pack.
   procedure Read_Index
     (Path    : String;
      Pack_Id : Natural;
      Width   : Positive;
      Items   : in out Entry_Vectors.Vector)
   is
      Data : constant String := Version.Files.Read_Binary_File (Path);

      Pack_File : constant String :=
        Path (Path'First .. Path'Last - 4) & ".pack";

      Mtime : constant Ada.Calendar.Time :=
        (if Ada.Directories.Exists (Pack_File)
         then Ada.Directories.Modification_Time (Pack_File)
         else Ada.Directories.Modification_Time (Path));

      function U32 (At_Pos : Positive) return Interfaces.Unsigned_32 is
        (Interfaces.Shift_Left
           (Interfaces.Unsigned_32 (Character'Pos (Data (At_Pos))), 24)
         or Interfaces.Shift_Left
              (Interfaces.Unsigned_32 (Character'Pos (Data (At_Pos + 1))), 16)
         or Interfaces.Shift_Left
              (Interfaces.Unsigned_32 (Character'Pos (Data (At_Pos + 2))), 8)
         or Interfaces.Unsigned_32 (Character'Pos (Data (At_Pos + 3))));
   begin
      if Data'Length < 8
        or else Data (Data'First .. Data'First + 3)
                /= Character'Val (255) & "tOc"
      then
         return;
      end if;

      declare
         N        : constant Natural :=
           Natural (U32 (Data'First + 8 + 255 * 4));
         Sha_Base : constant Positive := Data'First + 8 + 256 * 4;
         Off_Base : constant Positive :=
           Sha_Base + N * Width + N * 4;
      begin
         for I in 0 .. N - 1 loop
            Items.Append
              (Entry_Record'
                 (Id     =>
                    To_Unbounded_String
                      (Data (Sha_Base + I * Width
                             .. Sha_Base + I * Width + Width - 1)),
                  Pack   => Pack_Id,
                  Offset => U32 (Off_Base + I * 4),
                  Mtime  => Mtime));
         end loop;
      end;
   end Read_Index;

   -----------
   -- Write --
   -----------

   procedure Write (Repo : Version.Repository.Repository_Handle) is
      Names : constant Name_Vectors.Vector := Index_Names (Repo);

      Algo : constant Version.Hash.Hash_Algorithm :=
        Version.Repository.Algorithm (Repo);

      Width : constant Positive := Version.Hash.Raw_Length (Algo);

      Items      : Entry_Vectors.Vector;
      Live_Names : Name_Vectors.Vector;
   begin
      if Names.Is_Empty then
         return;
      end if;

      for I in Names.First_Index .. Names.Last_Index loop
         Read_Index
           (Version.Files.Join (Pack_Dir (Repo), To_String (Names.Element (I))),
            I, Width, Items);
      end loop;

      if Items.Is_Empty then
         return;
      end if;

      --  git's midx_oid_compare: by object id, then the copy in the pack with
      --  the newer mtime, then the one in the lower-numbered pack.
      declare
         function Precedes (Left, Right : Entry_Record) return Boolean is
         begin
            if To_String (Left.Id) /= To_String (Right.Id) then
               return To_String (Left.Id) < To_String (Right.Id);
            end if;

            if Left.Mtime /= Right.Mtime then
               return Left.Mtime > Right.Mtime;
            end if;

            return Left.Pack < Right.Pack;
         end Precedes;
      begin
         for I in Items.First_Index + 1 .. Items.Last_Index loop
            declare
               Item : constant Entry_Record := Items.Element (I);
               J    : Integer := I - 1;
            begin
               while J >= Items.First_Index
                 and then Precedes (Item, Items.Element (J))
               loop
                  Items.Replace_Element (J + 1, Items.Element (J));
                  J := J - 1;
               end loop;

               Items.Replace_Element (J + 1, Item);
            end;
         end loop;
      end;

      declare
         Unique : Entry_Vectors.Vector;
      begin
         for E of Items loop
            if Unique.Is_Empty
              or else To_String (Unique.Last_Element.Id) /= To_String (E.Id)
            then
               Unique.Append (E);
            end if;
         end loop;

         Items := Unique;
      end;

      --  A pack every one of whose objects is also in a newer pack contributes
      --  nothing, and git leaves it out of the index entirely.
      declare
         Used  : array (0 .. Natural (Names.Length) - 1) of Boolean :=
           [others => False];
         Renum : array (0 .. Natural (Names.Length) - 1) of Natural :=
           [others => 0];
         Kept  : Name_Vectors.Vector;
         Next  : Natural := 0;
      begin
         for E of Items loop
            Used (E.Pack) := True;
         end loop;

         for I in Used'Range loop
            if Used (I) then
               Renum (I) := Next;
               Next := Next + 1;
               Kept.Append (Names.Element (I));
            end if;
         end loop;

         for I in Items.First_Index .. Items.Last_Index loop
            declare
               E : Entry_Record := Items.Element (I);
            begin
               E.Pack := Renum (E.Pack);
               Items.Replace_Element (I, E);
            end;
         end loop;

         Live_Names := Kept;
      end;

      declare
         Names : Name_Vectors.Vector renames Live_Names;

         Pnam : Unbounded_String;
         Oidl : Unbounded_String;
         Ooff : Unbounded_String;
         Fanout : String (1 .. 256 * 4);

         Counts : array (0 .. 255) of Interfaces.Unsigned_32 := [others => 0];
      begin
         for Name of Names loop
            Append (Pnam, To_String (Name) & Character'Val (0));
         end loop;

         --  git pads the pack-name chunk out to a 4-byte boundary
         --  (MIDX_CHUNK_ALIGNMENT); every later chunk's offset depends on it.
         while Length (Pnam) mod 4 /= 0 loop
            Append (Pnam, Character'Val (0));
         end loop;

         for E of Items loop
            declare
               Raw : constant String := To_String (E.Id);
            begin
               Counts (Character'Pos (Raw (Raw'First))) :=
                 Counts (Character'Pos (Raw (Raw'First))) + 1;

               Append (Oidl, Raw);
               Append (Ooff, BE32 (Interfaces.Unsigned_32 (E.Pack)));
               Append (Ooff, BE32 (E.Offset));
            end;
         end loop;

         declare
            Running : Interfaces.Unsigned_32 := 0;
            At_Pos  : Positive := Fanout'First;
         begin
            for I in 0 .. 255 loop
               Running := Running + Counts (I);
               Fanout (At_Pos .. At_Pos + 3) := BE32 (Running);
               At_Pos := At_Pos + 4;
            end loop;
         end;

         declare
            Chunks : constant Natural := 4;

            Header : constant String :=
              "MIDX" & Character'Val (1) & Character'Val (1)
              & Character'Val (Chunks) & Character'Val (0)
              & BE32 (Interfaces.Unsigned_32 (Names.Length));

            Table_Size : constant Natural := (Chunks + 1) * 12;

            Off_Pnam : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Header'Length + Table_Size);
            Off_Oidf : constant Interfaces.Unsigned_64 :=
              Off_Pnam + Interfaces.Unsigned_64 (Length (Pnam));
            Off_Oidl : constant Interfaces.Unsigned_64 :=
              Off_Oidf + Interfaces.Unsigned_64 (Fanout'Length);
            Off_Ooff : constant Interfaces.Unsigned_64 :=
              Off_Oidl + Interfaces.Unsigned_64 (Length (Oidl));
            Off_End  : constant Interfaces.Unsigned_64 :=
              Off_Ooff + Interfaces.Unsigned_64 (Length (Ooff));

            Body_Text : constant String :=
              Header
              & "PNAM" & BE64 (Off_Pnam)
              & "OIDF" & BE64 (Off_Oidf)
              & "OIDL" & BE64 (Off_Oidl)
              & "OOFF" & BE64 (Off_Ooff)
              & [1 .. 4 => Character'Val (0)] & BE64 (Off_End)
              & To_String (Pnam)
              & Fanout
              & To_String (Oidl)
              & To_String (Ooff);

            Path : constant String := Midx_Path (Repo);
         begin
            if Ada.Directories.Exists (Path) then
               Ada.Directories.Delete_File (Path);
            end if;

            Version.Files.Write_Binary_File
              (Path, Body_Text & Raw_Digest (Algo, Body_Text));
         end;
      end;
   end Write;

   ------------
   -- Verify --
   ------------

   function Verify
     (Repo       : Version.Repository.Repository_Handle;
      Diagnostic : out String;
      Last       : out Natural)
      return Boolean
   is
      procedure Say (Text : String) is
      begin
         Last := Natural'Min (Text'Length, Diagnostic'Length);
         Diagnostic (Diagnostic'First .. Diagnostic'First + Last - 1) :=
           Text (Text'First .. Text'First + Last - 1);
      end Say;

      Path : constant String := Midx_Path (Repo);
   begin
      Last := 0;

      if not Ada.Directories.Exists (Path) then
         return True;
      end if;

      declare
         Data : constant String := Version.Files.Read_Binary_File (Path);

         Algo : constant Version.Hash.Hash_Algorithm :=
           Version.Repository.Algorithm (Repo);

         Raw : constant Natural := Version.Hash.Raw_Length (Algo);
      begin
         if Data'Length < 12 + Raw
           or else Data (Data'First .. Data'First + 3) /= "MIDX"
         then
            Say ("multi-pack-index file is too small or not a MIDX");
            return False;
         end if;

         if Raw_Digest (Algo, Data (Data'First .. Data'Last - Raw))
            /= Data (Data'Last - Raw + 1 .. Data'Last)
         then
            Say ("the multi-pack-index file has incorrect checksum and is "
                 & "likely corrupt");
            return False;
         end if;

         --  A correct checksum only says the bytes are the ones that were
         --  written; it says nothing about whether they make sense. git also
         --  checks the structure, so corruption that was re-checksummed --
         --  or written by a broken tool -- is still caught.
         declare
            function U32 (At_Index : Natural) return Natural is
              (Natural (Character'Pos (Data (At_Index))) * 16#100_00_00#
               + Natural (Character'Pos (Data (At_Index + 1))) * 16#1_00_00#
               + Natural (Character'Pos (Data (At_Index + 2))) * 16#100#
               + Natural (Character'Pos (Data (At_Index + 3))));

            Chunk_Count : constant Natural :=
              Natural (Character'Pos (Data (Data'First + 6)));

            Table : constant Natural := Data'First + 12;
            Fanout : Natural := 0;
         begin
            --  Locate the OIDF (fanout) chunk in the chunk table.
            for I in 0 .. Chunk_Count loop
               declare
                  Entry_At : constant Natural := Table + I * 12;
               begin
                  exit when Entry_At + 11 > Data'Last;
                  if Data (Entry_At .. Entry_At + 3) = "OIDF" then
                     --  The offset is 8 bytes; the low 4 are enough here.
                     Fanout := Data'First + U32 (Entry_At + 8);
                     exit;
                  end if;
               end;
            end loop;

            if Fanout = 0 or else Fanout + 256 * 4 - 1 > Data'Last then
               Say ("multi-pack-index is missing its object fanout");
               return False;
            end if;

            declare
               Previous : Natural := 0;
            begin
               for Bucket in 0 .. 255 loop
                  declare
                     Value : constant Natural := U32 (Fanout + Bucket * 4);
                  begin
                     if Value < Previous then
                        Say ("oid fanout out of order");
                        return False;
                     end if;
                     Previous := Value;
                  end;
               end loop;
            end;
         end;

         return True;
      end;
   end Verify;

end Version.Multi_Pack_Index;
