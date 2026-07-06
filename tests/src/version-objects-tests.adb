with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Compression;
with Version.Git_Fixtures;
with Version.Hash;
with Version.Refs;
with Version.Repository;
with Version.Revisions;
with Version.Test_Support;
with Version.Unsupported;
with Interfaces;   use Interfaces;
with Version.Pack; use Version.Pack;
with Version.Pack_Index_Cache;
with Version.Object_Cache;
with Version.Tree_Cache;

package body Version.Objects.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Join (Left, Right : String) return String
   renames Version.Test_Support.Join;

   procedure Write_Binary_File (Path : String; Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);

      if Content'Length > 0 then
         declare
            Data :
              Ada.Streams.Stream_Element_Array
                (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
         begin
            for I in Content'Range loop
               Data
                 (Ada.Streams.Stream_Element_Offset (I - Content'First + 1)) :=
                 Ada.Streams.Stream_Element (Character'Pos (Content (I)));
            end loop;

            Ada.Streams.Stream_IO.Write (File, Data);
         end;
      end if;

      Ada.Streams.Stream_IO.Close (File);

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Write_Binary_File;

   function U32_BE (Value : Interfaces.Unsigned_32) return String is
   begin
      return
        Character'Val (Natural (Interfaces.Shift_Right (Value, 24) and 16#FF#))
        & Character'Val
            (Natural (Interfaces.Shift_Right (Value, 16) and 16#FF#))
        & Character'Val
            (Natural (Interfaces.Shift_Right (Value, 8) and 16#FF#))
        & Character'Val (Natural (Value and 16#FF#));
   end U32_BE;

   function Canonical_Raw (Kind : String; Content : String) return String is
      Len_Image : constant String := Natural'Image (Content'Length);
   begin
      return
        Kind
        & " "
        & Len_Image (Len_Image'First + 1 .. Len_Image'Last)
        & Character'Val (0)
        & Content;
   end Canonical_Raw;

   procedure Write_Loose_Raw
     (Repo     : Version.Repository.Repository_Handle;
      Id       : Version.Objects.Hex_Object_Id;
      Raw      : String;
      Compress : Boolean := True)
   is
      Path : constant String := Version.Objects.Loose_Object_Path (Repo, Id);
      Dir  : constant String := Path (Path'First .. Path'Last - 39);
      Data : constant String :=
        (if Compress then Version.Compression.Deflate_Zlib (Raw) else Raw);
   begin
      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Directory (Dir);
      end if;

      Write_Binary_File (Path, Data);
   end Write_Loose_Raw;

   function Pack_Dir
     (Repo : Version.Repository.Repository_Handle) return String is
   begin
      return
        Join
          (Join (Version.Repository.Common_Git_Dir (Repo), "objects"), "pack");
   end Pack_Dir;

   procedure Ensure_Pack_Dir (Repo : Version.Repository.Repository_Handle) is
      Dir : constant String := Pack_Dir (Repo);
   begin
      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Directory (Dir);
      end if;
   end Ensure_Pack_Dir;

   function Pack_File
     (Object_Count   : Interfaces.Unsigned_32;
      Payload        : String;
      Valid_Checksum : Boolean := True) return String
   is
      Prefix : constant String :=
        "PACK"
        & U32_BE (Interfaces.Unsigned_32'(2))
        & U32_BE (Object_Count)
        & Payload;
      Sum    : constant String :=
        (if Valid_Checksum
         then Version.Hash.Sha1_Raw (Prefix)
         else String'(1 .. 20 => Character'Val (0)));
   begin
      return Prefix & Sum;
   end Pack_File;

   function Ref_Delta_Entry_With_Missing_Base return String is
      Delta_Data : constant String := Character'Val (0) & Character'Val (0);
      Header     : constant String := "" &
        Character'Val (16#70# + Delta_Data'Length);
   begin
      return
        Header
        & String'(1 .. 20 => Character'Val (0))
        & Version.Compression.Deflate_Zlib (Delta_Data);
   end Ref_Delta_Entry_With_Missing_Base;

   function Pack_Object_Header (Type_Code : Natural; Size : Natural) return String is
      Remaining : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Size) / 16;
      First     : Natural := Type_Code * 16 + Size mod 16;
      Result    : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Remaining /= 0 then
         First := First + 16#80#;
      end if;

      Ada.Strings.Unbounded.Append (Result, Character'Val (First));

      while Remaining /= 0 loop
         declare
            Part : Natural := Natural (Remaining mod 16#80#);
         begin
            Remaining := Remaining / 16#80#;
            if Remaining /= 0 then
               Part := Part + 16#80#;
            end if;
            Ada.Strings.Unbounded.Append (Result, Character'Val (Part));
         end;
      end loop;

      return Ada.Strings.Unbounded.To_String (Result);
   end Pack_Object_Header;

   function Hex_Nibble (C : Character) return Natural is
   begin
      if C in '0' .. '9' then
         return Character'Pos (C) - Character'Pos ('0');
      elsif C in 'a' .. 'f' then
         return Character'Pos (C) - Character'Pos ('a') + 10;
      elsif C in 'A' .. 'F' then
         return Character'Pos (C) - Character'Pos ('A') + 10;
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid object id hex digit";
      end if;
   end Hex_Nibble;

   function Raw_Id (Id : Version.Objects.Hex_Object_Id) return String is
      Result : String (1 .. 20);
      Pos    : Positive := To_String (Id)'First;
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val (Hex_Nibble (To_String (Id) (Pos)) * 16 + Hex_Nibble (To_String (Id) (Pos + 1)));
         Pos := Pos + 2;
      end loop;

      return Result;
   end Raw_Id;

   function Blob_Pack_Entry (Content : String) return String is
   begin
      return
        Pack_Object_Header (Type_Code => 3, Size => Content'Length)
        & Version.Compression.Deflate_Zlib (Content);
   end Blob_Pack_Entry;

   function Copy_Whole_Base_Delta (Base_Size : Natural) return String is
   begin
      if Base_Size > 255 then
         raise Ada.IO_Exceptions.Data_Error with "test delta base too large";
      end if;

      return
        Character'Val (Base_Size)
        & Character'Val (Base_Size)
        & Character'Val (16#90#)
        & Character'Val (Base_Size);
   end Copy_Whole_Base_Delta;

   function Ref_Delta_Entry_With_Size_Mismatch
     (Base_Id : Version.Objects.Hex_Object_Id) return String
   is
      Delta_Data : constant String := Copy_Whole_Base_Delta (3);
   begin
      return
        Pack_Object_Header (Type_Code => 7, Size => Delta_Data'Length + 1)
        & Raw_Id (Base_Id)
        & Version.Compression.Deflate_Zlib (Delta_Data);
   end Ref_Delta_Entry_With_Size_Mismatch;

   function Ofs_Delta_Entry_With_Size_Mismatch (Base_Distance : Natural) return String
   is
      Delta_Data : constant String := Copy_Whole_Base_Delta (3);
   begin
      if Base_Distance > 127 then
         raise Ada.IO_Exceptions.Data_Error with "test delta base distance too large";
      end if;

      return
        Pack_Object_Header (Type_Code => 6, Size => Delta_Data'Length + 1)
        & Character'Val (Base_Distance)
        & Version.Compression.Deflate_Zlib (Delta_Data);
   end Ofs_Delta_Entry_With_Size_Mismatch;

   procedure Expect_Data_Error (Raised : Boolean; Label : String) is
   begin
      Assert (Raised, Label & " must raise Data_Error");
   end Expect_Data_Error;

   function Contains_Path
     (Entries : Version.Objects.Tree_Entry_Vectors.Vector; Path : String)
      return Boolean is
   begin
      if Entries.Is_Empty then
         return False;
      end if;

      for I in Entries.First_Index .. Entries.Last_Index loop
         if To_String (Entries.Element (I).Path) = Path then
            return True;
         end if;
      end loop;

      return False;
   end Contains_Path;

   procedure Read_Commit_And_Tree_From_Git_Repo
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "current commit id must be a valid SHA-1 object id");

         declare
            Commit_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Commit);

            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object (Repo, Commit_Id);
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "HEAD object must be a commit object");

            declare
               Tree_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.Commit_Tree_Id (Obj);
            begin
               Assert
                 (Version.Objects.Is_Valid_Hex_Object_Id (To_String (Tree_Id)),
                  "commit tree id must be valid");

               declare
                  Entries :
                    constant Version.Objects.Tree_Entry_Vectors.Vector :=
                      Version.Objects.Flatten_Tree
                        (Repo => Repo, Tree_Id => Tree_Id);
               begin
                  Assert
                    (Contains_Path (Entries, "a.txt"),
                     "flattened tree must contain a.txt");
               end;
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Commit_And_Tree_From_Git_Repo;

   procedure Commit_Message_First_Line_From_Git_Repo
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);

         Commit_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id (Commit);

         Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         Assert
           (Version.Objects.Commit_Message_First_Line (Obj) = "initial",
            "commit message first line must be initial");

         Assert
           (Version.Objects.Commit_Parent_Id (Obj) = "",
            "first commit must not have a parent");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Commit_Message_First_Line_From_Git_Repo;

   procedure Packed_Commit_Is_Detected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before git gc must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run (Root, "git gc");

         Ada.Directories.Set_Directory (Root);

         Assert
           (Version.Pack.Contains
              (Repo, Version.Objects.To_Object_Id (Commit)),
            "packed HEAD commit must be found in pack index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Packed_Commit_Is_Detected;

   procedure Packed_Commit_Offset_Is_Found
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before git gc must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run (Root, "git gc");

         Ada.Directories.Set_Directory (Root);

         declare
            Location : constant Version.Pack.Pack_Location :=
              Version.Pack.Find_Location
                (Repo, Version.Objects.To_Object_Id (Commit));
         begin
            Assert
              (Location.Found, "packed HEAD commit location must be found");

            Assert
              (Location.Offset > 0,
               "packed object offset must be greater than zero");

            Assert
              (Ada.Strings.Unbounded.Length (Location.Pack_Path) > 0,
               "pack path must be present");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Packed_Commit_Offset_Is_Found;

   procedure Packed_Commit_Header_Is_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before git gc must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "git repack -ad --window=0 --depth=0");

         Ada.Directories.Set_Directory (Root);

         declare
            Location : constant Version.Pack.Pack_Location :=
              Version.Pack.Find_Location
                (Repo, Version.Objects.To_Object_Id (Commit));

            Header : constant Version.Pack.Packed_Object_Header :=
              Version.Pack.Read_Header (Location);
         begin
            Assert
              (Location.Found, "packed HEAD commit location must be found");

            Assert
              (Header.Kind = Version.Pack.Packed_Commit,
               "packed HEAD object must have commit type");

            Assert
              (Header.Size > 0,
               "packed object uncompressed size must be greater than zero");

            Assert
              (Header.Data_Offset > Location.Offset,
               "packed object data offset must follow object header");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Packed_Commit_Header_Is_Read;

   procedure Read_Non_Delta_Packed_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before repack must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "git repack -ad --window=0 --depth=0");

         Ada.Directories.Set_Directory (Root);

         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Commit));
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "packed object must read as commit object");

            Assert
              (Version.Objects.Commit_Message_First_Line (Obj) = "initial",
               "packed commit message must be readable");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Non_Delta_Packed_Commit;

   procedure Read_Packed_Commit_After_Git_Gc
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before git gc must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run (Root, "git gc");

         Ada.Directories.Set_Directory (Root);

         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Commit));
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "packed commit after git gc must read as commit");

            Assert
              (Version.Objects.Commit_Message_First_Line (Obj) = "initial",
               "packed commit after git gc must have readable message");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Packed_Commit_After_Git_Gc;

   procedure Read_Packed_Tree_With_Deltas
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_Similar_Files (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before git gc must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run (Root, "git gc");

         Ada.Directories.Set_Directory (Root);

         declare
            Commit_Obj : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Commit));

            Tree_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id (Commit_Obj);

            Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
              Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
         begin
            Assert
              (Contains_Path (Entries, "a.txt"), "tree must contain a.txt");

            Assert
              (Contains_Path (Entries, "b.txt"), "tree must contain b.txt");

            Assert
              (Contains_Path (Entries, "c.txt"), "tree must contain c.txt");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Read_Packed_Tree_With_Deltas;
   procedure Pack_Index_Cache_Locates_Packed_Commit
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before repack must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "git repack -ad --window=0 --depth=0");

         Ada.Directories.Set_Directory (Root);

         declare
            Cache : Version.Pack_Index_Cache.Cache;
            Id    : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Commit);
         begin
            Version.Pack_Index_Cache.Load (Repo => Repo, Item => Cache);

            Assert
              (Version.Pack_Index_Cache.Contains (Cache, Id),
               "pack-index cache must contain packed HEAD commit");

            declare
               Location : constant Version.Pack.Pack_Location :=
                 Version.Pack_Index_Cache.Locate (Cache, Id);
            begin
               Assert
                 (Location.Found,
                  "pack-index cache must return a concrete location");

               Assert
                 (Location.Offset > 0,
                  "cached packed object offset must be non-zero");

               Assert
                 (Location.End_Offset > Location.Offset,
                  "cached packed object end offset must follow start offset");
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Index_Cache_Locates_Packed_Commit;

   procedure Object_Cache_Reads_From_Pack_Index_Cache
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before repack must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "git repack -ad --window=0 --depth=0");

         Ada.Directories.Set_Directory (Root);

         declare
            Cache : Version.Object_Cache.Object_Cache;
            Obj   : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo  => Repo,
                 Cache => Cache,
                 Id    => Version.Objects.To_Object_Id (Commit));
         begin
            Assert
              (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
               "object cache must read packed commit through cached index");

            Assert
              (Version.Objects.Commit_Message_First_Line (Obj) = "initial",
               "cached packed commit must preserve commit payload");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Object_Cache_Reads_From_Pack_Index_Cache;

   procedure Command_Local_Cache_Counts_Remain_Bounded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before cache test must be valid");

         declare
            Objects      : Version.Object_Cache.Object_Cache;
            Trees        : Version.Tree_Cache.Tree_Cache;
            Commit_Id    : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Commit);
            Commit_Obj_1 : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Objects, Id => Commit_Id);
            Commit_Obj_2 : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Objects, Id => Commit_Id);
            Tree_Id      : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id (Commit_Obj_1);
            Tree_1       :
              constant Version.Objects.Tree_Entry_Vectors.Vector :=
                Version.Tree_Cache.Flatten_Tree
                  (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
            Tree_2       :
              constant Version.Objects.Tree_Entry_Vectors.Vector :=
                Version.Tree_Cache.Flatten_Tree
                  (Repo => Repo, Cache => Trees, Tree_Id => Tree_Id);
         begin
            Assert
              (Version.Objects.Kind (Commit_Obj_2)
               = Version.Objects.Commit_Object,
               "second cached object read must return the same commit object kind");

            Assert
              (Version.Object_Cache.Cached_Object_Count (Objects) = 1,
               "repeated object reads must keep one decoded object in the command cache");

            Assert
              (Natural (Tree_1.Length) = Natural (Tree_2.Length),
               "repeated cached tree flatten must preserve tree contents");

            Assert
              (Version.Tree_Cache.Cached_Tree_Count (Trees) = 1,
               "repeated tree flatten must keep one flattened tree in the command cache");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Command_Local_Cache_Counts_Remain_Bounded;

   procedure Packed_Abbreviation_Resolves_Through_Pack_Index_Cache
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Root);

      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;

         Commit : constant String := Version.Refs.Current_Commit_Id (Repo);
      begin
         Assert
           (Version.Objects.Is_Valid_Hex_Object_Id (Commit),
            "commit id before repack must be valid");

         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "git repack -ad --window=0 --depth=0");

         Ada.Directories.Set_Directory (Root);

         declare
            Abbrev : constant String :=
              Commit (Commit'First .. Commit'First + 11);
            Id     : constant Version.Objects.Hex_Object_Id :=
              Version.Revisions.Resolve (Repo, Abbrev);
         begin
            Assert
              (To_String (Id) = Commit,
               "revision abbreviation must resolve packed objects through the pack-index cache");
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Packed_Abbreviation_Resolves_Through_Pack_Index_Cache;

   procedure Missing_Object_In_Promisor_Repository_Reports_Unsupported
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Missing : constant Version.Objects.Object_Id_Storage := Version.Objects.To_Object_Id ([1 .. 40 => '2']);

      procedure Assert_Promisor_Diagnostic (Message : String) is
      begin
         Assert
           (Message = Version.Unsupported.Promisor_Objects & ": " & To_String (Missing),
            "missing promisor object returned wrong diagnostic: " & Message);
      end Assert_Promisor_Diagnostic;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File (Join (Pack_Dir (Repo), "pack-promised.promisor"), "");

         begin
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Repo, Missing);
               pragma Unreferenced (Obj);
            begin
               Assert (False, "missing promisor object must be unsupported");
            end;
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Assert_Promisor_Diagnostic (Ada.Exceptions.Exception_Message (E));
         end;

         declare
            Cache : Version.Object_Cache.Object_Cache;
         begin
            begin
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Object_Cache.Read_Object
                      (Repo => Repo, Cache => Cache, Id => Missing);
                  pragma Unreferenced (Obj);
               begin
                  Assert (False, "cached missing promisor object must be unsupported");
               end;
            exception
               when E : Ada.IO_Exceptions.Data_Error =>
                  Assert_Promisor_Diagnostic (Ada.Exceptions.Exception_Message (E));
            end;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Missing_Object_In_Promisor_Repository_Reports_Unsupported;

   procedure Partial_Clone_Read_Object_Lazily_Fetches_Local_Remote
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Source  : constant String := Join (Root, "source");
      Target  : constant String := Join (Root, "target");
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Commit  : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
   begin
      Version.Test_Support.Make_Directory (Source);
      Version.Git_Fixtures.Init_Repo_With_One_Commit (Source);
      Ada.Directories.Set_Directory (Source);
      Commit := Version.Objects.To_Object_Id
        (Version.Refs.Current_Commit_Id (Version.Repository.Open));
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Test_Support.Make_Directory (Target);
      Version.Git_Fixtures.Run (Target, "git init");
      Version.Test_Support.Write_Text_File
        (Join (Join (Target, ".git"), "config"),
         "[core]" & Character'Val (10)
         & Character'Val (9) & "repositoryformatversion = 1" & Character'Val (10)
         & "[extensions]" & Character'Val (10)
         & Character'Val (9) & "partialClone = origin" & Character'Val (10)
         & "[remote ""origin""]" & Character'Val (10)
         & Character'Val (9) & "url = " & Join (Source, ".git") & Character'Val (10)
         & Character'Val (9) & "fetch = +refs/heads/*:refs/remotes/origin/*"
         & Character'Val (10));

      Ada.Directories.Set_Directory (Target);
      declare
         Repo : constant Version.Repository.Repository_Handle := Version.Repository.Open;
         Obj  : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit);
      begin
         Assert
           (Version.Objects.Kind (Obj) = Version.Objects.Commit_Object,
            "lazy-fetched partial clone object must be a commit");
         Assert
           (Ada.Directories.Exists (Version.Objects.Loose_Object_Path (Repo, Commit))
            or else Version.Pack.Contains (Repo, Commit),
            "lazy fetch must materialize the requested object");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Partial_Clone_Read_Object_Lazily_Fetches_Local_Remote;

   procedure Loose_Object_Corrupt_Zlib_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Id   : constant Version.Objects.Object_Id_Storage := Version.Objects.To_Object_Id ([1 .. 40 => '1']);
      begin
         Write_Loose_Raw (Repo, Id, "not-a-zlib-stream", Compress => False);

         begin
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Loose_Object (Repo, Id);
               pragma Unreferenced (Obj);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "corrupt loose zlib stream");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Loose_Object_Corrupt_Zlib_Rejected;

   procedure Loose_Object_Missing_Header_Terminator_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raw     : constant String := "blob 3abc";
      Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Loose_Object (Repo, Id);
               pragma Unreferenced (Obj);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "loose object missing header terminator");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Loose_Object_Missing_Header_Terminator_Rejected;

   procedure Loose_Object_Declared_Size_Mismatch_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raw     : constant String := "blob 99" & Character'Val (0) & "abc";
      Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Loose_Object (Repo, Id);
               pragma Unreferenced (Obj);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "loose object declared-size mismatch");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Loose_Object_Declared_Size_Mismatch_Rejected;

   procedure Loose_Object_Hash_Mismatch_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raw     : constant String := Canonical_Raw ("blob", "abc");
      Id      : constant Version.Objects.Object_Id_Storage := Version.Objects.To_Object_Id ([1 .. 40 => '1']);
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Loose_Object (Repo, Id);
               pragma Unreferenced (Obj);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "loose object hash mismatch");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Loose_Object_Hash_Mismatch_Rejected;

   procedure Tree_Object_Malformed_Mode_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Content : constant String := "100644";
      Raw     : constant String := Canonical_Raw ("tree", Content);
      Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                 Version.Objects.Flatten_Tree (Repo, Id);
               pragma Unreferenced (Entries);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "tree object missing mode terminator");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tree_Object_Malformed_Mode_Rejected;

   procedure Tree_Object_Missing_Name_Nul_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Content : constant String := "100644 file";
      Raw     : constant String := Canonical_Raw ("tree", Content);
      Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                 Version.Objects.Flatten_Tree (Repo, Id);
               pragma Unreferenced (Entries);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "tree object missing name terminator");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tree_Object_Missing_Name_Nul_Rejected;

   procedure Tree_Object_Truncated_Object_Id_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Content : constant String := "100644 file" & Character'Val (0) & "short";
      Raw     : constant String := Canonical_Raw ("tree", Content);
      Id      : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
      begin
         Write_Loose_Raw (Repo, Id, Raw);

         begin
            declare
               Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                 Version.Objects.Flatten_Tree (Repo, Id);
               pragma Unreferenced (Entries);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "tree object truncated object id");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tree_Object_Truncated_Object_Id_Rejected;

   procedure Commit_Object_Missing_Tree_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Obj    : constant Version.Objects.Git_Object :=
        Version.Objects.Create_Object
          (Kind    => Version.Objects.Commit_Object,
           Content =>
             "author Test <test@example.com> 0 +0000" & Character'Val (10));
      Raised : Boolean := False;
   begin
      begin
         declare
            Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id (Obj);
            pragma Unreferenced (Tree);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Expect_Data_Error (Raised, "commit object missing tree");
   end Commit_Object_Missing_Tree_Rejected;

   procedure Commit_Object_Invalid_Tree_Id_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Obj    : constant Version.Objects.Git_Object :=
        Version.Objects.Create_Object
          (Kind    => Version.Objects.Commit_Object,
           Content => "tree not-a-valid-object-id" & Character'Val (10));
      Raised : Boolean := False;
   begin
      begin
         declare
            Tree : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.Commit_Tree_Id (Obj);
            pragma Unreferenced (Tree);
         begin
            null;
         end;
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Expect_Data_Error (Raised, "commit object invalid tree id");
   end Commit_Object_Invalid_Tree_Id_Rejected;

   procedure Pack_Truncated_Header_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Pack_Path : constant String :=
           Join (Pack_Dir (Repo), "truncated.pack");
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File (Pack_Path, "PACK");

         begin
            Version.Pack.Index_Pack (Repo, Pack_Path);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (not Ada.Directories.Exists
                  (Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx"),
            "truncated pack must not leave an index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "truncated pack");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Truncated_Header_Rejected;

   procedure Pack_Bad_Checksum_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Pack_Path : constant String :=
           Join (Pack_Dir (Repo), "bad-checksum.pack");
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File
           (Pack_Path,
            Pack_File
              (Interfaces.Unsigned_32'(0), "", Valid_Checksum => False));

         begin
            Version.Pack.Index_Pack (Repo, Pack_Path);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (not Ada.Directories.Exists
                  (Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx"),
            "bad-checksum pack must not leave an index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "bad pack checksum");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Bad_Checksum_Rejected;

   procedure Pack_Missing_Ref_Delta_Base_Rejected_Without_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Pack_Path : constant String :=
           Join (Pack_Dir (Repo), "missing-ref-delta-base.pack");
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File
           (Pack_Path,
            Pack_File
              (Interfaces.Unsigned_32'(1), Ref_Delta_Entry_With_Missing_Base));

         begin
            Version.Pack.Index_Pack (Repo, Pack_Path);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (not Ada.Directories.Exists
                  (Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx"),
            "pack with missing ref-delta base must not leave an index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "pack missing ref-delta base");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Missing_Ref_Delta_Base_Rejected_Without_Index;

   procedure Pack_Ref_Delta_Size_Mismatch_Rejected_Without_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo      : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Base      : constant String := "abc";
         Base_Id   : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Hash.Sha1_Hex (Canonical_Raw ("blob", Base)));
         Pack_Path : constant String :=
           Join (Pack_Dir (Repo), "ref-delta-size-mismatch.pack");
      begin
         Ensure_Pack_Dir (Repo);
         Write_Loose_Raw (Repo, Base_Id, Canonical_Raw ("blob", Base));
         Write_Binary_File
           (Pack_Path,
            Pack_File
              (Interfaces.Unsigned_32'(1),
               Ref_Delta_Entry_With_Size_Mismatch (Base_Id)));

         begin
            Version.Pack.Index_Pack (Repo, Pack_Path);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (not Ada.Directories.Exists
                  (Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx"),
            "pack with ref-delta size mismatch must not leave an index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "pack ref-delta size mismatch");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Ref_Delta_Size_Mismatch_Rejected_Without_Index;

   procedure Pack_Ofs_Delta_Size_Mismatch_Rejected_Without_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo       : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Base_Entry : constant String := Blob_Pack_Entry ("abc");
         Delta_Entry : constant String :=
           Ofs_Delta_Entry_With_Size_Mismatch
             (Base_Distance => Base_Entry'Length);
         Pack_Path  : constant String :=
           Join (Pack_Dir (Repo), "ofs-delta-size-mismatch.pack");
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File
           (Pack_Path,
            Pack_File
              (Interfaces.Unsigned_32'(2), Base_Entry & Delta_Entry));

         begin
            Version.Pack.Index_Pack (Repo, Pack_Path);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;

         Assert
           (not Ada.Directories.Exists
                  (Pack_Path (Pack_Path'First .. Pack_Path'Last - 3) & "idx"),
            "pack with ofs-delta size mismatch must not leave an index");
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "pack ofs-delta size mismatch");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Ofs_Delta_Size_Mismatch_Rejected_Without_Index;

   procedure Pack_Index_Truncated_Name_Table_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Ada.Directories.Set_Directory (Root);

      declare
         Repo       : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Dir        : constant String := Pack_Dir (Repo);
         Pack_Path  : constant String := Join (Dir, "bad-index.pack");
         Index_Path : constant String := Join (Dir, "bad-index.idx");
         Fanout     : Ada.Strings.Unbounded.Unbounded_String :=
           Ada.Strings.Unbounded.Null_Unbounded_String;
      begin
         Ensure_Pack_Dir (Repo);
         Write_Binary_File
           (Pack_Path, Pack_File (Interfaces.Unsigned_32'(0), ""));

         for I in 0 .. 255 loop
            Ada.Strings.Unbounded.Append
              (Fanout, U32_BE (Interfaces.Unsigned_32'(1)));
         end loop;

         Write_Binary_File
           (Index_Path,
            Character'Val (16#FF#)
            & "tOc"
            & U32_BE (Interfaces.Unsigned_32'(2))
            & Ada.Strings.Unbounded.To_String (Fanout));

         begin
            declare
               Found : constant Boolean :=
                 Version.Pack.Contains (Repo, Version.Objects.Zero_Object_Id);
               pragma Unreferenced (Found);
            begin
               null;
            end;
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Expect_Data_Error (Raised, "truncated pack index name table");

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pack_Index_Truncated_Name_Table_Rejected;

   procedure Commit_Parent_Ids_Reads_Merge_Parents
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Obj : constant Version.Objects.Git_Object :=
        Version.Objects.Create_Object
          (Kind    => Version.Objects.Commit_Object,
           Content =>
             "tree 0123456789012345678901234567890123456789"
             & Character'Val (10)
             & "parent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
             & Character'Val (10)
             & "parent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
             & Character'Val (10)
             & "author Test <test@example.com> 0 +0000"
             & Character'Val (10)
             & "committer Test <test@example.com> 0 +0000"
             & Character'Val (10)
             & Character'Val (10)
             & "merge"
             & Character'Val (10));

      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);
   begin
      Assert
        (Natural (Parents.Length) = 2,
         "merge commit must expose two parent ids");

      Assert
        (To_String (Parents.Element (Parents.First_Index))
         = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "first parent mismatch");

      Assert
        (To_String (Parents.Element (Parents.First_Index + 1))
         = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
         "second parent mismatch");

      Assert
        (Version.Objects.Commit_Parent_Id (Obj)
         = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "legacy first-parent API must return first parent");
   end Commit_Parent_Ids_Reads_Merge_Parents;

   procedure Parse_Tree_Handles_Sha1_And_Sha256_Widths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      NUL : constant Character := Character'Val (0);

      Raw20 : constant String (1 .. 20) := [others => Character'Val (16#CD#)];
      Raw32 : constant String (1 .. 32) := [others => Character'Val (16#AB#)];

      --  hex of the raw bytes above: 0xCD -> "cd", 0xAB -> "ab".
      Sha1_Hex   : constant String :=
        [for I in 1 .. 40 => (if I mod 2 = 1 then 'c' else 'd')];
      Sha256_Hex : constant String :=
        [for I in 1 .. 64 => (if I mod 2 = 1 then 'a' else 'b')];

      Sha1_Tree   : constant String := "40000 subdir" & NUL & Raw20;
      Sha256_Tree : constant String := "100644 file.txt" & NUL & Raw32;

      E1 : constant Tree_Entry_Vectors.Vector :=
        Version.Objects.Parse_Tree (Version.Hash.Sha1, Sha1_Tree);
      E2 : constant Tree_Entry_Vectors.Vector :=
        Version.Objects.Parse_Tree (Version.Hash.Sha256, Sha256_Tree);

   begin
      --  SHA-1 tree: one directory entry, 40-hex id from the 20 raw bytes.
      Assert (Natural (E1.Length) = 1, "sha1 tree must parse one entry");
      Assert
        (To_String (E1.Element (0).Id) = Sha1_Hex
         and then To_String (E1.Element (0).Path) = "subdir"
         and then E1.Element (0).Kind = Tree_Directory,
         "sha1 tree entry: 40-hex id / name / directory kind");

      --  SHA-256 tree: one blob entry, 64-hex id from the 32 raw bytes.
      Assert (Natural (E2.Length) = 1, "sha256 tree must parse one entry");
      Assert
        (To_String (E2.Element (0).Id)'Length = 64
         and then To_String (E2.Element (0).Id) = Sha256_Hex
         and then To_String (E2.Element (0).Path) = "file.txt"
         and then E2.Element (0).Kind = Tree_Blob,
         "sha256 tree entry: 64-hex id / name / blob kind");
   end Parse_Tree_Handles_Sha1_And_Sha256_Widths;

   procedure To_Raw_Encodes_Both_Widths_And_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      NUL : constant Character := Character'Val (0);

      Id40 : constant Object_Id_Storage :=
        To_Object_Id
          ([for I in 1 .. 40 => (if I mod 2 = 1 then 'c' else 'd')]);
      Id64 : constant Object_Id_Storage :=
        To_Object_Id
          ([for I in 1 .. 64 => (if I mod 2 = 1 then 'a' else 'b')]);

      Raw40 : constant String := Version.Objects.To_Raw (Id40);
      Raw64 : constant String := Version.Objects.To_Raw (Id64);

      --  A sha256 tree encoded with To_Raw, parsed back by Parse_Tree.
      Tree : constant String := "100644 f.txt" & NUL & Raw64;
      Entries : constant Tree_Entry_Vectors.Vector :=
        Version.Objects.Parse_Tree (Version.Hash.Sha256, Tree);
   begin
      Assert (Raw40'Length = 20, "40-hex id must encode to 20 raw bytes");
      Assert (Raw64'Length = 32, "64-hex id must encode to 32 raw bytes");
      Assert
        (Raw40 (Raw40'First) = Character'Val (16#CD#)
         and then Raw64 (Raw64'First) = Character'Val (16#AB#),
         "To_Raw must decode hex pairs to the right bytes");
      Assert
        (Natural (Entries.Length) = 1
         and then To_String (Entries.Element (0).Id) = To_String (Id64),
         "To_Raw then Parse_Tree round-trips a sha256 tree entry id");
   end To_Raw_Encodes_Both_Widths_And_Round_Trips;

   procedure Is_Valid_Hex_Object_Id_Accepts_40_And_64
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      H40 : constant String := [for I in 1 .. 40 => 'a'];
      H64 : constant String := [for I in 1 .. 64 => 'f'];
   begin
      Assert
        (Version.Objects.Is_Valid_Hex_Object_Id (H40)
         and then Version.Objects.Is_Valid_Hex_Object_Id (H64),
         "both 40-hex (sha1) and 64-hex (sha256) ids must be valid");
      Assert
        (not Version.Objects.Is_Valid_Hex_Object_Id ([for I in 1 .. 50 => 'a'])
         and then not Version.Objects.Is_Valid_Hex_Object_Id ("")
         and then not Version.Objects.Is_Valid_Hex_Object_Id
           ([for I in 1 .. 40 => 'g']),
         "wrong length or non-hex must be rejected");
   end Is_Valid_Hex_Object_Id_Accepts_40_And_64;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T,
         Is_Valid_Hex_Object_Id_Accepts_40_And_64'Access,
         "Is_Valid_Hex_Object_Id accepts 40-hex and 64-hex, rejects others");

      Register_Routine
        (T,
         Parse_Tree_Handles_Sha1_And_Sha256_Widths'Access,
         "Parse_Tree handles both sha1 (20-byte) and sha256 (32-byte) ids");

      Register_Routine
        (T,
         To_Raw_Encodes_Both_Widths_And_Round_Trips'Access,
         "To_Raw encodes 40/64-hex ids and round-trips via Parse_Tree");

      Register_Routine
        (T,
         Read_Commit_And_Tree_From_Git_Repo'Access,
         "Read loose commit and flatten tree from real Git repo");

      Register_Routine
        (T,
         Commit_Message_First_Line_From_Git_Repo'Access,
         "Read commit message and parent from real Git repo");

      Register_Routine
        (T,
         Packed_Commit_Is_Detected'Access,
         "Pack index: detect packed HEAD commit");

      Register_Routine
        (T,
         Packed_Commit_Offset_Is_Found'Access,
         "Pack index: find packed HEAD commit offset");

      Register_Routine
        (T,
         Packed_Commit_Header_Is_Read'Access,
         "Pack file: read packed commit header");

      Register_Routine
        (T,
         Read_Non_Delta_Packed_Commit'Access,
         "Pack file: read non-delta packed commit");

      Register_Routine
        (T,
         Read_Packed_Commit_After_Git_Gc'Access,
         "Pack file: read packed commit after git gc");

      Register_Routine
        (T,
         Read_Packed_Tree_With_Deltas'Access,
         "Pack file: read packed tree with deltas");

      Register_Routine
        (T,
         Pack_Index_Cache_Locates_Packed_Commit'Access,
         "Pack index cache: locate packed HEAD commit");

      Register_Routine
        (T,
         Object_Cache_Reads_From_Pack_Index_Cache'Access,
         "Object cache: read packed commit through pack-index cache");

      Register_Routine
        (T,
         Command_Local_Cache_Counts_Remain_Bounded'Access,
         "Command-local caches: repeated reads remain bounded");

      Register_Routine
        (T,
         Packed_Abbreviation_Resolves_Through_Pack_Index_Cache'Access,
         "Revision abbreviation: resolve packed object through pack-index cache");

      Register_Routine
        (T,
         Missing_Object_In_Promisor_Repository_Reports_Unsupported'Access,
         "Promisor object: missing promised object reports unsupported");

      Register_Routine
        (T,
         Partial_Clone_Read_Object_Lazily_Fetches_Local_Remote'Access,
         "Partial clone: object read lazily fetches from local promisor remote");

      Register_Routine
        (T,
         Loose_Object_Corrupt_Zlib_Rejected'Access,
         "Loose object: corrupt zlib stream rejected");

      Register_Routine
        (T,
         Loose_Object_Missing_Header_Terminator_Rejected'Access,
         "Loose object: missing header terminator rejected");

      Register_Routine
        (T,
         Loose_Object_Declared_Size_Mismatch_Rejected'Access,
         "Loose object: declared size mismatch rejected");

      Register_Routine
        (T,
         Loose_Object_Hash_Mismatch_Rejected'Access,
         "Loose object: hash mismatch rejected");

      Register_Routine
        (T,
         Tree_Object_Malformed_Mode_Rejected'Access,
         "Tree object: malformed mode rejected");

      Register_Routine
        (T,
         Tree_Object_Missing_Name_Nul_Rejected'Access,
         "Tree object: missing name terminator rejected");

      Register_Routine
        (T,
         Tree_Object_Truncated_Object_Id_Rejected'Access,
         "Tree object: truncated object id rejected");

      Register_Routine
        (T,
         Commit_Object_Missing_Tree_Rejected'Access,
         "Commit object: missing tree rejected");

      Register_Routine
        (T,
         Commit_Object_Invalid_Tree_Id_Rejected'Access,
         "Commit object: invalid tree id rejected");

      Register_Routine
        (T,
         Pack_Truncated_Header_Rejected'Access,
         "Pack: truncated pack rejected without index");

      Register_Routine
        (T,
         Pack_Bad_Checksum_Rejected'Access,
         "Pack: bad checksum rejected without index");

      Register_Routine
        (T,
         Pack_Missing_Ref_Delta_Base_Rejected_Without_Index'Access,
         "Pack: missing ref-delta base rejected without index");

      Register_Routine
        (T,
         Pack_Ref_Delta_Size_Mismatch_Rejected_Without_Index'Access,
         "Pack: ref-delta size mismatch rejected without index");

      Register_Routine
        (T,
         Pack_Ofs_Delta_Size_Mismatch_Rejected_Without_Index'Access,
         "Pack: ofs-delta size mismatch rejected without index");

      Register_Routine
        (T,
         Pack_Index_Truncated_Name_Table_Rejected'Access,
         "Pack index: truncated object name table rejected");

      Register_Routine
        (T,
         Commit_Parent_Ids_Reads_Merge_Parents'Access,
         "Commit: read all merge parents");

   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Objects");
   end Name;

end Version.Objects.Tests;
