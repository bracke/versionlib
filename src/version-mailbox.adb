with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Version.Mailbox is

   function Lower (Text : String) return String is
      Result : String := Text;
   begin
      for I in Result'Range loop
         Result (I) := Ada.Characters.Handling.To_Lower (Result (I));
      end loop;
      return Result;
   end Lower;

   --  RFC 2047 encoded-words: "=?charset?Q?text?=" or "=?charset?B?text?=".
   --  git decodes these in Author and Subject before printing them.
   function Decode_RFC2047 (Text : String) return String is
      Result : Unbounded_String;
      I      : Natural := Text'First;

      function Hex_Value (C : Character) return Natural is
        (case C is
            when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
            when 'a' .. 'f' =>
              Character'Pos (C) - Character'Pos ('a') + 10,
            when 'A' .. 'F' =>
              Character'Pos (C) - Character'Pos ('A') + 10,
            when others => 0);

      function Base64_Value (C : Character) return Natural is
        (case C is
            when 'A' .. 'Z' => Character'Pos (C) - Character'Pos ('A'),
            when 'a' .. 'z' => Character'Pos (C) - Character'Pos ('a') + 26,
            when '0' .. '9' => Character'Pos (C) - Character'Pos ('0') + 52,
            when '+' => 62,
            when '/' => 63,
            when others => 0);

      procedure Decode_Q (Body_Text : String) is
         K : Natural := Body_Text'First;
      begin
         while K <= Body_Text'Last loop
            if Body_Text (K) = '_' then
               Append (Result, ' ');
               K := K + 1;
            elsif Body_Text (K) = '='
              and then K + 2 <= Body_Text'Last
            then
               Append
                 (Result,
                  Character'Val (Hex_Value (Body_Text (K + 1)) * 16
                                 + Hex_Value (Body_Text (K + 2))));
               K := K + 3;
            else
               Append (Result, Body_Text (K));
               K := K + 1;
            end if;
         end loop;
      end Decode_Q;

      procedure Decode_B (Body_Text : String) is
         --  Only the bits not yet emitted are carried, so the accumulator
         --  stays small; letting it grow overflowed Natural after a handful
         --  of characters.
         Acc  : Natural := 0;
         Bits : Natural := 0;
      begin
         for C of Body_Text loop
            exit when C = '=';
            Acc := Acc * 64 + Base64_Value (C);
            Bits := Bits + 6;
            if Bits >= 8 then
               Bits := Bits - 8;
               Append (Result, Character'Val ((Acc / (2 ** Bits)) mod 256));
               Acc := Acc mod (2 ** Bits);
            end if;
         end loop;
      end Decode_B;
   begin
      while I <= Text'Last loop
         if I + 1 <= Text'Last
           and then Text (I) = '=' and then Text (I + 1) = '?'
         then
            declare
               Charset_End : Natural := 0;
               Enc_End     : Natural := 0;
               Word_End    : Natural := 0;
            begin
               --  =?charset?E?body?=
               for K in I + 2 .. Text'Last loop
                  if Text (K) = '?' then
                     if Charset_End = 0 then
                        Charset_End := K;
                     elsif Enc_End = 0 then
                        Enc_End := K;
                     else
                        if K < Text'Last and then Text (K + 1) = '=' then
                           Word_End := K;
                        end if;
                        exit;
                     end if;
                  end if;
               end loop;

               if Word_End > 0 and then Enc_End = Charset_End + 2 then
                  declare
                     Enc : constant Character := Text (Charset_End + 1);
                     Payload : constant String :=
                       Text (Enc_End + 1 .. Word_End - 1);
                     Charset : constant String :=
                       Lower (Text (I + 2 .. Charset_End - 1));
                     Mark : constant Natural := Length (Result);
                  begin
                     if Enc = 'Q' or else Enc = 'q' then
                        Decode_Q (Payload);
                     elsif Enc = 'B' or else Enc = 'b' then
                        Decode_B (Payload);
                     else
                        Append (Result, Text (I .. Word_End + 1));
                     end if;

                     --  git hands back UTF-8; a Latin-1 word has to be
                     --  transcoded, or its high bytes are invalid UTF-8.
                     if Charset = "iso-8859-1" or else Charset = "latin1"
                       or else Charset = "iso8859-1"
                     then
                        declare
                           Raw : constant String :=
                             Slice (Result, Mark + 1, Length (Result));
                           Wide : Unbounded_String;
                        begin
                           for C of Raw loop
                              if Character'Pos (C) < 16#80# then
                                 Append (Wide, C);
                              else
                                 Append
                                   (Wide,
                                    Character'Val
                                      (16#C0#
                                       + Character'Pos (C) / 16#40#));
                                 Append
                                   (Wide,
                                    Character'Val
                                      (16#80#
                                       + Character'Pos (C) mod 16#40#));
                              end if;
                           end loop;
                           Head (Result, Mark);
                           Append (Result, Wide);
                        end;
                     end if;

                     I := Word_End + 2;
                  end;
               else
                  Append (Result, Text (I));
                  I := I + 1;
               end if;
            end;
         else
            Append (Result, Text (I));
            I := I + 1;
         end if;
      end loop;

      return To_String (Result);
   end Decode_RFC2047;


   LF : constant Character := Character'Val (10);

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   ------------------
   -- Is_From_Line --
   ------------------

   function Is_From_Line (Line : String) return Boolean is
      Colon : Integer;
   begin
      if Line'Length < 20
        or else Line (Line'First .. Line'First + 4) /= "From "
      then
         return False;
      end if;

      --  Walk back from the end to the last ':' -- the time in the date.
      Colon := Line'Last - 1;

      while Colon >= Line'First + 5 and then Line (Colon) /= ':' loop
         Colon := Colon - 1;
      end loop;

      if Colon < Line'First + 5 then
         return False;
      end if;

      --  "hh:mm" around it, with the seconds' pair before the minute colon.
      if Colon - 4 < Line'First or else Colon + 2 > Line'Last then
         return False;
      end if;

      return Is_Digit (Line (Colon - 4))
        and then Is_Digit (Line (Colon - 2))
        and then Is_Digit (Line (Colon - 1))
        and then Is_Digit (Line (Colon + 1))
        and then Is_Digit (Line (Colon + 2));
   end Is_From_Line;

   function Lines_Of (Text : String) return Text_Vectors.Vector is
      Result : Text_Vectors.Vector;
      Start  : Natural := Text'First;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            Result.Append (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;

      if Start <= Text'Last then
         Result.Append (Text (Start .. Text'Last));
      end if;

      return Result;
   end Lines_Of;

   -----------
   -- Split --
   -----------

   function Split (Mailbox : String) return Text_Vectors.Vector is
      Result  : Text_Vectors.Vector;
      Current : Unbounded_String;
   begin
      for Line of Lines_Of (Mailbox) loop
         if Is_From_Line (Line) and then Length (Current) > 0 then
            Result.Append (To_String (Current));
            Current := Null_Unbounded_String;
         end if;

         Append (Current, Line & LF);
      end loop;

      if Length (Current) > 0 then
         Result.Append (To_String (Current));
      end if;

      return Result;
   end Split;

   -----------
   -- Parse --
   -----------

   function Parse (Mail : String) return Message is
      Lines  : constant Text_Vectors.Vector := Lines_Of (Mail);
      Result : Message;

      I : Positive := Lines.First_Index;
   begin
      if not Lines.Is_Empty and then Is_From_Line (Lines.First_Element) then
         I := I + 1;
      end if;

      --  Headers, up to the blank line.
      while I <= Lines.Last_Index and then Lines.Element (I) /= "" loop
         declare
            Line : constant String := Lines.Element (I);
         begin
            if Line'Length >= 6
              and then Line (Line'First .. Line'First + 5) = "From: "
            then
               Result.Author :=
                 To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 6
              and then Line (Line'First .. Line'First + 5) = "Date: "
            then
               Result.Date :=
                 To_Unbounded_String (Line (Line'First + 6 .. Line'Last));
            elsif Line'Length >= 9
              and then Line (Line'First .. Line'First + 8) = "Subject: "
            then
               Result.Subject :=
                 To_Unbounded_String (Line (Line'First + 9 .. Line'Last));
            end if;
         end;

         I := I + 1;
      end loop;

      I := I + 1;   --  past the blank line

      --  The commit message, then the patch from the "---" line on.
      declare
         Body_Text : Unbounded_String;
         Patch     : Unbounded_String;
      begin
         while I <= Lines.Last_Index and then Lines.Element (I) /= "---" loop
            Append (Body_Text, Lines.Element (I) & LF);
            I := I + 1;
         end loop;

         while I <= Lines.Last_Index loop
            Append (Patch, Lines.Element (I) & LF);
            I := I + 1;
         end loop;

         --  Verbatim: `mailinfo` writes exactly these bytes to its message
         --  file, blank lines and all.  A caller that wants a commit message
         --  (like `am`) trims them itself.
         Result.Body_Text := Body_Text;
         Result.Patch := Patch;
      end;

      --  "[PATCH v2 3/7] [RFC] real subject" -> "real subject": git strips
      --  every leading bracket group, not just the first.
      declare
         Done : Boolean := False;
      begin
         while not Done loop
            declare
               Subject : constant String := To_String (Result.Subject);
               Cut     : Natural := 0;
            begin
               Done := True;

               --  git also drops a leading "Re:" (any case), repeatedly.
               if Subject'Length >= 3
                 and then Lower (Subject (Subject'First
                                          .. Subject'First + 2)) = "re:"
               then
                  declare
                     Rest  : constant String :=
                       Subject (Subject'First + 3 .. Subject'Last);
                     First : Natural := Rest'First;
                  begin
                     while First <= Rest'Last and then Rest (First) = ' ' loop
                        First := First + 1;
                     end loop;
                     Result.Subject :=
                       To_Unbounded_String (Rest (First .. Rest'Last));
                     Done := False;
                  end;
               elsif Subject'Length > 0
                 and then Subject (Subject'First) = '['
               then
                  for K in Subject'Range loop
                     if Subject (K) = ']' then
                        Cut := K;
                        exit;
                     end if;
                  end loop;

                  if Cut > 0 then
                     declare
                        Rest : constant String :=
                          (if Cut < Subject'Last
                           then Subject (Cut + 1 .. Subject'Last) else "");
                        First : Natural := Rest'First;
                     begin
                        while First <= Rest'Last
                          and then Rest (First) = ' '
                        loop
                           First := First + 1;
                        end loop;
                        Result.Subject :=
                          To_Unbounded_String (Rest (First .. Rest'Last));
                        Done := False;
                     end;
                  end if;
               end if;
            end;
         end loop;
      end;

      --  Decode RFC 2047 encoded-words in the headers git prints.
      Result.Subject :=
        To_Unbounded_String (Decode_RFC2047 (To_String (Result.Subject)));
      Result.Author :=
        To_Unbounded_String (Decode_RFC2047 (To_String (Result.Author)));

      --  "Name <mail>" -> the two halves.
      declare
         Author : constant String := To_String (Result.Author);
         LT     : constant Natural := Ada.Strings.Fixed.Index (Author, "<");
         GT     : constant Natural := Ada.Strings.Fixed.Index (Author, ">");
      begin
         if LT /= 0 and then GT > LT then
            Result.Author_Name :=
              To_Unbounded_String
                (Ada.Strings.Fixed.Trim
                   (Author (Author'First .. LT - 1), Ada.Strings.Both));
            Result.Author_Email :=
              To_Unbounded_String (Author (LT + 1 .. GT - 1));
         else
            Result.Author_Name := Result.Author;
         end if;
      end;

      return Result;
   end Parse;

end Version.Mailbox;
