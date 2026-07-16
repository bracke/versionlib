with Ada.Characters.Latin_1;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Version.Trailers is

   LF : Character renames Ada.Characters.Latin_1.LF;
   HT : Character renames Ada.Characters.Latin_1.HT;

   package Line_Vectors is new
     Ada.Containers.Indefinite_Vectors (Positive, String);

   function Split_Lines (S : String) return Line_Vectors.Vector is
      Result : Line_Vectors.Vector;
      Start  : Positive := (if S'Length > 0 then S'First else 1);
   begin
      if S'Length = 0 then
         return Result;
      end if;
      for I in S'Range loop
         if S (I) = LF then
            Result.Append (S (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= S'Last then
         Result.Append (S (Start .. S'Last));
      end if;
      return Result;
   end Split_Lines;

   function Is_Blank (Line : String) return Boolean is
   begin
      for C of Line loop
         if C /= ' ' and then C /= HT then
            return False;
         end if;
      end loop;
      return True;
   end Is_Blank;

   function Is_Comment (Line : String) return Boolean is
     (Line'Length > 0 and then Line (Line'First) = '#');

   function Is_Continuation (Line : String) return Boolean is
     (Line'Length > 0
      and then (Line (Line'First) = ' ' or else Line (Line'First) = HT));

   --  Position of the ':' that separates a valid trailer token from its value,
   --  or 0 when the line is not a trailer. The token must be non-empty and
   --  contain no embedded whitespace (so prose such as "This fixes: bug" is
   --  rejected).
   function Trailer_Sep_Pos (Line : String) return Natural is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
   begin
      if Colon = 0 then
         return 0;
      end if;
      declare
         Tok_Last : Integer := Colon - 1;
      begin
         while Tok_Last >= Line'First
           and then (Line (Tok_Last) = ' ' or else Line (Tok_Last) = HT)
         loop
            Tok_Last := Tok_Last - 1;
         end loop;
         if Tok_Last < Line'First then
            return 0;
         end if;
         for J in Line'First .. Tok_Last loop
            if Line (J) = ' ' or else Line (J) = HT then
               return 0;
            end if;
         end loop;
         return Colon;
      end;
   end Trailer_Sep_Pos;

   function Is_Trailer_Line (Line : String) return Boolean is
     (not Is_Blank (Line) and then not Is_Comment (Line)
      and then not Is_Continuation (Line)
      and then Trailer_Sep_Pos (Line) > 0);

   --  Normalise a raw `--trailer` argument to `token: value`. Either ':' or
   --  '=' is accepted as the input separator.
   function Normalize_Trailer (Arg : String) return String is
      Sep : Natural := 0;
   begin
      for I in Arg'Range loop
         if Arg (I) = ':' or else Arg (I) = '=' then
            Sep := I;
            exit;
         end if;
      end loop;
      if Sep = 0 then
         return Arg;
      end if;
      declare
         Token : constant String :=
           Ada.Strings.Fixed.Trim
             (Arg (Arg'First .. Sep - 1), Ada.Strings.Both);
         Value : constant String :=
           Ada.Strings.Fixed.Trim (Arg (Sep + 1 .. Arg'Last), Ada.Strings.Both);
      begin
         --  git normalises to "token: value" even when the value is empty,
         --  which leaves a trailing space ("Fixes: ").
         return Token & ": " & Value;
      end;
   end Normalize_Trailer;

   function Interpret
     (Input         : String;
      Trailers      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Where         : Placement := Placement_After;
      Only_Trailers : Boolean   := False;
      Only_Input    : Boolean   := False;
      Unfold        : Boolean   := False)
      return String
   is
      Lines : constant Line_Vectors.Vector := Split_Lines (Input);
      Added : Line_Vectors.Vector;
      Out_B : Unbounded_String;

      procedure Emit (Line : String) is
      begin
         Append (Out_B, Line);
         Append (Out_B, LF);
      end Emit;

      --  Last content line (trailing blank lines ignored); 0 if all-blank.
      Last : Natural := Lines.Last_Index;
   begin
      if not Only_Input then
         for Tr of Trailers loop
            Added.Append (Normalize_Trailer (Tr));
         end loop;
      end if;

      while Last >= 1 and then Is_Blank (Lines (Last)) loop
         Last := Last - 1;
      end loop;

      --  Empty or all-blank input: nothing to anchor to. In whole-message mode
      --  git still emits the blank separator line before the added trailers.
      if Last < 1 then
         if Only_Trailers then
            for L of Added loop
               Emit (L);
            end loop;
         elsif not Added.Is_Empty then
            Append (Out_B, LF);
            for L of Added loop
               Emit (L);
            end loop;
         end if;
         return To_String (Out_B);
      end if;

      --  Locate the last paragraph (the candidate trailer block).
      declare
         BS : Positive := Last;

         function Block_Has_Trailer return Boolean is
         begin
            for I in BS .. Last loop
               if Is_Trailer_Line (Lines (I)) then
                  return True;
               end if;
            end loop;
            return False;
         end Block_Has_Trailer;

         Is_Block : Boolean;
      begin
         while BS > 1 and then not Is_Blank (Lines (BS - 1)) loop
            BS := BS - 1;
         end loop;

         --  A trailer block cannot be the first paragraph.
         Is_Block := BS > 1 and then Block_Has_Trailer;

         if Only_Trailers then
            declare
               Collected : Line_Vectors.Vector;
            begin
               if Is_Block then
                  for I in BS .. Last loop
                     if Is_Trailer_Line (Lines (I))
                       or else Is_Continuation (Lines (I))
                     then
                        Collected.Append (Lines (I));
                     end if;
                  end loop;
               end if;
               for L of Added loop
                  Collected.Append (L);
               end loop;

               for I in Collected.First_Index .. Collected.Last_Index loop
                  if Unfold and then Is_Continuation (Collected (I))
                    and then Length (Out_B) > 0
                  then
                     --  Fold the continuation onto the previous line: drop the
                     --  trailing LF, add a single space and the trimmed text.
                     Head (Out_B, Length (Out_B) - 1);
                     Append
                       (Out_B,
                        " "
                        & Ada.Strings.Fixed.Trim
                            (Collected (I), Ada.Strings.Both));
                     Append (Out_B, LF);
                  else
                     Emit (Collected (I));
                  end if;
               end loop;
            end;
            return To_String (Out_B);
         end if;

         --  Normal (whole-message) output.
         if Is_Block then
            declare
               Insert_At : Positive;
            begin
               if Where = Placement_After then
                  Insert_At := Last;
                  while Insert_At > BS
                    and then Is_Comment (Lines (Insert_At))
                  loop
                     Insert_At := Insert_At - 1;
                  end loop;
                  --  Emit through Insert_At, the added trailers, then the rest.
                  for I in 1 .. Insert_At loop
                     Emit (Lines (I));
                  end loop;
                  for L of Added loop
                     Emit (L);
                  end loop;
                  for I in Insert_At + 1 .. Last loop
                     Emit (Lines (I));
                  end loop;
               else
                  Insert_At := BS;
                  while Insert_At < Last
                    and then not Is_Trailer_Line (Lines (Insert_At))
                  loop
                     Insert_At := Insert_At + 1;
                  end loop;
                  for I in 1 .. Insert_At - 1 loop
                     Emit (Lines (I));
                  end loop;
                  for L of Added loop
                     Emit (L);
                  end loop;
                  for I in Insert_At .. Last loop
                     Emit (Lines (I));
                  end loop;
               end if;
            end;
         else
            for I in 1 .. Last loop
               Emit (Lines (I));
            end loop;
            if not Added.Is_Empty then
               Append (Out_B, LF);
               for L of Added loop
                  Emit (L);
               end loop;
            end if;
         end if;
      end;

      return To_String (Out_B);
   end Interpret;

end Version.Trailers;
