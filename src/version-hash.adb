package body Version.Hash is

   use Interfaces;

   function RotL (X : U32; N : Natural) return U32 is
   begin
      return Shift_Left (X, N) or Shift_Right (X, 32 - N);
   end RotL;

   function To_U32 (A, B, C, D : U8) return U32 is
   begin
      return U32 (A) * 16#1000000#
           + U32 (B) * 16#10000#
           + U32 (C) * 16#100#
           + U32 (D);
   end To_U32;

   procedure Reset_State (Context : out Sha1_Context) is
   begin
      Context.H0 := 16#67452301#;
      Context.H1 := 16#EFCDAB89#;
      Context.H2 := 16#98BADCFE#;
      Context.H3 := 16#10325476#;
      Context.H4 := 16#C3D2E1F0#;
      Context.Buffer := [others => 0];
      Context.Buffer_Length := 0;
      Context.Total_Length := 0;
   end Reset_State;

   procedure Initialize (Context : out Sha1_Context) renames Reset_State;

   procedure Process_Block
     (Context : in out Sha1_Context;
      Block   : Sha1_Buffer)
   is
      W : array (0 .. 79) of U32 := [others => 0];
      A : U32;
      B : U32;
      C : U32;
      D : U32;
      E : U32;
   begin
      for I in 0 .. 15 loop
         declare
            Base : constant Natural := 1 + I * 4;
         begin
            W (I) :=
              To_U32
                (Block (Base),
                 Block (Base + 1),
                 Block (Base + 2),
                 Block (Base + 3));
         end;
      end loop;

      for I in 16 .. 79 loop
         W (I) :=
           RotL
             (W (I - 3)
              xor W (I - 8)
              xor W (I - 14)
              xor W (I - 16),
              1);
      end loop;

      A := Context.H0;
      B := Context.H1;
      C := Context.H2;
      D := Context.H3;
      E := Context.H4;

      for I in 0 .. 79 loop
         declare
            F : U32;
            K : U32;
         begin
            if I <= 19 then
               F := (B and C) or ((not B) and D);
               K := 16#5A827999#;
            elsif I <= 39 then
               F := B xor C xor D;
               K := 16#6ED9EBA1#;
            elsif I <= 59 then
               F := (B and C) or (B and D) or (C and D);
               K := 16#8F1BBCDC#;
            else
               F := B xor C xor D;
               K := 16#CA62C1D6#;
            end if;

            declare
               Temp : constant U32 := RotL (A, 5) + F + E + K + W (I);
            begin
               E := D;
               D := C;
               C := RotL (B, 30);
               B := A;
               A := Temp;
            end;
         end;
      end loop;

      Context.H0 := Context.H0 + A;
      Context.H1 := Context.H1 + B;
      Context.H2 := Context.H2 + C;
      Context.H3 := Context.H3 + D;
      Context.H4 := Context.H4 + E;
   end Process_Block;

   procedure Update
     (Context : in out Sha1_Context;
      Input   : String)
   is
   begin
      for Ch of Input loop
         Context.Buffer_Length := Context.Buffer_Length + 1;
         Context.Buffer (Context.Buffer_Length) := U8 (Character'Pos (Ch));
         Context.Total_Length := Context.Total_Length + 1;

         if Context.Buffer_Length = 64 then
            --  Block aliases Context.Buffer, but Process_Block reads Block
            --  fully before updating only Context.H0..H4 (never Buffer), so
            --  the overlap is harmless.
            pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
            Process_Block (Context, Context.Buffer);
            pragma Warnings (On, "writable actual for ""Context"" overlaps*");
            Context.Buffer := [others => 0];
            Context.Buffer_Length := 0;
         end if;
      end loop;
   end Update;

   procedure Emit_U32_Raw
     (Value  : U32;
      Target : in out String;
      Pos    : in out Natural)
   is
   begin
      for I in reverse 0 .. 3 loop
         Target (Pos) :=
           Character'Val (Natural (Shift_Right (Value, I * 8) and 16#FF#));
         Pos := Pos + 1;
      end loop;
   end Emit_U32_Raw;

   function Final_Raw
     (Context : Sha1_Context)
      return String
   is
      Work    : Sha1_Context := Context;
      Bit_Len : constant U64 := Context.Total_Length * 8;
      Result  : String (1 .. 20);
      Pos     : Natural := Result'First;
   begin
      Work.Buffer_Length := Work.Buffer_Length + 1;
      Work.Buffer (Work.Buffer_Length) := 16#80#;

      if Work.Buffer_Length > 56 then
         for I in Work.Buffer_Length + 1 .. 64 loop
            Work.Buffer (I) := 0;
         end loop;

         --  Block aliases Work.Buffer, but Process_Block reads Block fully
         --  before updating only Work.H0..H4 (never Buffer), so the overlap
         --  is harmless.
         pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
         Process_Block (Work, Work.Buffer);
         pragma Warnings (On, "writable actual for ""Context"" overlaps*");
         Work.Buffer := [others => 0];
         Work.Buffer_Length := 0;
      end if;

      for I in Work.Buffer_Length + 1 .. 56 loop
         Work.Buffer (I) := 0;
      end loop;

      declare
         L : U64 := Bit_Len;
      begin
         for I in reverse 57 .. 64 loop
            Work.Buffer (I) := U8 (L mod 256);
            L := L / 256;
         end loop;
      end;

      --  Same harmless overlap as above: Block aliases Work.Buffer.
      pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
      Process_Block (Work, Work.Buffer);
      pragma Warnings (On, "writable actual for ""Context"" overlaps*");

      Emit_U32_Raw (Work.H0, Result, Pos);
      Emit_U32_Raw (Work.H1, Result, Pos);
      Emit_U32_Raw (Work.H2, Result, Pos);
      Emit_U32_Raw (Work.H3, Result, Pos);
      Emit_U32_Raw (Work.H4, Result, Pos);

      return Result;
   end Final_Raw;

   function Final_Hex
     (Context : Sha1_Context)
      return String
   is
      Raw    : constant String := Final_Raw (Context);
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. 40);
      Pos    : Natural := Result'First;
   begin
      for Ch of Raw loop
         declare
            B : constant Natural := Character'Pos (Ch);
         begin
            Result (Pos) := Hex (B / 16 + 1);
            Result (Pos + 1) := Hex (B mod 16 + 1);
            Pos := Pos + 2;
         end;
      end loop;

      return Result;
   end Final_Hex;

   function Sha1_Hex
     (Input : String)
      return String
   is
      Context : Sha1_Context;
   begin
      Initialize (Context);
      Update (Context, Input);
      return Final_Hex (Context);
   end Sha1_Hex;

   function Sha1_Raw
     (Input : String)
      return String
   is
      Context : Sha1_Context;
   begin
      Initialize (Context);
      Update (Context, Input);
      return Final_Raw (Context);
   end Sha1_Raw;

   ----------------------------------------------------------------------------
   --  SHA-256 (FIPS 180-4)
   ----------------------------------------------------------------------------

   function RotR (X : U32; N : Natural) return U32 is
     (Shift_Right (X, N) or Shift_Left (X, 32 - N));

   function Shr (X : U32; N : Natural) return U32 is (Shift_Right (X, N));

   type Sha256_K_Array is array (0 .. 63) of U32;

   Sha256_K : constant Sha256_K_Array :=
     [16#428a2f98#, 16#71374491#, 16#b5c0fbcf#, 16#e9b5dba5#,
      16#3956c25b#, 16#59f111f1#, 16#923f82a4#, 16#ab1c5ed5#,
      16#d807aa98#, 16#12835b01#, 16#243185be#, 16#550c7dc3#,
      16#72be5d74#, 16#80deb1fe#, 16#9bdc06a7#, 16#c19bf174#,
      16#e49b69c1#, 16#efbe4786#, 16#0fc19dc6#, 16#240ca1cc#,
      16#2de92c6f#, 16#4a7484aa#, 16#5cb0a9dc#, 16#76f988da#,
      16#983e5152#, 16#a831c66d#, 16#b00327c8#, 16#bf597fc7#,
      16#c6e00bf3#, 16#d5a79147#, 16#06ca6351#, 16#14292967#,
      16#27b70a85#, 16#2e1b2138#, 16#4d2c6dfc#, 16#53380d13#,
      16#650a7354#, 16#766a0abb#, 16#81c2c92e#, 16#92722c85#,
      16#a2bfe8a1#, 16#a81a664b#, 16#c24b8b70#, 16#c76c51a3#,
      16#d192e819#, 16#d6990624#, 16#f40e3585#, 16#106aa070#,
      16#19a4c116#, 16#1e376c08#, 16#2748774c#, 16#34b0bcb5#,
      16#391c0cb3#, 16#4ed8aa4a#, 16#5b9cca4f#, 16#682e6ff3#,
      16#748f82ee#, 16#78a5636f#, 16#84c87814#, 16#8cc70208#,
      16#90befffa#, 16#a4506ceb#, 16#bef9a3f7#, 16#c67178f2#];

   function Ch (X, Y, Z : U32) return U32 is ((X and Y) xor ((not X) and Z));

   function Maj (X, Y, Z : U32) return U32 is
     ((X and Y) xor (X and Z) xor (Y and Z));

   function Big_Sigma0 (X : U32) return U32 is
     (RotR (X, 2) xor RotR (X, 13) xor RotR (X, 22));

   function Big_Sigma1 (X : U32) return U32 is
     (RotR (X, 6) xor RotR (X, 11) xor RotR (X, 25));

   function Small_Sigma0 (X : U32) return U32 is
     (RotR (X, 7) xor RotR (X, 18) xor Shr (X, 3));

   function Small_Sigma1 (X : U32) return U32 is
     (RotR (X, 17) xor RotR (X, 19) xor Shr (X, 10));

   procedure Initialize (Context : out Sha256_Context) is
   begin
      Context.H :=
        [16#6A09E667#, 16#BB67AE85#, 16#3C6EF372#, 16#A54FF53A#,
         16#510E527F#, 16#9B05688C#, 16#1F83D9AB#, 16#5BE0CD19#];
      Context.Buffer := [others => 0];
      Context.Buffer_Length := 0;
      Context.Total_Length := 0;
   end Initialize;

   procedure Process_Block
     (Context : in out Sha256_Context;
      Block   : Sha256_Buffer)
   is
      W : array (0 .. 63) of U32 := [others => 0];
      A, B, C, D, E, F, G, H : U32;
   begin
      for I in 0 .. 15 loop
         declare
            Base : constant Natural := 1 + I * 4;
         begin
            W (I) :=
              To_U32
                (Block (Base), Block (Base + 1),
                 Block (Base + 2), Block (Base + 3));
         end;
      end loop;

      for I in 16 .. 63 loop
         W (I) :=
           Small_Sigma1 (W (I - 2)) + W (I - 7)
           + Small_Sigma0 (W (I - 15)) + W (I - 16);
      end loop;

      A := Context.H (0);
      B := Context.H (1);
      C := Context.H (2);
      D := Context.H (3);
      E := Context.H (4);
      F := Context.H (5);
      G := Context.H (6);
      H := Context.H (7);

      for I in 0 .. 63 loop
         declare
            T1 : constant U32 :=
              H + Big_Sigma1 (E) + Ch (E, F, G) + Sha256_K (I) + W (I);
            T2 : constant U32 := Big_Sigma0 (A) + Maj (A, B, C);
         begin
            H := G;
            G := F;
            F := E;
            E := D + T1;
            D := C;
            C := B;
            B := A;
            A := T1 + T2;
         end;
      end loop;

      Context.H (0) := Context.H (0) + A;
      Context.H (1) := Context.H (1) + B;
      Context.H (2) := Context.H (2) + C;
      Context.H (3) := Context.H (3) + D;
      Context.H (4) := Context.H (4) + E;
      Context.H (5) := Context.H (5) + F;
      Context.H (6) := Context.H (6) + G;
      Context.H (7) := Context.H (7) + H;
   end Process_Block;

   procedure Update
     (Context : in out Sha256_Context;
      Input   : String)
   is
   begin
      for Ch of Input loop
         Context.Buffer_Length := Context.Buffer_Length + 1;
         Context.Buffer (Context.Buffer_Length) := U8 (Character'Pos (Ch));
         Context.Total_Length := Context.Total_Length + 1;

         if Context.Buffer_Length = 64 then
            pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
            Process_Block (Context, Context.Buffer);
            pragma Warnings (On, "writable actual for ""Context"" overlaps*");
            Context.Buffer := [others => 0];
            Context.Buffer_Length := 0;
         end if;
      end loop;
   end Update;

   function Final_Raw
     (Context : Sha256_Context)
      return String
   is
      Work    : Sha256_Context := Context;
      Bit_Len : constant U64 := Context.Total_Length * 8;
      Result  : String (1 .. 32);
      Pos     : Natural := Result'First;
   begin
      Work.Buffer_Length := Work.Buffer_Length + 1;
      Work.Buffer (Work.Buffer_Length) := 16#80#;

      if Work.Buffer_Length > 56 then
         for I in Work.Buffer_Length + 1 .. 64 loop
            Work.Buffer (I) := 0;
         end loop;

         pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
         Process_Block (Work, Work.Buffer);
         pragma Warnings (On, "writable actual for ""Context"" overlaps*");
         Work.Buffer := [others => 0];
         Work.Buffer_Length := 0;
      end if;

      for I in Work.Buffer_Length + 1 .. 56 loop
         Work.Buffer (I) := 0;
      end loop;

      declare
         L : U64 := Bit_Len;
      begin
         for I in reverse 57 .. 64 loop
            Work.Buffer (I) := U8 (L mod 256);
            L := L / 256;
         end loop;
      end;

      pragma Warnings (Off, "writable actual for ""Context"" overlaps*");
      Process_Block (Work, Work.Buffer);
      pragma Warnings (On, "writable actual for ""Context"" overlaps*");

      for Word of Work.H loop
         Emit_U32_Raw (Word, Result, Pos);
      end loop;

      return Result;
   end Final_Raw;

   function Final_Hex
     (Context : Sha256_Context)
      return String
   is
      Raw    : constant String := Final_Raw (Context);
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. 64);
      Pos    : Natural := Result'First;
   begin
      for Ch of Raw loop
         declare
            B : constant Natural := Character'Pos (Ch);
         begin
            Result (Pos) := Hex (B / 16 + 1);
            Result (Pos + 1) := Hex (B mod 16 + 1);
            Pos := Pos + 2;
         end;
      end loop;

      return Result;
   end Final_Hex;

   function Sha256_Hex
     (Input : String)
      return String
   is
      Context : Sha256_Context;
   begin
      Initialize (Context);
      Update (Context, Input);
      return Final_Hex (Context);
   end Sha256_Hex;

   function Sha256_Raw
     (Input : String)
      return String
   is
      Context : Sha256_Context;
   begin
      Initialize (Context);
      Update (Context, Input);
      return Final_Raw (Context);
   end Sha256_Raw;

   function Hex_Length (Algorithm : Hash_Algorithm) return Positive is
     (case Algorithm is when Sha1 => 40, when Sha256 => 64);

   function Raw_Length (Algorithm : Hash_Algorithm) return Positive is
     (case Algorithm is when Sha1 => 20, when Sha256 => 32);

   function Object_Hash_Hex
     (Algorithm : Hash_Algorithm;
      Input     : String)
      return String
   is
     (case Algorithm is
         when Sha1   => Sha1_Hex (Input),
         when Sha256 => Sha256_Hex (Input));

   function Object_Hash_Raw
     (Algorithm : Hash_Algorithm;
      Input     : String)
      return String
   is
     (case Algorithm is
         when Sha1   => Sha1_Raw (Input),
         when Sha256 => Sha256_Raw (Input));

   procedure Initialize (Context : out Streaming_Context) is
   begin
      case Context.Algorithm is
         when Sha1   => Initialize (Context.C1);
         when Sha256 => Initialize (Context.C256);
      end case;
   end Initialize;

   procedure Update (Context : in out Streaming_Context; Input : String) is
   begin
      case Context.Algorithm is
         when Sha1   => Update (Context.C1, Input);
         when Sha256 => Update (Context.C256, Input);
      end case;
   end Update;

   function Final_Raw (Context : Streaming_Context) return String is
     (case Context.Algorithm is
         when Sha1   => Final_Raw (Context.C1),
         when Sha256 => Final_Raw (Context.C256));

end Version.Hash;
