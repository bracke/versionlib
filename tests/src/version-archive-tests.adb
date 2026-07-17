with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO; use Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Version.Compression;
with Version.Files;
with Version.Hash;
with Version.Git_Fixtures;
with Version.Init;
with Version.Objects;
with Version.Pathspec;
with Version.Repository;
with Version.Refs;
with Version.Revisions;
with Version.Sparse;
with Version.Tar;
with Version.Test_Support;
with Version.Write;
with Version.Zip;

package body Version.Archive.Tests is
   use Version.Objects;

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   function Join (Left, Right : String) return String
   renames Version.Test_Support.Join;

   function LFS_Pointer return String is
     ("version https://git-lfs.github.com/spec/v1" & Character'Val (10)
      & "oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      & Character'Val (10)
      & "size 123456");

   function Read_Binary_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Size : constant Ada.Streams.Stream_IO.Count :=
           Ada.Streams.Stream_IO.Size (File);
      begin
         if Size = 0 then
            Ada.Streams.Stream_IO.Close (File);
            return "";
         end if;

         declare
            Data : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
            Last : Stream_Element_Offset;
            Text : String (1 .. Natural (Size));
            J    : Natural := Text'First;
         begin
            Ada.Streams.Stream_IO.Read (File, Data, Last);
            Ada.Streams.Stream_IO.Close (File);
            Assert (Last = Data'Last, "must read complete binary file");
            for I in Data'Range loop
               Text (J) := Character'Val (Data (I));
               J := J + 1;
            end loop;
            return Text;
         end;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         raise;
   end Read_Binary_File;

   function Raw_Id (Id : Version.Objects.Hex_Object_Id) return String is
      Result : String (1 .. 20);
      Pos    : Positive := To_String (Id)'First;

      function Nibble (C : Character) return Natural is
      begin
         if C in '0' .. '9' then
            return Character'Pos (C) - Character'Pos ('0');
         elsif C in 'a' .. 'f' then
            return Character'Pos (C) - Character'Pos ('a') + 10;
         elsif C in 'A' .. 'F' then
            return Character'Pos (C) - Character'Pos ('A') + 10;
         else
            raise Ada.IO_Exceptions.Data_Error
              with "invalid object id hex digit";
         end if;
      end Nibble;
   begin
      for I in Result'Range loop
         declare
            V : constant Natural :=
              Nibble (To_String (Id) (Pos)) * 16 + Nibble (To_String (Id) (Pos + 1));
         begin
            Result (I) := Character'Val (V);
            Pos := Pos + 2;
         end;
      end loop;

      return Result;
   end Raw_Id;

   function Write_Raw_Object
     (Repo    : Version.Repository.Repository_Handle;
      Kind    : String;
      Content : String) return Version.Objects.Hex_Object_Id
   is
      Header : constant String :=
        Kind & Natural'Image (Content'Length) & Character'Val (0);
      Raw    : constant String := Header & Content;
      Id     : constant Version.Objects.Hex_Object_Id :=
        Version.Objects.To_Object_Id (Version.Hash.Sha1_Hex (Raw));
   begin
      Version.Files.Write_Binary_File
        (Path    => Version.Objects.Loose_Object_Path (Repo, Id),
         Content => Version.Compression.Deflate_Zlib (Raw));
      return Id;
   end Write_Raw_Object;

   procedure Point_Main_At
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) is
   begin
      Version.Refs.Atomic_Write_Ref
        (Path      =>
           Version.Files.Join
             (Version.Files.Join
                (Version.Repository.Git_Dir (Repo), "refs/heads"),
              "main"),
         Object_Id => Commit_Id);
   end Point_Main_At;

   procedure Init_Repo_With_Archive_Fixture (Root : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");

      Version.Test_Support.Write_Text_File
        (Join (Root, "README.md"), "committed readme" & Character'Val (10));
      Version.Test_Support.Make_Directory (Join (Root, "src"));
      Version.Test_Support.Write_Text_File
        (Join (Root, "src/main.adb"),
         "procedure Main is begin null; end Main;" & Character'Val (10));
      Version.Test_Support.Make_Directory (Join (Root, "docs"));
      Version.Test_Support.Write_Text_File
        (Join (Root, "docs/manual.md"), "manual" & Character'Val (10));
      Version.Files.Write_Binary_File
        (Join (Root, "binary.dat"),
         "A" & Character'Val (0) & Character'Val (255) & "Z");
      Version.Files.Write_Binary_File
        (Join (Root, "crlf.txt"),
         "one"
         & Character'Val (13)
         & Character'Val (10)
         & "two"
         & Character'Val (13)
         & Character'Val (10));
      Version.Files.Write_Binary_File
        (Join (Root, "compressed-looking.bin"),
         Character'Val (16#1F#)
         & Character'Val (16#8B#)
         & Character'Val (8)
         & Character'Val (0)
         & "payload"
         & Character'Val (255));

      Version.Git_Fixtures.Run
        (Root,
         "git add README.md src/main.adb docs/manual.md binary.dat crlf.txt compressed-looking.bin");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("archive fixture");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Init_Repo_With_Archive_Fixture;

   procedure Add_Second_Commit_After_Tag (Root : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git tag archive-base");
      Version.Test_Support.Write_Text_File
        (Join (Root, "README.md"),
         "second commit readme" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add README.md");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("second archive fixture");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_Second_Commit_After_Tag;

   procedure Add_Branch_Then_Second_Commit (Root : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Git_Fixtures.Run (Root, "git branch archive-branch");
      Version.Test_Support.Write_Text_File
        (Join (Root, "README.md"),
         "branch successor readme" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add README.md");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("branch successor archive fixture");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_Branch_Then_Second_Commit;

   procedure Add_Gitlink_Commit (Root : String) is
   begin
      Version.Test_Support.Make_Directory (Join (Root, "deps"));
      Version.Git_Fixtures.Run
        (Root,
         "git update-index --add --cacheinfo 160000,"
         & "0123456789012345678901234567890123456789,deps/libfoo");
      Version.Git_Fixtures.Run (Root, "git commit -m archive-gitlink");
   end Add_Gitlink_Commit;

   procedure Add_Symlink_Commit (Root : String) is
   begin
      Version.Git_Fixtures.Run
        (Root,
         "Target=$(printf README.md | git hash-object -w --stdin) && "
         & "git update-index --add --cacheinfo 120000,$Target,link-to-readme && "
         & "git commit -m archive-symlink");
   end Add_Symlink_Commit;

   procedure Add_Executable_Commit (Root : String) is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
   begin
      Version.Test_Support.Write_Text_File
        (Join (Root, "run.sh"),
         "#!/bin/sh" & Character'Val (10) & "exit 0" & Character'Val (10));
      Version.Git_Fixtures.Run (Root, "git add run.sh");
      Version.Git_Fixtures.Run (Root, "git update-index --chmod=+x run.sh");
      Version.Git_Fixtures.Run (Root, "chmod +x run.sh");
      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("archive executable fixture");
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Add_Executable_Commit;

   procedure Tar_Exports_Head_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "archive.tar");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Version.Test_Support.Write_Text_File
        (Join (Root, "README.md"), "dirty" & Character'Val (10));
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "README.md") > 0,
            "tar must contain README path");
         Assert
           (Ada.Strings.Fixed.Index (Data, "src/main.adb") > 0,
            "tar must contain nested path");
         Assert
           (Ada.Strings.Fixed.Index (Data, "committed readme") > 0,
            "tar must contain committed bytes");
         Assert
           (Ada.Strings.Fixed.Index (Data, "dirty") = 0,
            "tar must ignore dirty working-tree bytes");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_Exports_Head_Tree;

   procedure Tar_Gz_Decompresses_To_Tar
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Tar_Out : constant String := Join (Root, "archive.tar");
      Gz_Out  : constant String := Join (Root, "archive.tar.gz");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_Out, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Gz_Out,
         Version.Archive.Tar_Gz_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Gz : constant String := Read_Binary_File (Gz_Out);
      begin
         --  Valid gzip member: magic 1f 8b, deflate method 08.
         Assert
           (Gz'Length >= 3
            and then Character'Pos (Gz (Gz'First)) = 16#1F#
            and then Character'Pos (Gz (Gz'First + 1)) = 16#8B#
            and then Character'Pos (Gz (Gz'First + 2)) = 16#08#,
            "tar.gz must start with a gzip member header");
      end;

      --  gunzip of our .tar.gz must reproduce our plain .tar byte-for-byte,
      --  and standard tar must list the expected paths (interop via the shell).
      Version.Git_Fixtures.Run
        (Root,
         "gunzip -c archive.tar.gz > from-gz.tar && cmp archive.tar from-gz.tar");
      Version.Git_Fixtures.Run
        (Root, "tar -tzf archive.tar.gz | grep -q 'src/main.adb'");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_Gz_Decompresses_To_Tar;

   procedure Zip_Exports_Head_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "archive.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert (Data'Length > 22, "zip must not be empty");
         Assert
           (Data (Data'First .. Data'First + 3)
            = "PK" & Character'Val (3) & Character'Val (4),
            "zip must start with local file header");
         Assert
           (Ada.Strings.Fixed.Index (Data, "README.md") > 0,
            "zip must contain README path");
         Assert
           (Ada.Strings.Fixed.Index (Data, "binary.dat") > 0,
            "zip must contain binary path");
         Assert
           (Ada.Strings.Fixed.Index
              (Data, "PK" & Character'Val (5) & Character'Val (6))
            > 0,
            "zip must contain an end-of-central-directory record");
      end;

      Version.Git_Fixtures.Run
        (Root, "unzip -p archive.zip binary.dat > zip-binary.out");
      declare
         Extracted : constant String :=
           Read_Binary_File (Join (Root, "zip-binary.out"));
      begin
         Assert
           (Extracted = "A" & Character'Val (0) & Character'Val (255) & "Z",
            "zip extraction must preserve exact binary payload bytes");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Zip_Exports_Head_Tree;

   procedure Pathspec_Filters_Zip (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "src.zip");
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Version.Pathspec.Append_Parse (Specs, "src/");
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Output,
         Version.Archive.Zip_Format,
         Specs);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "src/main.adb") > 0,
            "filtered zip must contain src file");
         Assert
           (Ada.Strings.Fixed.Index (Data, "README.md") = 0,
            "filtered zip must omit nonmatching README");
         Assert
           (Ada.Strings.Fixed.Index (Data, "binary.dat") = 0,
            "filtered zip must omit nonmatching binary");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pathspec_Filters_Zip;

   procedure Pathspec_Exclusion_Filters_Tar
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "exclude.tar");
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Version.Pathspec.Append_Parse (Specs, ":(exclude)docs/");
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Output,
         Version.Archive.Tar_Format,
         Specs);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "README.md") > 0,
            "exclude-only pathspec archive must still include non-excluded paths");
         Assert
           (Ada.Strings.Fixed.Index (Data, "src/main.adb") > 0,
            "exclude-only pathspec archive must include non-excluded nested paths");
         Assert
           (Ada.Strings.Fixed.Index (Data, "docs/manual.md") = 0,
            "exclude pathspec archive must omit excluded directory contents");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Pathspec_Exclusion_Filters_Tar;

   procedure No_Matching_Pathspec_Creates_Empty_Archives
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "empty-filter.tar");
      Zip_Output : constant String := Join (Root, "empty-filter.zip");
      Specs      : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Version.Pathspec.Append_Parse (Specs, "missing/");
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format,
         Specs);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format,
         Specs);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Tar_Data : constant String := Read_Binary_File (Tar_Output);
         Zip_Data : constant String := Read_Binary_File (Zip_Output);
      begin
         --  A commit archive still carries git's pax global header (one
         --  512-byte header block + one record block) followed by the two
         --  terminating zero blocks and no file entries, the whole padded up
         --  to git's 20-block (10240-byte) record.
         Assert
           (Tar_Data'Length = 10240,
            "empty filtered TAR has the pax global header, its record block,"
            & " two terminating zero blocks, padded to a 10240-byte record");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "pax_global_header") > 0,
            "a commit archive carries a pax global header even when filtered"
            & " empty");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "README.md") = 0,
            "empty filtered TAR must not contain repository file names");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, "README.md") = 0,
            "empty filtered ZIP must not contain repository file names");
         Assert
           (Ada.Strings.Fixed.Index
              (Zip_Data, "PK" & Character'Val (5) & Character'Val (6))
            > 0,
            "empty filtered ZIP must still contain an end-of-central-directory record");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end No_Matching_Pathspec_Creates_Empty_Archives;

   procedure Tagged_Revision_Exports_Selected_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "tagged.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Second_Commit_After_Tag (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "archive-base",
         Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "committed readme") > 0,
            "tagged archive must contain tagged revision bytes");
         Assert
           (Ada.Strings.Fixed.Index (Data, "second commit readme") = 0,
            "tagged archive must not use later HEAD bytes");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tagged_Revision_Exports_Selected_Tree;

   procedure Tar_Preserves_Executable_Mode
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "mode.tar");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Executable_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "run.sh") > 0,
            "tar must contain executable file path");
         Assert
           (Ada.Strings.Fixed.Index (Data, "0000775") > 0,
            "tar must preserve executable mode metadata "
            & "(git's tar.umask 0002: 0777 -> 0775)");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_Preserves_Executable_Mode;

   procedure Missing_Revision_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "missing.tar");
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "release-42",
            Output,
            Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "missing archive revision must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Missing_Revision_Is_Rejected;

   procedure Tar_And_Zip_Contain_Same_Core_Files
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "archive.tar");
      Zip_Output : constant String := Join (Root, "archive.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Tar_Data : constant String := Read_Binary_File (Tar_Output);
         Zip_Data : constant String := Read_Binary_File (Zip_Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "README.md") > 0
            and then Ada.Strings.Fixed.Index (Zip_Data, "README.md") > 0,
            "both formats must contain README.md");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "src/main.adb") > 0
            and then Ada.Strings.Fixed.Index (Zip_Data, "src/main.adb") > 0,
            "both formats must contain src/main.adb");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "binary.dat") > 0
            and then Ada.Strings.Fixed.Index (Zip_Data, "binary.dat") > 0,
            "both formats must contain binary.dat");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_And_Zip_Contain_Same_Core_Files;

   procedure Branch_Revision_Exports_Selected_Tree
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "branch.tar");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Branch_Then_Second_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "archive-branch",
         Output,
         Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "committed readme") > 0,
            "branch archive must contain branch revision bytes");
         Assert
           (Ada.Strings.Fixed.Index (Data, "branch successor readme") = 0,
            "branch archive must not use later HEAD bytes");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Branch_Revision_Exports_Selected_Tree;

   procedure Sparse_Checkout_Does_Not_Filter_Archive
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "sparse.tar");
      Items   : Version.Sparse.String_Vectors.Vector;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Items.Append ("src/");
      Version.Sparse.Set_From_Strings (Version.Repository.Open, Items);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "src/main.adb") > 0,
            "sparse archive must contain sparse-included path");
         Assert
           (Ada.Strings.Fixed.Index (Data, "docs/manual.md") > 0,
            "sparse archive must also contain committed paths excluded from sparse checkout");
         Assert
           (Ada.Strings.Fixed.Index (Data, "README.md") > 0,
            "sparse archive must not be filtered by sparse state");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Sparse_Checkout_Does_Not_Filter_Archive;

   procedure Gitlink_Is_Exported_As_Placeholder
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "gitlink.tar");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Gitlink_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Data : constant String := Read_Binary_File (Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Data, "deps/libfoo") > 0,
            "archive must contain gitlink placeholder path");
         Assert
           (Ada.Strings.Fixed.Index
              (Data, "Submodule: 0123456789012345678901234567890123456789")
            > 0,
            "archive must contain deterministic gitlink placeholder content");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Gitlink_Is_Exported_As_Placeholder;

   procedure Empty_Output_Path_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Archive.Create
           (Version.Repository.Open, "HEAD", "", Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "empty archive output path must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Empty_Output_Path_Is_Rejected;

   procedure Compressed_Looking_Output_Path_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         --  .tar.gz/.tgz are now supported; .tar.xz remains unsupported.
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Join (Root, "release.tar.xz"),
            Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Raised,
         "compressed-looking archive output path must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Compressed_Looking_Output_Path_Is_Rejected;

   procedure Empty_Revision_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "",
            Join (Root, "empty-revision.tar"),
            Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert (Raised, "empty archive revision must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Empty_Revision_Is_Rejected;

   procedure Case_Insensitive_Compressed_Output_Path_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root        : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir     : constant String := Ada.Directories.Current_Directory;
      Tgz_Raised  : Boolean := False;
      Bz2_Raised  : Boolean := False;
      Zipx_Raised : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         --  .TGZ is now a supported (case-insensitive) format; .TAR.XZ is not.
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Join (Root, "release.TAR.XZ"),
            Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tgz_Raised := True;
      end;
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Join (Root, "release.tar.BZ2"),
            Version.Archive.Tar_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Bz2_Raised := True;
      end;
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Join (Root, "release.ZIPX"),
            Version.Archive.Zip_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zipx_Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Tgz_Raised,
         "uppercase TGZ archive output path must raise Data_Error");
      Assert
        (Bz2_Raised,
         "mixed-case tar.BZ2 archive output path must raise Data_Error");
      Assert
        (Zipx_Raised,
         "uppercase ZIPX archive output path must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Case_Insensitive_Compressed_Output_Path_Is_Rejected;

   procedure Symlink_Is_Exported_As_Link_Metadata
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "symlink.tar");
      Zip_Output : constant String := Join (Root, "symlink.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Symlink_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "tar -tvf symlink.tar > symlink-tar.list");
      Version.Git_Fixtures.Run
        (Root, "unzip -Z -l symlink.zip > symlink-zip.list");

      declare
         Tar_List : constant String :=
           Read_Binary_File (Join (Root, "symlink-tar.list"));
         Zip_List : constant String :=
           Read_Binary_File (Join (Root, "symlink-zip.list"));
         Zip_Data : constant String := Read_Binary_File (Zip_Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tar_List, "link-to-readme -> README.md")
            > 0,
            "TAR must export Git 120000 entries as symlinks, not regular files");
         Assert
           (Ada.Strings.Fixed.Index (Zip_List, "link-to-readme") > 0,
            "ZIP must contain symlink entry path");
         Assert
           (Ada.Strings.Fixed.Index
              (Zip_Data,
               Character'Val (0)
               & Character'Val (0)
               & Character'Val (16#FF#)
               & Character'Val (16#A1#))
            > 0,
            "ZIP central directory must carry Unix symlink mode metadata");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Symlink_Is_Exported_As_Link_Metadata;

   procedure Tar_Extraction_Preserves_Binary_Data
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "binary.tar");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Output, Version.Archive.Tar_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "tar -xOf binary.tar binary.dat > tar-binary.out");
      declare
         Extracted : constant String :=
           Read_Binary_File (Join (Root, "tar-binary.out"));
      begin
         Assert
           (Extracted = "A" & Character'Val (0) & Character'Val (255) & "Z",
            "tar extraction must preserve exact binary payload bytes");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_Extraction_Preserves_Binary_Data;

   procedure Zip_Writer_Exports_Empty_Directory_And_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root   : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Output : constant String := Join (Root, "empty.zip");
      Writer : Version.Zip.Zip_Writer;
   begin
      Version.Zip.Create (Writer, Output);
      Version.Zip.Add_Directory (Writer, "empty");
      Version.Zip.Add_File (Writer, "empty/file.txt", "");
      Version.Zip.Close (Writer);

      Version.Git_Fixtures.Run
        (Root, "unzip -Z1 empty.zip | grep '^empty/$' >/dev/null");
      Version.Git_Fixtures.Run
        (Root, "unzip -p empty.zip empty/file.txt > empty-file.out");
      declare
         Extracted : constant String :=
           Read_Binary_File (Join (Root, "empty-file.out"));
      begin
         Assert
           (Extracted = "", "zip writer must preserve empty file content");
      end;
   end Zip_Writer_Exports_Empty_Directory_And_File;

   procedure Tar_And_Zip_Preserve_Directory_Entries
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "dirs.tar");
      Zip_Output : constant String := Join (Root, "dirs.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run (Root, "tar -tf dirs.tar > tar-dirs.list");
      Version.Git_Fixtures.Run (Root, "unzip -Z1 dirs.zip > zip-dirs.list");

      declare
         Tar_List : constant String :=
           Read_Binary_File (Join (Root, "tar-dirs.list"));
         Zip_List : constant String :=
           Read_Binary_File (Join (Root, "zip-dirs.list"));
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tar_List, "src/" & Character'Val (10))
            > 0,
            "TAR archive must include explicit src/ directory entry");
         Assert
           (Ada.Strings.Fixed.Index (Tar_List, "docs/" & Character'Val (10))
            > 0,
            "TAR archive must include explicit docs/ directory entry");
         Assert
           (Ada.Strings.Fixed.Index (Zip_List, "src/" & Character'Val (10))
            > 0,
            "ZIP archive must include explicit src/ directory entry");
         Assert
           (Ada.Strings.Fixed.Index (Zip_List, "docs/" & Character'Val (10))
            > 0,
            "ZIP archive must include explicit docs/ directory entry");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Tar_And_Zip_Preserve_Directory_Entries;

   procedure Output_Path_Naming_Directory_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Join (Root, "docs"),
            Version.Archive.Zip_Format);
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Raised := True;
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Raised,
         "archive output path naming a directory must raise Data_Error");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Output_Path_Naming_Directory_Is_Rejected;

   procedure Writers_Reject_Unsafe_Archive_Entry_Paths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root                       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Tar_Output                 : constant String :=
        Join (Root, "unsafe.tar");
      Zip_Output                 : constant String :=
        Join (Root, "unsafe.zip");
      Tar_Writer                 : Version.Tar.Tar_Writer;
      Zip_Writer                 : Version.Zip.Zip_Writer;
      Tar_Parent_Raised          : Boolean := False;
      Tar_Empty_Component_Raised : Boolean := False;
      Tar_Control_Raised         : Boolean := False;
      Tar_File_Slash_Raised      : Boolean := False;
      Zip_Absolute_Raised        : Boolean := False;
      Zip_Backslash_Raised       : Boolean := False;
      Zip_Control_Raised         : Boolean := False;
      Zip_File_Slash_Raised      : Boolean := False;
   begin
      Version.Tar.Create (Tar_Writer, Tar_Output);
      begin
         Version.Tar.Add_File (Tar_Writer, "../escape.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Parent_Raised := True;
      end;
      begin
         Version.Tar.Add_File (Tar_Writer, "safe//name.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Empty_Component_Raised := True;
      end;
      begin
         Version.Tar.Add_File
           (Tar_Writer, "bad" & Character'Val (10) & "name.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Control_Raised := True;
      end;
      begin
         Version.Tar.Add_File (Tar_Writer, "directory-looking/", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_File_Slash_Raised := True;
      end;
      Version.Tar.Close (Tar_Writer);

      Version.Zip.Create (Zip_Writer, Zip_Output);
      begin
         Version.Zip.Add_File (Zip_Writer, "/absolute.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Absolute_Raised := True;
      end;
      begin
         Version.Zip.Add_File (Zip_Writer, "bad\\name.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Backslash_Raised := True;
      end;
      begin
         Version.Zip.Add_File
           (Zip_Writer, "bad" & Character'Val (13) & "name.txt", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Control_Raised := True;
      end;
      begin
         Version.Zip.Add_File (Zip_Writer, "directory-looking/", "bad");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_File_Slash_Raised := True;
      end;
      Version.Zip.Close (Zip_Writer);

      Assert
        (Tar_Parent_Raised,
         "tar writer must reject parent traversal entry paths");
      Assert
        (Tar_Empty_Component_Raised,
         "tar writer must reject empty path components");
      Assert
        (Tar_Control_Raised,
         "tar writer must reject control characters in entry paths");
      Assert
        (Tar_File_Slash_Raised,
         "tar writer must reject file paths ending in slash");
      Assert
        (Zip_Absolute_Raised, "zip writer must reject absolute entry paths");
      Assert
        (Zip_Backslash_Raised, "zip writer must reject backslash entry paths");
      Assert
        (Zip_Control_Raised,
         "zip writer must reject control characters in entry paths");
      Assert
        (Zip_File_Slash_Raised,
         "zip writer must reject file paths ending in slash");
   end Writers_Reject_Unsafe_Archive_Entry_Paths;

   procedure Writers_Reject_Duplicate_Archive_Entry_Names
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root                                : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Tar_Output                          : constant String :=
        Join (Root, "duplicate.tar");
      Zip_Output                          : constant String :=
        Join (Root, "duplicate.zip");
      Tar_Writer                          : Version.Tar.Tar_Writer;
      Zip_Writer                          : Version.Zip.Zip_Writer;
      Tar_File_Duplicate_Raised           : Boolean := False;
      Tar_Directory_File_Collision_Raised : Boolean := False;
      Zip_File_Duplicate_Raised           : Boolean := False;
      Zip_Directory_File_Collision_Raised : Boolean := False;
   begin
      Version.Tar.Create (Tar_Writer, Tar_Output);
      Version.Tar.Add_File (Tar_Writer, "dup.txt", "one");
      begin
         Version.Tar.Add_File (Tar_Writer, "dup.txt", "two");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_File_Duplicate_Raised := True;
      end;
      Version.Tar.Add_Directory (Tar_Writer, "collision");
      begin
         Version.Tar.Add_File (Tar_Writer, "collision", "not a directory");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Directory_File_Collision_Raised := True;
      end;
      Version.Tar.Close (Tar_Writer);

      Version.Zip.Create (Zip_Writer, Zip_Output);
      Version.Zip.Add_File (Zip_Writer, "dup.txt", "one");
      begin
         Version.Zip.Add_File (Zip_Writer, "dup.txt", "two");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_File_Duplicate_Raised := True;
      end;
      Version.Zip.Add_Directory (Zip_Writer, "collision");
      begin
         Version.Zip.Add_File (Zip_Writer, "collision", "not a directory");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Directory_File_Collision_Raised := True;
      end;
      Version.Zip.Close (Zip_Writer);

      Assert
        (Tar_File_Duplicate_Raised,
         "tar writer must reject duplicate file entry names");
      Assert
        (Tar_Directory_File_Collision_Raised,
         "tar writer must reject directory/file name collisions");
      Assert
        (Zip_File_Duplicate_Raised,
         "zip writer must reject duplicate file entry names");
      Assert
        (Zip_Directory_File_Collision_Raised,
         "zip writer must reject directory/file name collisions");
   end Writers_Reject_Duplicate_Archive_Entry_Names;

   procedure Writers_Reject_Unsafe_Symlink_Targets
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root                       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Tar_Output                 : constant String :=
        Join (Root, "unsafe-link-targets.tar");
      Zip_Output                 : constant String :=
        Join (Root, "unsafe-link-targets.zip");
      Tar_Writer                 : Version.Tar.Tar_Writer;
      Zip_Writer                 : Version.Zip.Zip_Writer;
      Tar_Absolute_Raised        : Boolean := False;
      Tar_Parent_Raised          : Boolean := False;
      Tar_Backslash_Raised       : Boolean := False;
      Tar_Empty_Component_Raised : Boolean := False;
      Tar_Control_Raised         : Boolean := False;
      Zip_Absolute_Raised        : Boolean := False;
      Zip_Parent_Raised          : Boolean := False;
      Zip_Backslash_Raised       : Boolean := False;
      Zip_Empty_Component_Raised : Boolean := False;
      Zip_Control_Raised         : Boolean := False;
   begin
      Version.Tar.Create (Tar_Writer, Tar_Output);
      begin
         Version.Tar.Add_Symlink (Tar_Writer, "abs-link", "/etc/passwd");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Absolute_Raised := True;
      end;
      begin
         Version.Tar.Add_Symlink (Tar_Writer, "parent-link", "../outside");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Parent_Raised := True;
      end;
      begin
         Version.Tar.Add_Symlink (Tar_Writer, "backslash-link", "dir\\target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Backslash_Raised := True;
      end;
      begin
         Version.Tar.Add_Symlink
           (Tar_Writer, "empty-component-link", "dir//target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Empty_Component_Raised := True;
      end;
      begin
         Version.Tar.Add_Symlink
           (Tar_Writer, "control-link", "dir/" & Character'Val (9) & "target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Tar_Control_Raised := True;
      end;
      Version.Tar.Close (Tar_Writer);

      Version.Zip.Create (Zip_Writer, Zip_Output);
      begin
         Version.Zip.Add_Symlink (Zip_Writer, "abs-link", "/etc/passwd");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Absolute_Raised := True;
      end;
      begin
         Version.Zip.Add_Symlink (Zip_Writer, "parent-link", "../outside");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Parent_Raised := True;
      end;
      begin
         Version.Zip.Add_Symlink (Zip_Writer, "backslash-link", "dir\\target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Backslash_Raised := True;
      end;
      begin
         Version.Zip.Add_Symlink
           (Zip_Writer, "empty-component-link", "dir//target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Empty_Component_Raised := True;
      end;
      begin
         Version.Zip.Add_Symlink
           (Zip_Writer,
            "control-link",
            "dir/" & Character'Val (10) & "target");
      exception
         when Ada.IO_Exceptions.Data_Error =>
            Zip_Control_Raised := True;
      end;
      Version.Zip.Close (Zip_Writer);

      Assert
        (Tar_Absolute_Raised,
         "tar writer must reject absolute symlink targets");
      Assert
        (Tar_Parent_Raised,
         "tar writer must reject parent traversal symlink targets");
      Assert
        (Tar_Backslash_Raised,
         "tar writer must reject backslash symlink targets");
      Assert
        (Tar_Empty_Component_Raised,
         "tar writer must reject empty symlink target components");
      Assert
        (Tar_Control_Raised,
         "tar writer must reject control characters in symlink targets");
      Assert
        (Zip_Absolute_Raised,
         "zip writer must reject absolute symlink targets");
      Assert
        (Zip_Parent_Raised,
         "zip writer must reject parent traversal symlink targets");
      Assert
        (Zip_Backslash_Raised,
         "zip writer must reject backslash symlink targets");
      Assert
        (Zip_Empty_Component_Raised,
         "zip writer must reject empty symlink target components");
      Assert
        (Zip_Control_Raised,
         "zip writer must reject control characters in symlink targets");
   end Writers_Reject_Unsafe_Symlink_Targets;

   procedure Long_Tar_Path_Uses_Ustar_Prefix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root      : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Output    : constant String := Join (Root, "long.tar");
      Long_Dir  : constant String := "long/" & String'(1 .. 96 => 'a');
      Long_Path : constant String := Long_Dir & "/file.txt";
      Writer    : Version.Tar.Tar_Writer;
   begin
      Version.Tar.Create (Writer, Output);
      Version.Tar.Add_File
        (Writer, Long_Path, "long path content" & Character'Val (10));
      Version.Tar.Close (Writer);

      Version.Git_Fixtures.Run
        (Root, "tar -xOf long.tar " & Long_Path & " > long.out");
      Assert
        (Read_Binary_File (Join (Root, "long.out"))
         = "long path content" & Character'Val (10),
         "tar writer must emit extractable ustar name/prefix entries");
   end Long_Tar_Path_Uses_Ustar_Prefix;

   procedure Archive_Output_Is_Deterministic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Tar_One : constant String := Join (Root, "one.tar");
      Tar_Two : constant String := Join (Root, "two.tar");
      Zip_One : constant String := Join (Root, "one.zip");
      Zip_Two : constant String := Join (Root, "two.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_One, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_Two, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Zip_One, Version.Archive.Zip_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Zip_Two, Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Assert
        (Read_Binary_File (Tar_One) = Read_Binary_File (Tar_Two),
         "same revision TAR archives must be byte deterministic");
      Assert
        (Read_Binary_File (Zip_One) = Read_Binary_File (Zip_Two),
         "same revision ZIP archives must be byte deterministic");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Output_Is_Deterministic;

   procedure Archive_Prefix_Rewrites_Tar_And_Zip_Roots
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "prefixed.tar");
      Zip_Output : constant String := Join (Root, "prefixed.zip");
      Specs      : Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Version.Pathspec.Append_Parse (Specs, "src/");
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format,
         Specs,
         "release/");
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format,
         Specs,
         "release/");
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Tar_Data : constant String := Read_Binary_File (Tar_Output);
         Zip_Data : constant String := Read_Binary_File (Zip_Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "release/") > 0,
            "prefixed TAR must contain the explicit root prefix directory");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "release/src/main.adb") > 0,
            "prefixed TAR must rewrite selected entries below the prefix");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "README.md") = 0,
            "prefixed filtered TAR must still apply pathspecs before prefixing");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, "release/") > 0,
            "prefixed ZIP must contain the explicit root prefix directory");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, "release/src/main.adb") > 0,
            "prefixed ZIP must rewrite selected entries below the prefix");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, "README.md") = 0,
            "prefixed filtered ZIP must still apply pathspecs before prefixing");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Prefix_Rewrites_Tar_And_Zip_Roots;

   procedure Unsafe_Archive_Prefix_Is_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Specs   : Version.Pathspec.Pathspec_Vectors.Vector;

      procedure Expect_Rejected (Prefix : String) is
         Raised  : Boolean := False;
         Message : Unbounded_String;
      begin
         begin
            Version.Archive.Create
              (Version.Repository.Open,
               "HEAD",
               Join (Root, "unsafe-prefix.tar"),
               Version.Archive.Tar_Format,
               Specs,
               Prefix);
         exception
            when E : Ada.IO_Exceptions.Data_Error =>
               Raised := True;
               Message :=
                 To_Unbounded_String (Ada.Exceptions.Exception_Message (E));
         end;
         Assert
           (Raised, "unsafe archive prefix must raise Data_Error: " & Prefix);
         Assert
           (Ada.Strings.Fixed.Index (To_String (Message), "archive prefix")
            > 0,
            "unsafe archive prefix diagnostic must identify prefix context: "
            & Prefix);
      end Expect_Rejected;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Expect_Rejected ("/release");
      Expect_Rejected ("../release");
      Expect_Rejected ("release//src");
      Expect_Rejected ("release/.hidden/..");
      Expect_Rejected ("release/.git");
      Expect_Rejected ("release" & Character'Val (9));
      Ada.Directories.Set_Directory (Old_Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Unsafe_Archive_Prefix_Is_Rejected;

   procedure Expect_Hostile_Object_Archive_Rejected
     (Root          : String;
      Hostile_Path  : String;
      Format        : Version.Archive.Archive_Format;
      Assertion_Tag : String)
   is
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String :=
        Join
          (Root,
           "hostile-"
           & Assertion_Tag
           & (if Format = Version.Archive.Zip_Format then ".zip" else ".tar"));
      Raised  : Boolean := False;
   begin
      Version.Init.Init (Root);
      Ada.Directories.Set_Directory (Root);

      declare
         Repo         : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Blob_Id      : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Blob (Repo, "archive hostile payload");
         Tree_Content : constant String :=
           "100644 " & Hostile_Path & Character'Val (0) & Raw_Id (Blob_Id);
         Tree_Id      : constant Version.Objects.Hex_Object_Id :=
           Write_Raw_Object (Repo, "tree", Tree_Content);
         Commit_Id    : constant Version.Objects.Hex_Object_Id :=
           Version.Write.Write_Commit
             (Repo      => Repo,
              Tree_Id   => Tree_Id,
              Parent_Id => "",
              Message   => "hostile archive tree");
      begin
         Point_Main_At (Repo, Commit_Id);

         begin
            Version.Archive.Create (Repo, "HEAD", Output, Format);
         exception
            when Ada.IO_Exceptions.Data_Error =>
               Raised := True;
         end;
      end;

      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Raised, Assertion_Tag & " must be rejected during archive export");
      Assert
        (not Ada.Directories.Exists (Output),
         Assertion_Tag & " must not leave a partial output archive");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Expect_Hostile_Object_Archive_Rejected;

   procedure Archive_Rejects_Hostile_Object_Tree_Entries
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "hostile-parent"),
         "../escape.txt",
         Version.Archive.Tar_Format,
         "parent-traversal");
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "hostile-nested"),
         "safe/../../escape.txt",
         Version.Archive.Zip_Format,
         "nested-traversal");
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "hostile-dotgit"),
         ".git/hooks/post-checkout",
         Version.Archive.Tar_Format,
         "dot-git-hook");
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "hostile-empty"),
         "a//b",
         Version.Archive.Zip_Format,
         "empty-component");
   end Archive_Rejects_Hostile_Object_Tree_Entries;

   procedure Gitlink_Archive_Behavior_Matches_Docs
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "gitlink-doc.tar");
      Zip_Output : constant String := Join (Root, "gitlink-doc.zip");
      Expected   : constant String :=
        "Submodule: 0123456789012345678901234567890123456789";
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Add_Gitlink_Commit (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      declare
         Tar_Data : constant String := Read_Binary_File (Tar_Output);
         Zip_Data : constant String := Read_Binary_File (Zip_Output);
      begin
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, "deps/libfoo") > 0,
            "TAR archive must contain documented gitlink placeholder path");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, "deps/libfoo") > 0,
            "ZIP archive must contain documented gitlink placeholder path");
         Assert
           (Ada.Strings.Fixed.Index (Tar_Data, Expected) > 0,
            "TAR archive must contain documented gitlink placeholder content");
         Assert
           (Ada.Strings.Fixed.Index (Zip_Data, Expected) > 0,
            "ZIP archive must contain documented gitlink placeholder content");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Gitlink_Archive_Behavior_Matches_Docs;

   procedure Unsupported_Archive_Output_Message_Is_Stable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Output  : constant String := Join (Root, "release.tar.xz");
      Raised  : Boolean := False;
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      begin
         Version.Archive.Create
           (Version.Repository.Open,
            "HEAD",
            Output,
            Version.Archive.Tar_Format);
      exception
         when E : Ada.IO_Exceptions.Data_Error =>
            Raised := True;
            Assert
              (Ada.Exceptions.Exception_Message (E)
               = Version.Archive.Unsupported_Output_Format_Text (Output),
               "unsupported archive output format diagnostic must remain stable");
            Assert
              (Ada.Strings.Fixed.Index
                 (Ada.Exceptions.Exception_Message (E),
                  "use --format tar|tar.gz|zip")
               > 0,
               "unsupported archive output diagnostic should suggest --format");
      end;
      Ada.Directories.Set_Directory (Old_Dir);
      Assert
        (Raised, "unsupported compressed archive output must be rejected");
      Assert
        (not Ada.Directories.Exists (Output),
         "unsupported archive output rejection must not create a file");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Unsupported_Archive_Output_Message_Is_Stable;

   procedure Archive_Failure_Removes_Partial_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
   begin
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "partial-tar"),
         ".git/config",
         Version.Archive.Tar_Format,
         "partial-cleanup-tar");
      Expect_Hostile_Object_Archive_Rejected
        (Join (Root, "partial-zip"),
         ".git/config",
         Version.Archive.Zip_Format,
         "partial-cleanup-zip");
   end Archive_Failure_Removes_Partial_Output;

   procedure Archive_Failure_Preserves_Preexisting_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check_One
        (Subdir : String;
         Format : Version.Archive.Archive_Format;
         Name   : String)
      is
         Case_Root : constant String := Join (Root, Subdir);
         Output    : constant String := Join (Case_Root, Name);
         Old_Dir   : constant String := Ada.Directories.Current_Directory;
         Raised    : Boolean := False;
      begin
         Version.Init.Init (Case_Root);
         Version.Test_Support.Write_Text_File
           (Output, "previous archive content");
         Ada.Directories.Set_Directory (Case_Root);

         declare
            Repo         : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Blob_Id      : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Blob (Repo, "hostile payload");
            Tree_Content : constant String :=
              "100644 .git/config" & Character'Val (0) & Raw_Id (Blob_Id);
            Tree_Id      : constant Version.Objects.Hex_Object_Id :=
              Write_Raw_Object (Repo, "tree", Tree_Content);
            Commit_Id    : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit
                (Repo      => Repo,
                 Tree_Id   => Tree_Id,
                 Parent_Id => "",
                 Message   => "hostile archive existing output");
         begin
            Point_Main_At (Repo, Commit_Id);
            begin
               Version.Archive.Create (Repo, "HEAD", Output, Format);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
         end;

         Ada.Directories.Set_Directory (Old_Dir);
         Assert
           (Raised, "hostile archive must fail for existing output: " & Name);
         Assert
           (Read_Binary_File (Output) = "previous archive content",
            "failed archive must preserve preexisting output: " & Name);
         Assert
           (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
            "failed archive must remove temporary output: " & Name);
      exception
         when others =>
            Ada.Directories.Set_Directory (Old_Dir);
            raise;
      end Check_One;
   begin
      Check_One
        ("preserve-existing-tar", Version.Archive.Tar_Format, "existing.tar");
      Check_One
        ("preserve-existing-zip", Version.Archive.Zip_Format, "existing.zip");
   end Archive_Failure_Preserves_Preexisting_Output;

   procedure Archive_Failure_Removes_Temporary_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check_One
        (Subdir : String; Format : Version.Archive.Archive_Format)
      is
         Case_Root : constant String := Join (Root, Subdir);
         Tag       : constant String := "temp-cleanup-" & Subdir;
         Output    : constant String :=
           Join
             (Case_Root,
              "hostile-"
              & Tag
              & (if Format = Version.Archive.Zip_Format
                 then ".zip"
                 else ".tar"));
      begin
         Expect_Hostile_Object_Archive_Rejected
           (Case_Root, ".git/config", Format, Tag);
         Assert
           (not Ada.Directories.Exists (Output),
            "failed archive must not leave final output: " & Output);
         Assert
           (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
            "failed archive must remove temporary output: " & Output);
      end Check_One;
   begin
      Check_One ("temp-tar", Version.Archive.Tar_Format);
      Check_One ("temp-zip", Version.Archive.Zip_Format);
   end Archive_Failure_Removes_Temporary_Output;

   procedure Archive_Rejects_Unsafe_Symlink_Targets_From_Object_Database
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check_One
        (Subdir      : String;
         Format      : Version.Archive.Archive_Format;
         Link_Target : String)
      is
         Case_Root : constant String := Join (Root, Subdir);
         Old_Dir   : constant String := Ada.Directories.Current_Directory;
         Output    : constant String :=
           Join
             (Case_Root,
              "unsafe-link"
              & (if Format = Version.Archive.Zip_Format
                 then ".zip"
                 else ".tar"));
         Raised    : Boolean := False;
      begin
         Version.Init.Init (Case_Root);
         Ada.Directories.Set_Directory (Case_Root);

         declare
            Repo         : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Link_Id      : constant Version.Objects.Hex_Object_Id :=
              Write_Raw_Object (Repo, "blob", Link_Target);
            Tree_Content : constant String :=
              "120000 link" & Character'Val (0) & Raw_Id (Link_Id);
            Tree_Id      : constant Version.Objects.Hex_Object_Id :=
              Write_Raw_Object (Repo, "tree", Tree_Content);
            Commit_Id    : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit
                (Repo      => Repo,
                 Tree_Id   => Tree_Id,
                 Parent_Id => "",
                 Message   => "unsafe symlink archive");
         begin
            Point_Main_At (Repo, Commit_Id);
            begin
               Version.Archive.Create (Repo, "HEAD", Output, Format);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
         end;

         Ada.Directories.Set_Directory (Old_Dir);
         Assert
           (Raised,
            "archive must reject unsafe symlink target from object database");
         Assert
           (not Ada.Directories.Exists (Output),
            "unsafe symlink archive must not leave final output");
         Assert
           (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
            "unsafe symlink archive must clean temporary output");
      exception
         when others =>
            Ada.Directories.Set_Directory (Old_Dir);
            raise;
      end Check_One;
   begin
      Check_One
        ("unsafe-link-parent-tar", Version.Archive.Tar_Format, "../outside");
      Check_One
        ("unsafe-link-absolute-zip",
         Version.Archive.Zip_Format,
         "/etc/passwd");
      Check_One
        ("unsafe-link-backslash-tar",
         Version.Archive.Tar_Format,
         "dir\target");
      Check_One
        ("unsafe-link-empty-zip", Version.Archive.Zip_Format, "dir//target");
   end Archive_Rejects_Unsafe_Symlink_Targets_From_Object_Database;

   procedure Archive_Rejects_Unsupported_Object_Mode_Without_Output
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));

      procedure Check_One
        (Subdir : String;
         Format : Version.Archive.Archive_Format;
         Mode   : String)
      is
         Case_Root : constant String := Join (Root, Subdir);
         Old_Dir   : constant String := Ada.Directories.Current_Directory;
         Output    : constant String :=
           Join
             (Case_Root,
              "bad-mode"
              & (if Format = Version.Archive.Zip_Format
                 then ".zip"
                 else ".tar"));
         Raised    : Boolean := False;
      begin
         Version.Init.Init (Case_Root);
         Ada.Directories.Set_Directory (Case_Root);

         declare
            Repo         : constant Version.Repository.Repository_Handle :=
              Version.Repository.Open;
            Blob_Id      : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Blob (Repo, "bad mode payload");
            Tree_Content : constant String :=
              Mode & " strange" & Character'Val (0) & Raw_Id (Blob_Id);
            Tree_Id      : constant Version.Objects.Hex_Object_Id :=
              Write_Raw_Object (Repo, "tree", Tree_Content);
            Commit_Id    : constant Version.Objects.Hex_Object_Id :=
              Version.Write.Write_Commit
                (Repo      => Repo,
                 Tree_Id   => Tree_Id,
                 Parent_Id => "",
                 Message   => "unsupported archive mode");
         begin
            Point_Main_At (Repo, Commit_Id);
            begin
               Version.Archive.Create (Repo, "HEAD", Output, Format);
            exception
               when Ada.IO_Exceptions.Data_Error =>
                  Raised := True;
            end;
         end;

         Ada.Directories.Set_Directory (Old_Dir);
         Assert (Raised, "unsupported object mode must be rejected: " & Mode);
         Assert
           (not Ada.Directories.Exists (Output),
            "unsupported mode archive must not leave final output");
         Assert
           (not Ada.Directories.Exists (Output & ".version-archive-tmp"),
            "unsupported mode archive must remove temporary output");
      exception
         when others =>
            Ada.Directories.Set_Directory (Old_Dir);
            raise;
      end Check_One;
   begin
      Check_One ("bad-mode-tar", Version.Archive.Tar_Format, "100664");
      Check_One ("bad-mode-zip", Version.Archive.Zip_Format, "100664");
   end Archive_Rejects_Unsupported_Object_Mode_Without_Output;

   procedure Archive_Entry_Order_Repeated_Runs_Is_Stable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root    : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir : constant String := Ada.Directories.Current_Directory;
      Tar_One : constant String := Join (Root, "order-one.tar");
      Tar_Two : constant String := Join (Root, "order-two.tar");
      Zip_One : constant String := Join (Root, "order-one.zip");
      Zip_Two : constant String := Join (Root, "order-two.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_One, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_Two, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Zip_One, Version.Archive.Zip_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Zip_Two, Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "tar -tf order-one.tar > order-one-tar.list");
      Version.Git_Fixtures.Run
        (Root, "tar -tf order-two.tar > order-two-tar.list");
      Version.Git_Fixtures.Run
        (Root, "unzip -Z1 order-one.zip > order-one-zip.list");
      Version.Git_Fixtures.Run
        (Root, "unzip -Z1 order-two.zip > order-two-zip.list");

      Assert
        (Read_Binary_File (Join (Root, "order-one-tar.list"))
         = Read_Binary_File (Join (Root, "order-two-tar.list")),
         "TAR entry order must be stable across repeated runs");
      Assert
        (Read_Binary_File (Join (Root, "order-one-zip.list"))
         = Read_Binary_File (Join (Root, "order-two-zip.list")),
         "ZIP entry order must be stable across repeated runs");
      Assert
        (Read_Binary_File (Tar_One) = Read_Binary_File (Tar_Two),
         "TAR bytes must remain deterministic while preserving order");
      Assert
        (Read_Binary_File (Zip_One) = Read_Binary_File (Zip_Two),
         "ZIP bytes must remain deterministic while preserving order");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Entry_Order_Repeated_Runs_Is_Stable;

   procedure Cross_Format_Extraction_Preserves_File_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "bytes.tar");
      Zip_Output : constant String := Join (Root, "bytes.zip");
   begin
      Init_Repo_With_Archive_Fixture (Root);
      Ada.Directories.Set_Directory (Root);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Tar_Output,
         Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open,
         "HEAD",
         Zip_Output,
         Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "tar -xOf bytes.tar crlf.txt > tar-crlf.out");
      Version.Git_Fixtures.Run
        (Root, "unzip -p bytes.zip crlf.txt > zip-crlf.out");
      Version.Git_Fixtures.Run
        (Root,
         "tar -xOf bytes.tar compressed-looking.bin > tar-compressed.out");
      Version.Git_Fixtures.Run
        (Root,
         "unzip -p bytes.zip compressed-looking.bin > zip-compressed.out");

      Assert
        (Read_Binary_File (Join (Root, "tar-crlf.out"))
         = "one"
           & Character'Val (13)
           & Character'Val (10)
           & "two"
           & Character'Val (13)
           & Character'Val (10),
         "tar extraction must preserve CRLF text bytes");
      Assert
        (Read_Binary_File (Join (Root, "zip-crlf.out"))
         = Read_Binary_File (Join (Root, "tar-crlf.out")),
         "zip and tar must preserve identical CRLF bytes");
      Assert
        (Read_Binary_File (Join (Root, "zip-compressed.out"))
         = Read_Binary_File (Join (Root, "tar-compressed.out")),
         "zip and tar must preserve compressed-looking binary bytes identically");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Cross_Format_Extraction_Preserves_File_Bytes;

   procedure Archive_Preserves_LFS_Pointer_File_Bytes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "lfs-pointer.tar");
      Zip_Output : constant String := Join (Root, "lfs-pointer.zip");
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Files.Write_Binary_File
        (Join (Root, "asset.bin"), LFS_Pointer);
      Version.Git_Fixtures.Run (Root, "git add asset.bin");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("archive LFS pointer");
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Tar_Output, Version.Archive.Tar_Format);
      Version.Archive.Create
        (Version.Repository.Open, "HEAD", Zip_Output, Version.Archive.Zip_Format);
      Ada.Directories.Set_Directory (Old_Dir);

      Version.Git_Fixtures.Run
        (Root, "tar -xOf lfs-pointer.tar asset.bin > lfs-pointer-tar.out");
      Version.Git_Fixtures.Run
        (Root, "unzip -p lfs-pointer.zip asset.bin > lfs-pointer-zip.out");

      Assert
        (Read_Binary_File (Join (Root, "lfs-pointer-tar.out")) = LFS_Pointer,
         "tar archive must preserve LFS pointer bytes as ordinary file data");
      Assert
        (Read_Binary_File (Join (Root, "lfs-pointer-zip.out")) = LFS_Pointer,
         "zip archive must preserve LFS pointer bytes as ordinary file data");
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Preserves_LFS_Pointer_File_Bytes;

   --  git parity: export-subst expands `$Format:<pretty>$` in attributed blobs
   --  to the archived commit's metadata; a nested `.gitattributes` grants the
   --  attribute to its subtree; non-attributed files are left byte-for-byte.
   procedure Archive_Export_Subst_Expands_Like_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      Root       : constant String :=
        Version.Temp_Fixture.Root (Version.Temp_Fixture.Test_Case (T));
      Old_Dir    : constant String := Ada.Directories.Current_Directory;
      Tar_Output : constant String := Join (Root, "export-subst.tar");
      Zip_Output : constant String := Join (Root, "export-subst.zip");
      Attributes : constant String := "*.txt export-subst";
   begin
      Version.Init.Init (Root);
      Version.Git_Fixtures.Run
        (Root, "git config user.email test@example.com");
      Version.Git_Fixtures.Run (Root, "git config user.name Test");
      Version.Git_Fixtures.Run (Root, "git config gc.auto 0");
      Version.Files.Write_Binary_File
        (Join (Root, ".gitattributes"), Attributes);
      Version.Files.Write_Binary_File
        (Join (Root, "version.txt"), "commit $Format:%H$");
      --  Not matched by *.txt, and no attribute: must stay literal.
      Version.Files.Write_Binary_File
        (Join (Root, "raw.dat"), "raw $Format:%H$ untouched");
      Ada.Directories.Create_Directory (Join (Root, "sub"));
      --  Nested .gitattributes grants export-subst to sub/*.txt.
      Version.Files.Write_Binary_File
        (Join (Root, "sub/.gitattributes"), "*.txt export-subst");
      Version.Files.Write_Binary_File
        (Join (Root, "sub/inner.txt"), "short $Format:%h$");
      Version.Git_Fixtures.Run (Root, "git add -A");

      Ada.Directories.Set_Directory (Root);
      Version.Write.Save ("archive export-subst");
      declare
         Repo : constant Version.Repository.Repository_Handle :=
           Version.Repository.Open;
         Full : constant String :=
           Version.Objects.To_String
             (Version.Revisions.Resolve_Commit (Repo, "HEAD"));
         Short : constant String := Full (Full'First .. Full'First + 6);
      begin
         Version.Archive.Create
           (Repo, "HEAD", Tar_Output, Version.Archive.Tar_Format);
         Version.Archive.Create
           (Repo, "HEAD", Zip_Output, Version.Archive.Zip_Format);
         Ada.Directories.Set_Directory (Old_Dir);

         Version.Git_Fixtures.Run
           (Root, "tar -xOf export-subst.tar version.txt > st-tar.out");
         Version.Git_Fixtures.Run
           (Root, "unzip -p export-subst.zip version.txt > st-zip.out");
         Version.Git_Fixtures.Run
           (Root, "tar -xOf export-subst.tar sub/inner.txt > sub-tar.out");
         Version.Git_Fixtures.Run
           (Root, "tar -xOf export-subst.tar raw.dat > raw-tar.out");
         Version.Git_Fixtures.Run
           (Root, "tar -xOf export-subst.tar .gitattributes > attrs-tar.out");

         Assert
           (Read_Binary_File (Join (Root, "st-tar.out")) = "commit " & Full,
            "tar export-subst must expand %H to the commit id");
         Assert
           (Read_Binary_File (Join (Root, "st-zip.out")) = "commit " & Full,
            "zip export-subst must expand %H to the commit id");
         Assert
           (Read_Binary_File (Join (Root, "sub-tar.out")) = "short " & Short,
            "nested export-subst must expand %h for sub/*.txt");
         Assert
           (Read_Binary_File (Join (Root, "raw-tar.out"))
              = "raw $Format:%H$ untouched",
            "non-attributed file must not be substituted");
         Assert
           (Read_Binary_File (Join (Root, "attrs-tar.out")) = Attributes,
            "tar archive must preserve .gitattributes literally");
      end;
   exception
      when others =>
         Ada.Directories.Set_Directory (Old_Dir);
         raise;
   end Archive_Export_Subst_Expands_Like_Git;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
   begin
      Register_Routine
        (T, Tar_Exports_Head_Tree'Access, "archive: TAR exports HEAD tree");
      Register_Routine
        (T, Tar_Gz_Decompresses_To_Tar'Access,
         "archive: tar.gz is a valid gzip that decompresses to the tar");
      Register_Routine
        (T, Zip_Exports_Head_Tree'Access, "archive: ZIP exports HEAD tree");
      Register_Routine
        (T, Pathspec_Filters_Zip'Access, "archive: ZIP pathspec filtering");
      Register_Routine
        (T,
         Pathspec_Exclusion_Filters_Tar'Access,
         "archive: TAR pathspec exclusion filtering");
      Register_Routine
        (T,
         No_Matching_Pathspec_Creates_Empty_Archives'Access,
         "archive: no-match pathspec creates empty archives");
      Register_Routine
        (T,
         Tagged_Revision_Exports_Selected_Tree'Access,
         "archive: tagged revision exports selected tree");
      Register_Routine
        (T,
         Branch_Revision_Exports_Selected_Tree'Access,
         "archive: branch revision exports selected tree");
      Register_Routine
        (T,
         Tar_Preserves_Executable_Mode'Access,
         "archive: TAR preserves executable mode");
      Register_Routine
        (T,
         Missing_Revision_Is_Rejected'Access,
         "archive: missing revision rejected");
      Register_Routine
        (T,
         Empty_Revision_Is_Rejected'Access,
         "archive: empty revision rejected");
      Register_Routine
        (T,
         Empty_Output_Path_Is_Rejected'Access,
         "archive: empty output path rejected");
      Register_Routine
        (T,
         Output_Path_Naming_Directory_Is_Rejected'Access,
         "archive: output path naming directory rejected");
      Register_Routine
        (T,
         Compressed_Looking_Output_Path_Is_Rejected'Access,
         "archive: compressed-looking output path rejected");
      Register_Routine
        (T,
         Case_Insensitive_Compressed_Output_Path_Is_Rejected'Access,
         "archive: case-insensitive compressed output path rejected");
      Register_Routine
        (T,
         Writers_Reject_Unsafe_Archive_Entry_Paths'Access,
         "archive: writers reject unsafe entry paths");
      Register_Routine
        (T,
         Writers_Reject_Duplicate_Archive_Entry_Names'Access,
         "archive: writers reject duplicate entry names");
      Register_Routine
        (T,
         Writers_Reject_Unsafe_Symlink_Targets'Access,
         "archive: writers reject unsafe symlink targets");
      Register_Routine
        (T,
         Long_Tar_Path_Uses_Ustar_Prefix'Access,
         "archive: TAR long path uses ustar prefix");
      Register_Routine
        (T,
         Sparse_Checkout_Does_Not_Filter_Archive'Access,
         "archive: sparse checkout does not filter archive");
      Register_Routine
        (T,
         Gitlink_Is_Exported_As_Placeholder'Access,
         "archive: gitlink exported as placeholder");
      Register_Routine
        (T,
         Symlink_Is_Exported_As_Link_Metadata'Access,
         "archive: symlink entries preserve link metadata");
      Register_Routine
        (T,
         Tar_Extraction_Preserves_Binary_Data'Access,
         "archive: TAR extraction preserves binary data");
      Register_Routine
        (T,
         Zip_Writer_Exports_Empty_Directory_And_File'Access,
         "archive: ZIP writer exports empty dir and file");
      Register_Routine
        (T,
         Tar_And_Zip_Preserve_Directory_Entries'Access,
         "archive: TAR and ZIP preserve explicit directory entries");
      Register_Routine
        (T,
         Archive_Prefix_Rewrites_Tar_And_Zip_Roots'Access,
         "archive: prefix rewrites TAR and ZIP roots");
      Register_Routine
        (T,
         Unsafe_Archive_Prefix_Is_Rejected'Access,
         "archive: unsafe prefix rejected");
      Register_Routine
        (T,
         Archive_Output_Is_Deterministic'Access,
         "archive: output is deterministic");
      Register_Routine
        (T,
         Tar_And_Zip_Contain_Same_Core_Files'Access,
         "archive: TAR and ZIP contain same core files");
      Register_Routine
        (T,
         Archive_Rejects_Hostile_Object_Tree_Entries'Access,
         "archive: hostile object tree entries are rejected");
      Register_Routine
        (T,
         Gitlink_Archive_Behavior_Matches_Docs'Access,
         "archive: gitlink behavior matches docs");
      Register_Routine
        (T,
         Unsupported_Archive_Output_Message_Is_Stable'Access,
         "archive: unsupported output diagnostic is stable");
      Register_Routine
        (T,
         Archive_Failure_Removes_Partial_Output'Access,
         "archive: failure removes partial output");
      Register_Routine
        (T,
         Archive_Failure_Preserves_Preexisting_Output'Access,
         "archive: failure preserves preexisting output");
      Register_Routine
        (T,
         Archive_Failure_Removes_Temporary_Output'Access,
         "archive: failure removes temporary output");
      Register_Routine
        (T,
         Archive_Rejects_Unsafe_Symlink_Targets_From_Object_Database'Access,
         "archive: rejects unsafe object symlink targets");
      Register_Routine
        (T,
         Archive_Rejects_Unsupported_Object_Mode_Without_Output'Access,
         "archive: rejects unsupported object mode without output");
      Register_Routine
        (T,
         Archive_Entry_Order_Repeated_Runs_Is_Stable'Access,
         "archive: repeated entry order is stable");
      Register_Routine
        (T,
         Cross_Format_Extraction_Preserves_File_Bytes'Access,
         "archive: TAR and ZIP preserve extracted bytes identically");
      Register_Routine
        (T,
         Archive_Preserves_LFS_Pointer_File_Bytes'Access,
         "archive: LFS pointer file bytes preserved");
      Register_Routine
        (T,
         Archive_Export_Subst_Expands_Like_Git'Access,
         "archive: export-subst expands $Format:...$ like git");
   end Register_Tests;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Archive");
   end Name;

end Version.Archive.Tests;
