with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Interfaces;

with Version.Files;
with Version.Git_Fixtures;
with Version.Hash;
with Version.Objects; use Version.Objects;
with Version.Pack;
with Version.Pack_Index;
with Version.Pack_Index_Cache;
with Version.Refs;
with Version.Repository;
with Version.Test_Support;
with Version.Write;

package body Version.Pack_Write.Tests is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;
   use Interfaces;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   function Join (Left, Right : String) return String renames Version.Test_Support.Join;

   function Object_File_Path
     (Root : String;
      Id   : Version.Objects.Hex_Object_Id) return String
   is
      Text : constant String := To_String (Id);
   begin
      return Join (Join (Join (Root, ".git"), "objects"), Text (1 .. 2))
        & "/" & Text (3 .. 40);
   end Object_File_Path;

   function Read_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);

      declare
         Size   : constant Ada.Streams.Stream_IO.Count := Ada.Streams.Stream_IO.Size (File);
         Data   : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size));
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : String (1 .. Natural (Size));
      begin
         Ada.Streams.Stream_IO.Read (File, Data, Last);
         Ada.Streams.Stream_IO.Close (File);

         if Last /= Data'Last then
            raise Ada.IO_Exceptions.Data_Error with "test could not read complete file";
         end if;

         for I in Data'Range loop
            Result (Natural (I)) := Character'Val (Data (I));
         end loop;

         return Result;
      end;

   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;

         raise;
   end Read_File;

   function U32_BE (Data : String; Pos : Positive) return U32 is
   begin
      return U32 (Character'Pos (Data (Pos))) * 16#1000000#
        + U32 (Character'Pos (Data (Pos + 1))) * 16#10000#
        + U32 (Character'Pos (Data (Pos + 2))) * 16#100#
        + U32 (Character'Pos (Data (Pos + 3)));
   end U32_BE;

   function U64_BE_String (Value : U64) return String is
      Result : String (1 .. 8);
      V      : U64 := Value;
   begin
      for I in reverse Result'Range loop
         Result (I) := Character'Val (Natural (V and 16#FF#));
         V := Interfaces.Shift_Right (V, 8);
      end loop;

      return Result;
   end U64_BE_String;

   function Hex_Nibble (C : Character) return Natural is
   begin
      if C in '0' .. '9' then
         return Character'Pos (C) - Character'Pos ('0');
      elsif C in 'a' .. 'f' then
         return Character'Pos (C) - Character'Pos ('a') + 10;
      elsif C in 'A' .. 'F' then
         return Character'Pos (C) - Character'Pos ('A') + 10;
      else
         raise Ada.IO_Exceptions.Data_Error with "invalid hexadecimal digit in test";
      end if;
   end Hex_Nibble;

   function Raw_Id (Hex : String) return String is
      Result : String (1 .. 20);
      Pos    : Positive := Hex'First;
   begin
      for I in Result'Range loop
         Result (I) :=
           Character'Val (Hex_Nibble (Hex (Pos)) * 16 + Hex_Nibble (Hex (Pos + 1)));
         Pos := Pos + 2;
      end loop;

      return Result;
   end Raw_Id;

   function Raw_Sha1 (Content : String) return String is
   begin
      return Raw_Id (Version.Hash.Sha1_Hex (Content));
   end Raw_Sha1;

   function Slice
     (Data  : String;
      First : Positive;
      Count : Natural) return String
   is
   begin
      return Data (First .. First + Count - 1);
   end Slice;

   procedure Create_Commit_With_File
     (Root      : String;
      Repo      : out Version.Repository.Repository_Handle;
      Commit_Id : out Version.Objects.Hex_Object_Id;
      Tree_Id   : out Version.Objects.Hex_Object_Id;
      Blob_Id   : out Version.Objects.Hex_Object_Id)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Path    : constant String := Join (Root, "a.txt");
   begin
      Version.Git_Fixtures.Run (Root, "git init");
      Version.Git_Fixtures.Run (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");

      Ada.Directories.Set_Directory (Root);

      Version.Test_Support.Write_Text_File
        (Path,
         "packed" & Character'Val (10));

      Version.Git_Fixtures.Run (Root, "git add a.txt");
      Version.Write.Save ("pack-write baseline");

      Repo := Version.Repository.Open;
      Commit_Id := Version.Objects.To_Object_Id (Version.Refs.Current_Commit_Id (Repo));

      declare
         Commit_Obj : constant Version.Objects.Git_Object :=
           Version.Objects.Read_Object (Repo, Commit_Id);
      begin
         Tree_Id := Version.Objects.Commit_Tree_Id (Commit_Obj);
      end;

      declare
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo, Tree_Id);
      begin
         Assert (not Entries.Is_Empty, "test tree must contain a blob entry");
         Blob_Id := Entries.Element (Entries.First_Index).Id;
      end;

      Ada.Directories.Set_Directory (Old_Dir);

   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Create_Commit_With_File;

   procedure Append_All_Objects
     (Ids       : in out Version.Objects.Object_Id_Vectors.Vector;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Blob_Id   : Version.Objects.Hex_Object_Id)
   is
   begin
      Ids.Append (Commit_Id);
      Ids.Append (Tree_Id);
      Ids.Append (Blob_Id);
   end Append_All_Objects;

   procedure Writes_Canonical_Header_Tables_And_Checksums
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "canonical.pack");
      Index_Path : constant String := Join (Pack_Dir, "canonical.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Append_All_Objects (Ids, Commit_Id, Tree_Id, Blob_Id);

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Ids,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);

      declare
         Pack_Data : constant String := Read_File (Pack_Path);
         Idx_Data  : constant String := Read_File (Index_Path);

         Object_Count : constant Natural := 3;

         Idx_Pack_Checksum_Start : constant Positive :=
           8 + 256 * 4 + Object_Count * 20 + Object_Count * 4 + Object_Count * 4 + 1;

         Pack_Checksum : constant String :=
           Pack_Data (Pack_Data'Last - 19 .. Pack_Data'Last);

         Idx_Checksum : constant String :=
           Idx_Data (Idx_Data'Last - 19 .. Idx_Data'Last);

         Name_1 : constant String := Slice (Idx_Data, 8 + 256 * 4 + 1, 20);
         Name_2 : constant String := Slice (Idx_Data, 8 + 256 * 4 + 21, 20);
         Name_3 : constant String := Slice (Idx_Data, 8 + 256 * 4 + 41, 20);
      begin
         Assert (Slice (Pack_Data, 1, 4) = "PACK", "pack header must start with PACK magic");
         Assert (U32_BE (Pack_Data, 5) = 2, "pack header must use PACK version 2");
         Assert (U32_BE (Pack_Data, 9) = 3, "pack header must count unique objects");

         Assert
           (Pack_Checksum = Raw_Sha1 (Pack_Data (Pack_Data'First .. Pack_Data'Last - 20)),
            "pack trailer must be SHA-1 over all preceding pack bytes");

         Assert (U32_BE (Idx_Data, 1) = 16#FF744F63#, "idx must start with v2 magic");
         Assert (U32_BE (Idx_Data, 5) = 2, "idx must use version 2");
         Assert (U32_BE (Idx_Data, 8 + 255 * 4 + 1) = 3,
                 "idx final fanout entry must equal unique object count");
         Assert (Name_1 < Name_2 and then Name_2 < Name_3,
                 "idx object-name table must be sorted by raw object id");
         Assert (Slice (Idx_Data, Idx_Pack_Checksum_Start, 20) = Pack_Checksum,
                 "idx must embed the pack checksum before the idx checksum");
         Assert (Idx_Checksum = Raw_Sha1 (Idx_Data (Idx_Data'First .. Idx_Data'Last - 20)),
                 "idx checksum must cover all prior idx bytes including pack checksum");
      end;
   end Writes_Canonical_Header_Tables_And_Checksums;

   procedure Writes_Valid_Pack_And_Index
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "test.pack");
      Index_Path : constant String := Join (Pack_Dir, "test.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Append_All_Objects (Ids, Commit_Id, Tree_Id, Blob_Id);

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Ids,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);

      Assert (Ada.Directories.Exists (Pack_Path), "pack writer must create .pack file");
      Assert (Ada.Directories.Exists (Index_Path), "pack writer must create .idx file");

      Version.Git_Fixtures.Run (Root, "git verify-pack -v .git/objects/pack/test.idx");
      Version.Git_Fixtures.Run (Root, "git fsck --strict");
   end Writes_Valid_Pack_And_Index;

   procedure Reads_Self_Generated_Packed_Objects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "self.pack");
      Index_Path : constant String := Join (Pack_Dir, "self.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Append_All_Objects (Ids, Commit_Id, Tree_Id, Blob_Id);

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Ids,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);

      Ada.Directories.Delete_File (Version.Objects.Loose_Object_Path (Repo, Commit_Id));
      Ada.Directories.Delete_File (Version.Objects.Loose_Object_Path (Repo, Tree_Id));
      Ada.Directories.Delete_File (Version.Objects.Loose_Object_Path (Repo, Blob_Id));

      declare
         Commit_Obj : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Commit_Id);
         Tree_Obj   : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Tree_Id);
         Blob_Obj   : constant Version.Objects.Git_Object := Version.Objects.Read_Object (Repo, Blob_Id);
      begin
         Assert (Version.Objects.Kind (Commit_Obj) = Version.Objects.Commit_Object,
                 "self-generated pack must preserve commit kind");
         Assert (Version.Objects.Kind (Tree_Obj) = Version.Objects.Tree_Object,
                 "self-generated pack must preserve tree kind");
         Assert (Version.Objects.Kind (Blob_Obj) = Version.Objects.Blob_Object,
                 "self-generated pack must preserve blob kind");
         Assert (Version.Objects.Content (Blob_Obj) = "packed" & Character'Val (10),
                 "self-generated pack must preserve blob payload");
      end;
   end Reads_Self_Generated_Packed_Objects;

   procedure Fanout_Offsets_And_Duplicates_Are_Deterministic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "deterministic.pack");
      Index_Path : constant String := Join (Pack_Dir, "deterministic.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);

      Ids.Append (Blob_Id);
      Ids.Append (Commit_Id);
      Ids.Append (Blob_Id);
      Ids.Append (Tree_Id);
      Ids.Append (Commit_Id);

      Version.Pack_Write.Write_Pack
        (Repo       => Repo,
         Object_Ids => Ids,
         Pack_Path  => Pack_Path,
         Index_Path => Index_Path);

      declare
         Index_Data : constant String := Read_File (Index_Path);
         Object_Count : constant U32 := U32_BE (Index_Data, 8 + 255 * 4 + 1);
      begin
         Assert (Object_Count = 3, "idx fanout final entry must count unique objects only");
      end;

      for Id of Ids loop
         declare
            Location : constant Version.Pack.Pack_Location := Version.Pack.Find_Location (Repo, Id);
         begin
            Assert (Location.Found, "idx offsets must resolve packed object " & To_String (Id));
            Assert (Version.Pack.Read_Header (Location).Data_Offset > Location.Offset,
                    "resolved pack header must point at compressed data after object offset");
         end;
      end loop;
   end Fanout_Offsets_And_Duplicates_Are_Deterministic;

   procedure Index_Pack_Accepts_Non_Delta_Annotated_Tag
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Pack_Dir  : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Version.Git_Fixtures.Run (Root, "git tag -a ingested -m ingested");
      Version.Git_Fixtures.Run
        (Root, "git rev-parse refs/tags/ingested^{} > peeled.id");
      Version.Git_Fixtures.Run
        (Root, "git rev-parse refs/tags/ingested^{tag} > tag.id");

      declare
         Tag_Id : constant Version.Objects.Hex_Object_Id :=
           Version.Objects.To_Object_Id
             (Version.Test_Support.Read_Text_File (Join (Root, "tag.id")));
         Objects_Path : constant String := Join (Root, "ingested-tag-objects.txt");
      begin
         Assert
           (Version.Test_Support.Read_Text_File (Join (Root, "peeled.id")) = Commit_Id,
            "annotated tag fixture must peel to the baseline commit");

         Version.Test_Support.Write_Text_File (Objects_Path, To_String (Tag_Id));
         Version.Git_Fixtures.Run
           (Root,
            "git pack-objects .git/objects/pack/ingested-tag "
            & "< ingested-tag-objects.txt > ingested-tag-pack-name.txt");

         declare
            Pack_Name : constant String :=
              Version.Test_Support.Read_Text_File
                (Join (Root, "ingested-tag-pack-name.txt"));
            Pack_Path : constant String :=
              Join (Pack_Dir, "ingested-tag-" & Pack_Name & ".pack");
            Index_Path : constant String :=
              Join (Pack_Dir, "ingested-tag-" & Pack_Name & ".idx");
         begin
            Ada.Directories.Delete_File (Index_Path);
            Version.Pack.Index_Pack (Repo => Repo, Pack_Path => Pack_Path);
            Ada.Directories.Delete_File
              (Version.Objects.Loose_Object_Path (Repo, Tag_Id));

            declare
               Location : constant Version.Pack.Pack_Location :=
                 Version.Pack.Find_Location (Repo, Tag_Id);
               Obj : constant Version.Objects.Git_Object :=
                 Version.Objects.Read_Object (Repo, Tag_Id);
            begin
               Assert (Location.Found,
                       "Index_Pack must index non-delta annotated tag objects");
               Assert (Version.Objects.Kind (Obj) = Version.Objects.Tag_Object,
                       "ingested packed annotated tag must keep tag object kind");
               Assert
                 (Version.Objects.Content (Obj)'Length > 0
                  and then Version.Objects.Content (Obj) (1 .. 7) = "object ",
                  "ingested packed annotated tag must preserve tag payload");
            end;
         end;
      end;
   end Index_Pack_Accepts_Non_Delta_Annotated_Tag;

   procedure Index_Builder_Emits_Large_Offset_Table
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Entries : Version.Pack_Index.Entry_Vectors.Vector;
      Pack_Checksum : constant String := "abcdefghijklmnopqrst";
      Small_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("0000000000000000000000000000000000000001");
      Boundary_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("8000000000000000000000000000000000000000");
      Large_Id : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("ffffffffffffffffffffffffffffffffffffffff");
   begin
      Entries.Append
        (Version.Pack_Index.Index_Entry'
           (Id => Large_Id, Offset => 16#0000_0001_0000_0000#, Crc => 3));
      Entries.Append
        (Version.Pack_Index.Index_Entry'
           (Id => Small_Id, Offset => 12, Crc => 1));
      Entries.Append
        (Version.Pack_Index.Index_Entry'
           (Id => Boundary_Id, Offset => 16#8000_0000#, Crc => 2));

      declare
         Idx : constant String :=
           Version.Pack_Index.Build
             (Entries       => Entries,
              Pack_Checksum => Pack_Checksum);
         Object_Count : constant Natural := 3;
         Names_Start : constant Positive := 8 + 256 * 4 + 1;
         Crc_Start : constant Positive := Names_Start + Object_Count * 20;
         Offset_Start : constant Positive := Crc_Start + Object_Count * 4;
         Large_Start : constant Positive := Offset_Start + Object_Count * 4;
         Pack_Checksum_Start : constant Positive := Large_Start + 2 * 8;
      begin
         Assert (U32_BE (Idx, 1) = 16#FF744F63#, "idx must use v2 magic");
         Assert (U32_BE (Idx, 5) = 2, "idx must use v2 format");
         Assert (U32_BE (Idx, 8 + 255 * 4 + 1) = 3,
                 "final fanout must count all entries");

         Assert (Slice (Idx, Names_Start, 20) = Raw_Id (To_String (Small_Id)),
                 "small id must be sorted first");
         Assert (Slice (Idx, Names_Start + 20, 20) = Raw_Id (To_String (Boundary_Id)),
                 "boundary id must be sorted second");
         Assert (Slice (Idx, Names_Start + 40, 20) = Raw_Id (To_String (Large_Id)),
                 "large id must be sorted third");

         Assert (U32_BE (Idx, Offset_Start) = 12,
                 "small offset must stay in the normal offset table");
         Assert (U32_BE (Idx, Offset_Start + 4) = 16#8000_0000#,
                 "first large offset must point at large-offset slot zero");
         Assert (U32_BE (Idx, Offset_Start + 8) = 16#8000_0001#,
                 "second large offset must point at large-offset slot one");

         Assert (Slice (Idx, Large_Start, 8) = U64_BE_String (16#8000_0000#),
                 "large-offset table must include the boundary offset");
         Assert
           (Slice (Idx, Large_Start + 8, 8)
            = U64_BE_String (16#0000_0001_0000_0000#),
            "large-offset table must include offsets beyond 32 bits");
         Assert (Slice (Idx, Pack_Checksum_Start, 20) = Pack_Checksum,
                 "pack checksum must follow the large-offset table");
         Assert
           (Slice (Idx, Idx'Last - 19, 20)
            = Raw_Sha1 (Idx (Idx'First .. Idx'Last - 20)),
            "idx checksum must cover the large-offset table");
      end;
   end Index_Builder_Emits_Large_Offset_Table;

   procedure Rejects_Missing_Object_Id
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Raised     : Boolean := False;
      Missing    : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id ("ffffffffffffffffffffffffffffffffffffffff");
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "missing.pack");
      Index_Path : constant String := Join (Pack_Dir, "missing.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Ids.Append (Missing);

      begin
         Version.Pack_Write.Write_Pack
           (Repo       => Repo,
            Object_Ids => Ids,
            Pack_Path  => Pack_Path,
            Index_Path => Index_Path);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "pack writer must reject a missing object id deterministically");
      Assert
        (not Ada.Directories.Exists (Pack_Path),
         "missing-object failure must remove partial pack output");
      Assert
        (not Ada.Directories.Exists (Index_Path),
         "missing-object failure must remove partial index output");
   end Rejects_Missing_Object_Id;

   procedure Rejects_Object_Content_Mismatch_Without_Partial_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String := Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Repo : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Object_Id_Storage;
      Tree_Id   : Version.Objects.Object_Id_Storage;
      Blob_Id   : Version.Objects.Object_Id_Storage;
      Other_Blob : Version.Objects.Object_Id_Storage;
      Ids        : Version.Objects.Object_Id_Vectors.Vector;
      Raised     : Boolean := False;
      Pack_Dir   : constant String := Join (Join (Join (Root, ".git"), "objects"), "pack");
      Pack_Path  : constant String := Join (Pack_Dir, "mismatch.pack");
      Index_Path : constant String := Join (Pack_Dir, "mismatch.idx");
   begin
      Create_Commit_With_File (Root, Repo, Commit_Id, Tree_Id, Blob_Id);
      Ids.Append (Blob_Id);

      Other_Blob := Version.Write.Write_Blob (Repo, "different pack-write payload");
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Object_File_Path (Root, Blob_Id)));
      Version.Test_Support.Write_Text_File (Pack_Path, "preexisting pack");
      Version.Test_Support.Write_Text_File (Index_Path, "preexisting index");
      Version.Files.Delete_File_If_Exists (Object_File_Path (Root, Blob_Id));
      Version.Files.Write_Binary_File
        (Path    => Object_File_Path (Root, Blob_Id),
         Content => Version.Files.Read_Binary_File (Object_File_Path (Root, Other_Blob)));

      begin
         Version.Pack_Write.Write_Pack
           (Repo       => Repo,
            Object_Ids => Ids,
            Pack_Path  => Pack_Path,
            Index_Path => Index_Path);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;

      Assert (Raised, "pack writer must reject object content/id mismatch");
      Assert
        (not Ada.Directories.Exists (Pack_Path),
         "content-mismatch failure must remove partial pack output");
      Assert
        (not Ada.Directories.Exists (Index_Path),
         "content-mismatch failure must remove partial index output");
   end Rejects_Object_Content_Mismatch_Without_Partial_Output;

   procedure Pack_Index_Build_Uses_Object_Format_Width
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Entries : Version.Pack_Index.Entry_Vectors.Vector;

      Id64 : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ([for I in 1 .. 64 => (if I mod 2 = 1 then 'a' else 'b')]);

      Pack_Cksum : constant String :=
        [1 .. 32 => Character'Val (16#EE#)];
   begin
      Entries.Append
        (Version.Pack_Index.Index_Entry'
           (Id => Id64, Offset => 12, Crc => 16#DEAD_BEEF#));

      declare
         Idx : constant String :=
           Version.Pack_Index.Build (Entries, Pack_Cksum, Version.Hash.Sha256);

         --  8 header + 256*4 fanout + 32 name + 4 crc + 4 offset
         --  + 32 pack checksum + 32 idx trailer.
         Expected_Len : constant Natural := 8 + 1024 + 32 + 4 + 4 + 32 + 32;
         Body_Part    : constant String := Idx (Idx'First .. Idx'Last - 32);
      begin
         Assert
           (Idx'Length = Expected_Len,
            "sha256 idx must use 32-byte names and 32-byte checksums");
         Assert
           (U32_BE (Idx, 1) = 16#FF74_4F63# and then U32_BE (Idx, 5) = 2,
            "idx magic and version-2 header");
         --  Object-name table begins after 8 + 1024 = 1032 bytes.
         Assert
           (Idx (1033 .. 1064) = Version.Objects.To_Raw (Id64),
            "sha256 object name is the 32-byte raw id");
         Assert
           (Idx (Idx'Last - 31 .. Idx'Last) =
              Version.Hash.Object_Hash_Raw (Version.Hash.Sha256, Body_Part),
            "idx trailer is a sha256 hash over the idx body");
      end;
   end Pack_Index_Build_Uses_Object_Format_Width;

   procedure Pack_Index_Reader_Round_Trips_Sha256
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Pack_Dir  : constant String :=
        Join (Join (Join (Root, ".git"), "objects"), "pack");
      Idx_Path  : constant String := Join (Pack_Dir, "t.idx");
      Pack_Path : constant String := Join (Pack_Dir, "t.pack");

      Id64 : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id
          ([for I in 1 .. 64 => (if I mod 2 = 1 then 'a' else 'b')]);
      Pack_Cksum : constant String := [1 .. 32 => Character'Val (16#EE#)];

      Entries : Version.Pack_Index.Entry_Vectors.Vector;
      Locs    : Version.Pack_Index_Cache.Cache;
   begin
      Entries.Append
        (Version.Pack_Index.Index_Entry'(Id => Id64, Offset => 100, Crc => 7));

      Version.Files.Create_Parent_Directories (Idx_Path);
      Version.Files.Write_Binary_File
        (Idx_Path,
         Version.Pack_Index.Build (Entries, Pack_Cksum, Version.Hash.Sha256));
      --  200-byte dummy pack: End_Offset for the sole (last) entry is
      --  Pack_Size - 32 (the sha256 pack trailer width).
      Version.Files.Write_Binary_File
        (Pack_Path, [1 .. 200 => Character'Val (0)]);

      Version.Pack_Index_Cache.Load_Index
        (Locs, Idx_Path, Pack_Path, Version.Hash.Sha256);

      Assert
        (Version.Pack_Index_Cache.Contains (Locs, Id64),
         "sha256 idx reader must locate the 64-hex id");

      declare
         Loc : constant Version.Pack.Pack_Location :=
           Version.Pack_Index_Cache.Locate (Locs, Id64);
      begin
         Assert
           (Loc.Found
            and then Natural (Loc.Offset) = 100
            and then Natural (Loc.End_Offset) = 200 - 32,
            "sha256 idx: offset 100, end = pack size - 32-byte trailer");
      end;
   end Pack_Index_Reader_Round_Trips_Sha256;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T,
         Pack_Index_Build_Uses_Object_Format_Width'Access,
         "Pack_Write: idx Build uses the object-format hash width (sha256)");

      Register_Routine
        (T,
         Pack_Index_Reader_Round_Trips_Sha256'Access,
         "Pack_Write: idx reader round-trips a sha256 index (32-byte)");

      Register_Routine
        (T,
         Writes_Canonical_Header_Tables_And_Checksums'Access,
         "Pack_Write: writes canonical headers tables and checksums");

      Register_Routine
        (T,
         Writes_Valid_Pack_And_Index'Access,
         "Pack_Write: writes Git-valid pack and index");

      Register_Routine
        (T,
         Reads_Self_Generated_Packed_Objects'Access,
         "Pack_Write: Version reads self-generated packed commit/tree/blob");

      Register_Routine
        (T,
         Fanout_Offsets_And_Duplicates_Are_Deterministic'Access,
         "Pack_Write: fanout offsets and duplicate ids are deterministic");

      Register_Routine
        (T,
         Index_Pack_Accepts_Non_Delta_Annotated_Tag'Access,
         "Pack_Write: Index_Pack accepts non-delta annotated tag objects");

      Register_Routine
        (T,
         Index_Builder_Emits_Large_Offset_Table'Access,
         "Pack_Write: idx v2 builder emits large-offset table");

      Register_Routine
        (T,
         Rejects_Missing_Object_Id'Access,
         "Pack_Write: rejects missing object id");

      Register_Routine
        (T,
         Rejects_Object_Content_Mismatch_Without_Partial_Output'Access,
         "Pack_Write: rejects object content mismatch without partial output");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Pack_Write");
   end Name;

end Version.Pack_Write.Tests;
