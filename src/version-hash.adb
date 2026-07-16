with Ada.Streams;

package body Version.Hash is

   use type Ada.Streams.Stream_Element_Offset;

   Hex_Digits : constant String := "0123456789abcdef";

   function To_SEA (Input : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Input'Length));
      Index  : Ada.Streams.Stream_Element_Offset := Result'First;
   begin
      for C of Input loop
         Result (Index) := Ada.Streams.Stream_Element (Character'Pos (C));
         Index := Index + 1;
      end loop;
      return Result;
   end To_SEA;

   function To_Hex (Data : Ada.Streams.Stream_Element_Array) return String is
      Result : String (1 .. 2 * Natural (Data'Length));
      Index  : Positive := Result'First;
   begin
      for B of Data loop
         Result (Index)     := Hex_Digits (Natural (B) / 16 + 1);
         Result (Index + 1) := Hex_Digits (Natural (B) mod 16 + 1);
         Index := Index + 2;
      end loop;
      return Result;
   end To_Hex;

   function To_Raw (Data : Ada.Streams.Stream_Element_Array) return String is
      Result : String (1 .. Natural (Data'Length));
      Index  : Positive := Result'First;
   begin
      for B of Data loop
         Result (Index) := Character'Val (Natural (B));
         Index := Index + 1;
      end loop;
      return Result;
   end To_Raw;

   --  Absorb Input into a streaming context in bounded chunks, so an arbitrarily
   --  large input is hashed with O(chunk) memory (no full-size byte-array copy
   --  and no whole-message allocation inside the hash).
   Chunk_Size : constant := 65_536;

   procedure Feed_SHA1
     (Context : in out CryptoLib.Hashes.SHA1_Context; Input : String)
   is
      Pos : Natural := Input'First;
   begin
      while Pos <= Input'Last loop
         declare
            Stop : constant Natural := Natural'Min (Pos + Chunk_Size - 1, Input'Last);
         begin
            CryptoLib.Hashes.Update (Context, To_SEA (Input (Pos .. Stop)));
            Pos := Stop + 1;
         end;
      end loop;
   end Feed_SHA1;

   procedure Feed_SHA256
     (Context : in out CryptoLib.Hashes.SHA256_Context; Input : String)
   is
      Pos : Natural := Input'First;
   begin
      while Pos <= Input'Last loop
         declare
            Stop : constant Natural := Natural'Min (Pos + Chunk_Size - 1, Input'Last);
         begin
            CryptoLib.Hashes.Update (Context, To_SEA (Input (Pos .. Stop)));
            Pos := Stop + 1;
         end;
      end loop;
   end Feed_SHA256;

   function SHA1_Bytes (Input : String) return Ada.Streams.Stream_Element_Array is
      Context : CryptoLib.Hashes.SHA1_Context;
   begin
      CryptoLib.Hashes.Initialize_SHA1 (Context);
      Feed_SHA1 (Context, Input);
      return Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Context));
   end SHA1_Bytes;

   function SHA256_Bytes (Input : String) return Ada.Streams.Stream_Element_Array
   is
      Context : CryptoLib.Hashes.SHA256_Context;
   begin
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      Feed_SHA256 (Context, Input);
      return Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Context));
   end SHA256_Bytes;

   ---------------------------------  SHA-1  ---------------------------------

   procedure Initialize (Context : out Sha1_Context) is
   begin
      CryptoLib.Hashes.Initialize_SHA1 (Context.Ctx);
   end Initialize;

   procedure Update (Context : in out Sha1_Context; Input : String) is
   begin
      Feed_SHA1 (Context.Ctx, Input);
   end Update;

   function Final_Hex (Context : Sha1_Context) return String is
      Local : CryptoLib.Hashes.SHA1_Context := Context.Ctx;
   begin
      return To_Hex
        (Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Local)));
   end Final_Hex;

   function Final_Raw (Context : Sha1_Context) return String is
      Local : CryptoLib.Hashes.SHA1_Context := Context.Ctx;
   begin
      return To_Raw
        (Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Local)));
   end Final_Raw;

   function Sha1_Hex (Input : String) return String is
     (To_Hex (SHA1_Bytes (Input)));

   function Sha1_Raw (Input : String) return String is
     (To_Raw (SHA1_Bytes (Input)));

   --------------------------------  SHA-256  --------------------------------

   procedure Initialize (Context : out Sha256_Context) is
   begin
      CryptoLib.Hashes.Initialize_SHA256 (Context.Ctx);
   end Initialize;

   procedure Update (Context : in out Sha256_Context; Input : String) is
   begin
      Feed_SHA256 (Context.Ctx, Input);
   end Update;

   function Final_Hex (Context : Sha256_Context) return String is
      Local : CryptoLib.Hashes.SHA256_Context := Context.Ctx;
   begin
      return To_Hex
        (Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Local)));
   end Final_Hex;

   function Final_Raw (Context : Sha256_Context) return String is
      Local : CryptoLib.Hashes.SHA256_Context := Context.Ctx;
   begin
      return To_Raw
        (Ada.Streams.Stream_Element_Array (CryptoLib.Hashes.Finalize (Local)));
   end Final_Raw;

   function Sha256_Hex (Input : String) return String is
     (To_Hex (SHA256_Bytes (Input)));

   function Sha256_Raw (Input : String) return String is
     (To_Raw (SHA256_Bytes (Input)));

   ----------------------------  algorithm-agnostic  -------------------------

   function Hex_Length (Algorithm : Hash_Algorithm) return Positive is
     (case Algorithm is when Sha1 => 40, when Sha256 => 64);

   function Raw_Length (Algorithm : Hash_Algorithm) return Positive is
     (case Algorithm is when Sha1 => 20, when Sha256 => 32);

   function Object_Hash_Hex
     (Algorithm : Hash_Algorithm; Input : String) return String is
     (case Algorithm is
         when Sha1   => Sha1_Hex (Input),
         when Sha256 => Sha256_Hex (Input));

   function Object_Hash_Raw
     (Algorithm : Hash_Algorithm; Input : String) return String is
     (case Algorithm is
         when Sha1   => Sha1_Raw (Input),
         when Sha256 => Sha256_Raw (Input));

   procedure Initialize (Context : out Streaming_Context) is
   begin
      case Context.Algorithm is
         when Sha1   => CryptoLib.Hashes.Initialize_SHA1 (Context.C1);
         when Sha256 => CryptoLib.Hashes.Initialize_SHA256 (Context.C256);
      end case;
   end Initialize;

   procedure Update (Context : in out Streaming_Context; Input : String) is
   begin
      case Context.Algorithm is
         when Sha1   => Feed_SHA1 (Context.C1, Input);
         when Sha256 => Feed_SHA256 (Context.C256, Input);
      end case;
   end Update;

   function Final_Raw (Context : Streaming_Context) return String is
   begin
      case Context.Algorithm is
         when Sha1 =>
            declare
               Local : CryptoLib.Hashes.SHA1_Context := Context.C1;
            begin
               return To_Raw
                 (Ada.Streams.Stream_Element_Array
                    (CryptoLib.Hashes.Finalize (Local)));
            end;
         when Sha256 =>
            declare
               Local : CryptoLib.Hashes.SHA256_Context := Context.C256;
            begin
               return To_Raw
                 (Ada.Streams.Stream_Element_Array
                    (CryptoLib.Hashes.Finalize (Local)));
            end;
      end case;
   end Final_Raw;

end Version.Hash;
