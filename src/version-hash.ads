private with CryptoLib.Hashes;

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

   --  All hashing delegates to CryptoLib.Hashes (the shared crypto library);
   --  these contexts simply wrap the corresponding cryptolib streaming state.
   type Sha1_Context is record
      Ctx : CryptoLib.Hashes.SHA1_Context;
   end record;

   type Sha256_Context is record
      Ctx : CryptoLib.Hashes.SHA256_Context;
   end record;

   type Streaming_Context (Algorithm : Hash_Algorithm) is record
      case Algorithm is
         when Sha1   =>
            C1 : CryptoLib.Hashes.SHA1_Context;
         when Sha256 =>
            C256 : CryptoLib.Hashes.SHA256_Context;
      end case;
   end record;

end Version.Hash;
