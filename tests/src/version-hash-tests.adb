with Ada.Unchecked_Deallocation;

with AUnit.Assertions;   use AUnit.Assertions;

package body Version.Hash.Tests is

   use AUnit.Test_Cases.Registration;

   --  Hashing a multi-megabyte input (larger than the task stack) must not
   --  overflow and must agree with the incremental digest of the same bytes
   --  (regression for the streaming/chunked delegation to CryptoLib.Hashes).
   procedure Large_Input_Hashing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Size : constant := 9_000_000;
      type String_Access is access String;
      procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);
      Data : String_Access := new String'(1 .. Size => 'A');
   begin
      declare
         One_Shot : constant String := Version.Hash.Sha1_Hex (Data.all);
         Ctx      : Version.Hash.Sha1_Context;
      begin
         Version.Hash.Initialize (Ctx);
         Version.Hash.Update (Ctx, Data.all);
         Assert (One_Shot'Length = 40,
                 "large-input SHA-1 must produce a 40-hex digest");
         Assert (Version.Hash.Final_Hex (Ctx) = One_Shot,
                 "large-input incremental SHA-1 must equal the one-shot digest");
         Assert (Version.Hash.Sha256_Hex (Data.all)'Length = 64,
                 "large-input SHA-256 must produce a 64-hex digest");
      end;
      Free (Data);
   exception
      when others =>
         Free (Data);
         raise;
   end Large_Input_Hashing;

   procedure Empty_String_SHA1
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha1_Hex ("") =
           "da39a3ee5e6b4b0d3255bfef95601890afd80709",
         "SHA-1 of empty string is incorrect");
   end Empty_String_SHA1;

   procedure ABC_SHA1
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha1_Hex ("abc") =
           "a9993e364706816aba3e25717850c26c9cd0d89d",
         "SHA-1 of abc is incorrect");
   end ABC_SHA1;

   procedure Git_Blob_SHA1
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Header : constant String := "blob 6" & Character'Val (0);
   begin
      Assert
        (Version.Hash.Sha1_Hex (Header & "hello" & Character'Val (10)) =
           "ce013625030ba8dba906f756967f9e9ca394464a",
         "Git blob id for hello LF is incorrect");
   end Git_Blob_SHA1;

   procedure Incremental_SHA1_Matches_One_Shot
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Context : Version.Hash.Sha1_Context;
   begin
      Version.Hash.Initialize (Context);
      Version.Hash.Update (Context, "ab");
      Version.Hash.Update (Context, "c");

      Assert
        (Version.Hash.Final_Hex (Context) = Version.Hash.Sha1_Hex ("abc"),
         "incremental SHA-1 should match one-shot SHA-1");
   end Incremental_SHA1_Matches_One_Shot;

   procedure Incremental_SHA1_Crosses_Block_Boundary
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Context : Version.Hash.Sha1_Context;
   begin
      Version.Hash.Initialize (Context);
      Version.Hash.Update (Context, "01234567890123456789012345678901");
      Version.Hash.Update (Context, "abcdefghijklmnopqrstuvwxyzABCDE");
      Version.Hash.Update (Context, "tail");

      Assert
        (Version.Hash.Final_Hex (Context) =
           Version.Hash.Sha1_Hex
             ("01234567890123456789012345678901"
              & "abcdefghijklmnopqrstuvwxyzABCDE"
              & "tail"),
         "incremental SHA-1 should process full internal blocks correctly");
   end Incremental_SHA1_Crosses_Block_Boundary;

   procedure Empty_String_SHA256
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha256_Hex ("") =
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
         "SHA-256 of empty string should match FIPS 180-4 vector");
   end Empty_String_SHA256;

   procedure ABC_SHA256
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha256_Hex ("abc") =
           "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
         "SHA-256 of ""abc"" should match FIPS 180-4 vector");
   end ABC_SHA256;

   procedure Fox_SHA256
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha256_Hex
           ("The quick brown fox jumps over the lazy dog") =
           "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
         "SHA-256 of the pangram should match the known vector");
   end Fox_SHA256;

   procedure Incremental_SHA256_Crosses_Block_Boundary
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Context : Version.Hash.Sha256_Context;
   begin
      Version.Hash.Initialize (Context);
      Version.Hash.Update (Context, "01234567890123456789012345678901");
      Version.Hash.Update (Context, "abcdefghijklmnopqrstuvwxyzABCDE");
      Version.Hash.Update (Context, "tail");

      Assert
        (Version.Hash.Final_Hex (Context) =
           Version.Hash.Sha256_Hex
             ("01234567890123456789012345678901"
              & "abcdefghijklmnopqrstuvwxyzABCDE"
              & "tail"),
         "incremental SHA-256 should process full internal blocks correctly");
   end Incremental_SHA256_Crosses_Block_Boundary;

   procedure SHA256_Raw_And_Lengths
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Version.Hash.Sha256_Raw ("abc")'Length = 32,
         "SHA-256 raw digest should be 32 bytes");
      Assert
        (Version.Hash.Hex_Length (Version.Hash.Sha256) = 64
         and then Version.Hash.Raw_Length (Version.Hash.Sha256) = 32
         and then Version.Hash.Hex_Length (Version.Hash.Sha1) = 40
         and then Version.Hash.Raw_Length (Version.Hash.Sha1) = 20,
         "hash algorithm id widths must be 40/20 (sha1) and 64/32 (sha256)");
   end SHA256_Raw_And_Lengths;

   procedure Object_Hash_Dispatch_Matches_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Blob_Header : constant String := "blob 5" & Character'Val (0) & "hello";
   begin
      --  A git object id is <algo>("<kind> <size>\0" & content). This exact
      --  sha256 value was produced by `git --object-format=sha256
      --  hash-object` for the 5-byte blob "hello" (see docs/SHA256_SCOPE.md).
      Assert
        (Version.Hash.Object_Hash_Hex (Version.Hash.Sha256, Blob_Header) =
           "8aec4e4876f854f688d0ebfc8f37598f38e5fd6903cccc850ca36591175aeb60",
         "Object_Hash_Hex (Sha256, blob header) must equal git's sha256 id");
      Assert
        (Version.Hash.Object_Hash_Hex (Version.Hash.Sha1, Blob_Header) =
           Version.Hash.Sha1_Hex (Blob_Header),
         "Object_Hash_Hex (Sha1, ...) must dispatch to Sha1_Hex");
      Assert
        (Version.Hash.Object_Hash_Raw (Version.Hash.Sha256, Blob_Header)'Length
           = 32
         and then Version.Hash.Object_Hash_Raw
           (Version.Hash.Sha1, Blob_Header)'Length = 20,
         "Object_Hash_Raw must dispatch to the algorithm's raw width");
   end Object_Hash_Dispatch_Matches_Git;

   procedure Streaming_Context_Matches_One_Shot
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      procedure Check (Algorithm : Version.Hash.Hash_Algorithm) is
         Ctx : Version.Hash.Streaming_Context (Algorithm);
      begin
         Version.Hash.Initialize (Ctx);
         Version.Hash.Update (Ctx, "the quick ");
         Version.Hash.Update (Ctx, "brown fox");
         Assert
           (Version.Hash.Final_Raw (Ctx) =
              Version.Hash.Object_Hash_Raw (Algorithm, "the quick brown fox"),
            "streaming hash must equal the one-shot digest for "
            & Algorithm'Image);
      end Check;
   begin
      Check (Version.Hash.Sha1);
      Check (Version.Hash.Sha256);
   end Streaming_Context_Matches_One_Shot;

   overriding procedure Register_Tests
     (T : in out Test_Case)
   is
   begin
      Register_Routine
        (T, Streaming_Context_Matches_One_Shot'Access,
         "Streaming_Context matches one-shot digest (sha1 + sha256)");
      Register_Routine
        (T, Object_Hash_Dispatch_Matches_Git'Access,
         "Object_Hash_Hex/Raw dispatch matches git sha1/sha256 object ids");
      Register_Routine (T, Empty_String_SHA1'Access, "SHA-1 empty string");
      Register_Routine (T, ABC_SHA1'Access, "SHA-1 abc");
      Register_Routine (T, Git_Blob_SHA1'Access, "Git blob object id input");
      Register_Routine (T, Incremental_SHA1_Matches_One_Shot'Access, "incremental SHA-1 matches one-shot");
      Register_Routine (T, Incremental_SHA1_Crosses_Block_Boundary'Access, "incremental SHA-1 crosses block boundary");
      Register_Routine (T, Empty_String_SHA256'Access, "SHA-256 empty string");
      Register_Routine (T, ABC_SHA256'Access, "SHA-256 abc");
      Register_Routine (T, Fox_SHA256'Access, "SHA-256 pangram");
      Register_Routine
        (T, Incremental_SHA256_Crosses_Block_Boundary'Access,
         "incremental SHA-256 crosses block boundary");
      Register_Routine (T, SHA256_Raw_And_Lengths'Access, "SHA-256 raw digest and id widths");
      Register_Routine
        (T, Large_Input_Hashing'Access,
         "hashing a multi-MB input does not overflow (chunked streaming)");
   end Register_Tests;

   overriding function Name
     (T : Test_Case)
      return AUnit.Message_String
   is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Version.Hash");
   end Name;

end Version.Hash.Tests;
