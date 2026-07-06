with Interfaces;

package Version.Hash is

   type Sha1_Context is private;

   procedure Initialize (Context : out Sha1_Context);

   procedure Update
     (Context : in out Sha1_Context;
      Input   : String);

   function Final_Hex
     (Context : Sha1_Context)
      return String;

   function Final_Raw
     (Context : Sha1_Context)
      return String;

   function Sha1_Hex
     (Input : String)
      return String;

   function Sha1_Raw
     (Input : String)
      return String;

   type Sha256_Context is private;

   procedure Initialize (Context : out Sha256_Context);

   procedure Update
     (Context : in out Sha256_Context;
      Input   : String);

   function Final_Hex
     (Context : Sha256_Context)
      return String;

   function Final_Raw
     (Context : Sha256_Context)
      return String;

   function Sha256_Hex
     (Input : String)
      return String;

   function Sha256_Raw
     (Input : String)
      return String;

   --  Object-format hash algorithms and their id widths (used by later
   --  SHA-256 object-format phases; see docs/SHA256_SCOPE.md).
   type Hash_Algorithm is (Sha1, Sha256);

   function Hex_Length (Algorithm : Hash_Algorithm) return Positive;
   --  40 for Sha1, 64 for Sha256.

   function Raw_Length (Algorithm : Hash_Algorithm) return Positive;
   --  20 for Sha1, 32 for Sha256.

   function Object_Hash_Hex
     (Algorithm : Hash_Algorithm;
      Input     : String)
      return String;
   --  Hex digest of Input under the given algorithm (Sha1_Hex / Sha256_Hex).

   function Object_Hash_Raw
     (Algorithm : Hash_Algorithm;
      Input     : String)
      return String;
   --  Raw digest of Input under the given algorithm (Sha1_Raw / Sha256_Raw).

   --  Algorithm-agnostic streaming hash: pick the width at declaration
   --  (Ctx : Streaming_Context (Repo_Algorithm)), then Initialize / Update* /
   --  Final_Raw. Lets callers hash a large stream (e.g. a pack file) under
   --  either algorithm without buffering the whole input.
   type Streaming_Context (Algorithm : Hash_Algorithm) is private;

   procedure Initialize (Context : out Streaming_Context);

   procedure Update (Context : in out Streaming_Context; Input : String);

   function Final_Raw (Context : Streaming_Context) return String;

private

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;
   subtype U8  is Interfaces.Unsigned_8;

   type Sha1_Buffer is array (Positive range 1 .. 64) of U8;

   type Sha1_Context is record
      H0 : U32 := 16#67452301#;
      H1 : U32 := 16#EFCDAB89#;
      H2 : U32 := 16#98BADCFE#;
      H3 : U32 := 16#10325476#;
      H4 : U32 := 16#C3D2E1F0#;
      Buffer        : Sha1_Buffer := [others => 0];
      Buffer_Length : Natural range 0 .. 64 := 0;
      Total_Length  : U64 := 0;
   end record;

   type Sha256_Buffer is array (Positive range 1 .. 64) of U8;
   type Sha256_State is array (0 .. 7) of U32;

   type Sha256_Context is record
      H : Sha256_State :=
        [16#6A09E667#, 16#BB67AE85#, 16#3C6EF372#, 16#A54FF53A#,
         16#510E527F#, 16#9B05688C#, 16#1F83D9AB#, 16#5BE0CD19#];
      Buffer        : Sha256_Buffer := [others => 0];
      Buffer_Length : Natural range 0 .. 64 := 0;
      Total_Length  : U64 := 0;
   end record;

   type Streaming_Context (Algorithm : Hash_Algorithm) is record
      case Algorithm is
         when Sha1   =>
            C1 : Sha1_Context;
         when Sha256 =>
            C256 : Sha256_Context;
      end case;
   end record;

end Version.Hash;
