with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Ada.Containers.Vectors;

with Version.Config;
with Version.Files;
with Version.Mailmap;
with Version.Object_Cache;
with Version.Ref_Format;
with Version.Refs;
with Version.Revisions;
with Version.Verify;

package body Version.Pretty_Format is

   Default_Abbrev : constant := 7;

   LF : constant Character := Character'Val (10);

   --------------------------------------------------------------------------
   --  Small string helpers
   --------------------------------------------------------------------------

   function Is_Alnum (C : Character) return Boolean is
     (C in '0' .. '9' or else C in 'A' .. 'Z' or else C in 'a' .. 'z');

   function Is_Hex (C : Character) return Boolean is
     (C in '0' .. '9' or else C in 'a' .. 'f' or else C in 'A' .. 'F');

   function Hex_Val (C : Character) return Natural is
     (case C is
        when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
        when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
        when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
        when others => 0);

   --  Value of the header line beginning with Key (e.g. "tree "), without the
   --  key, or "" when absent. Only header lines (before the blank separator)
   --  are considered.
   function Header_Value (Commit : String; Key : String) return String is
      I : Natural := Commit'First;
   begin
      while I <= Commit'Last loop
         --  End of header block: a blank line.
         if Commit (I) = LF then
            exit;
         end if;
         declare
            Line_End : Natural := I;
         begin
            while Line_End <= Commit'Last and then Commit (Line_End) /= LF loop
               Line_End := Line_End + 1;
            end loop;
            if Line_End - I >= Key'Length
              and then Commit (I .. I + Key'Length - 1) = Key
            then
               return Commit (I + Key'Length .. Line_End - 1);
            end if;
            exit when Line_End > Commit'Last;
            I := Line_End + 1;
         end;
      end loop;
      return "";
   end Header_Value;

   --  The raw commit message: everything after the first blank line, with a
   --  single trailing newline (if any) and any trailing blank lines removed.
   function Raw_Message (Commit : String) return String is
      I : Natural := Commit'First;
   begin
      --  Find the header/message separator (an empty line).
      while I <= Commit'Last loop
         if Commit (I) = LF then
            --  Line starting at header start? Detect blank line: LF at start of
            --  a line means separator when previous char was also LF, but the
            --  header block ends at the first LF that begins an empty line.
            null;
         end if;
         --  Walk line by line looking for an empty line.
         declare
            Line_End : Natural := I;
         begin
            while Line_End <= Commit'Last and then Commit (Line_End) /= LF loop
               Line_End := Line_End + 1;
            end loop;
            if Line_End = I then
               --  Empty line at position I: message starts after it.
               declare
                  Start : constant Natural := I + 1;
                  Stop  : Natural := Commit'Last;
               begin
                  if Start > Commit'Last then
                     return "";
                  end if;
                  while Stop >= Start and then Commit (Stop) = LF loop
                     Stop := Stop - 1;
                  end loop;
                  return Commit (Start .. Stop);
               end;
            end if;
            exit when Line_End > Commit'Last;
            I := Line_End + 1;
         end;
      end loop;
      return "";
   end Raw_Message;

   --  Subject: the first paragraph of the message, with internal newlines
   --  folded to single spaces and surrounding whitespace trimmed.
   function Subject (Message : String) return String is
      Result : Unbounded_String;
      I      : Natural := Message'First;
   begin
      --  Skip leading blank lines.
      while I <= Message'Last and then Message (I) = LF loop
         I := I + 1;
      end loop;
      while I <= Message'Last loop
         if Message (I) = LF then
            --  A blank line ends the subject.
            if I < Message'Last and then Message (I + 1) = LF then
               exit;
            end if;
            Append (Result, ' ');
         else
            Append (Result, Message (I));
         end if;
         I := I + 1;
      end loop;
      --  Trim trailing spaces.
      declare
         S : constant String := To_String (Result);
         L : Natural := S'Last;
      begin
         while L >= S'First and then S (L) = ' ' loop
            L := L - 1;
         end loop;
         return S (S'First .. L);
      end;
   end Subject;

   --  Body: the message with the subject paragraph (and its trailing blank
   --  line) removed; leading blank lines stripped.
   function Message_Body (Message : String) return String is
      I : Natural := Message'First;
   begin
      while I <= Message'Last and then Message (I) = LF loop
         I := I + 1;
      end loop;
      --  Advance past the subject paragraph to its terminating blank line.
      while I <= Message'Last loop
         if Message (I) = LF
           and then I < Message'Last and then Message (I + 1) = LF
         then
            I := I + 2;
            --  Skip further blank lines.
            while I <= Message'Last and then Message (I) = LF loop
               I := I + 1;
            end loop;
            return Message (I .. Message'Last);
         end if;
         I := I + 1;
      end loop;
      return "";
   end Message_Body;

   --  git's format_sanitized_subject: alnum kept, runs of other chars become a
   --  single '-', a '.' is kept only when it does not start a run and is not
   --  doubled; leading separators suppressed, trailing '-'/'.' trimmed.
   function Sanitize_Subject (S : String) return String is
      Result : Unbounded_String;
      Space  : Boolean := True;
   begin
      for C of S loop
         exit when C = LF;
         if Is_Alnum (C) then
            Append (Result, C);
            Space := False;
         elsif C = '.' and then not Space
           and then (Length (Result) = 0
                     or else Element (Result, Length (Result)) /= '.')
         then
            Append (Result, '.');
         elsif not Space then
            Append (Result, '-');
            Space := True;
         end if;
      end loop;
      --  Trim trailing '-' and '.'.
      declare
         R : constant String := To_String (Result);
         L : Natural := R'Last;
      begin
         while L >= R'First and then (R (L) = '-' or else R (L) = '.') loop
            L := L - 1;
         end loop;
         return R (R'First .. L);
      end;
   end Sanitize_Subject;

   --------------------------------------------------------------------------
   --  Identity lines: "Name <email> <epoch> <tz>"
   --------------------------------------------------------------------------

   type Identity is record
      Name  : Unbounded_String;
      Email : Unbounded_String;
      Epoch : Long_Long_Integer := 0;
      TZ    : Unbounded_String;   --  e.g. "+0200"
   end record;

   function Parse_Identity (Line : String) return Identity is
      Result   : Identity;
      LT, GT   : Natural := 0;
   begin
      if Line'Length = 0 then
         return Result;
      end if;
      for I in Line'Range loop
         if Line (I) = '<' and then LT = 0 then
            LT := I;
         elsif Line (I) = '>' then
            GT := I;
         end if;
      end loop;
      if LT = 0 or else GT = 0 or else GT < LT then
         Result.Name := To_Unbounded_String (Line);
         return Result;
      end if;
      --  Name: up to the space before '<'.
      declare
         Name_Last : Natural := LT - 1;
      begin
         while Name_Last >= Line'First and then Line (Name_Last) = ' ' loop
            Name_Last := Name_Last - 1;
         end loop;
         Result.Name := To_Unbounded_String (Line (Line'First .. Name_Last));
      end;
      Result.Email := To_Unbounded_String (Line (LT + 1 .. GT - 1));
      --  Trailing "<epoch> <tz>" after "> ".
      declare
         Rest_First : Natural := GT + 1;
      begin
         while Rest_First <= Line'Last and then Line (Rest_First) = ' ' loop
            Rest_First := Rest_First + 1;
         end loop;
         if Rest_First <= Line'Last then
            declare
               Rest : constant String := Line (Rest_First .. Line'Last);
               Sp   : Natural := 0;
            begin
               for I in Rest'Range loop
                  if Rest (I) = ' ' then
                     Sp := I;
                     exit;
                  end if;
               end loop;
               if Sp = 0 then
                  begin
                     Result.Epoch := Long_Long_Integer'Value (Rest);
                  exception
                     when others => null;
                  end;
               else
                  begin
                     Result.Epoch :=
                       Long_Long_Integer'Value (Rest (Rest'First .. Sp - 1));
                  exception
                     when others => null;
                  end;
                  Result.TZ :=
                    To_Unbounded_String (Rest (Sp + 1 .. Rest'Last));
               end if;
            end;
         end if;
      end;
      return Result;
   end Parse_Identity;

   function Email_Local_Part (Email : String) return String is
   begin
      for I in Email'Range loop
         if Email (I) = '@' then
            return Email (Email'First .. I - 1);
         end if;
      end loop;
      return Email;
   end Email_Local_Part;

   --------------------------------------------------------------------------
   --  .mailmap (%aN/%aE/%aL and committer equivalents)
   --------------------------------------------------------------------------

   function Trim (S : String) return String is
      F : Integer := S'First;
      L : Integer := S'Last;
   begin
      while F <= L and then (S (F) = ' ' or else S (F) = Character'Val (9)) loop
         F := F + 1;
      end loop;

      while L >= F and then (S (L) = ' ' or else S (L) = Character'Val (9)
                             or else S (L) = Character'Val (13))
      loop
         L := L - 1;
      end loop;

      return S (F .. L);
   end Trim;

   function Lower (S : String) return String is
      R : String := S;
   begin
      for I in R'Range loop
         if R (I) in 'A' .. 'Z' then
            R (I) := Character'Val
              (Character'Pos (R (I)) - Character'Pos ('A') + Character'Pos ('a'));
         end if;
      end loop;
      return R;
   end Lower;


   --------------------------------------------------------------------------
   --  Dates
   --------------------------------------------------------------------------

   type Broken_Down is record
      Year, Month, Day     : Integer;
      Hour, Minute, Second : Integer;
      Weekday              : Integer;   --  0 = Sunday .. 6 = Saturday
   end record;

   Month_Abbrev : constant array (1 .. 12) of String (1 .. 3) :=
     ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

   Weekday_Abbrev : constant array (0 .. 6) of String (1 .. 3) :=
     ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

   function TZ_Offset_Seconds (TZ : String) return Long_Long_Integer is
      Sign  : Long_Long_Integer := 1;
      Hours : Long_Long_Integer := 0;
      Mins  : Long_Long_Integer := 0;
   begin
      if TZ'Length < 5 then
         return 0;
      end if;
      if TZ (TZ'First) = '-' then
         Sign := -1;
      end if;
      declare
         D : constant String := TZ (TZ'First + 1 .. TZ'Last);
      begin
         if D'Length >= 4 then
            Hours := Long_Long_Integer'Value (D (D'First .. D'First + 1));
            Mins  := Long_Long_Integer'Value (D (D'First + 2 .. D'First + 3));
         end if;
      end;
      return Sign * (Hours * 3600 + Mins * 60);
   exception
      when others => return 0;
   end TZ_Offset_Seconds;

   --  Break the local wall-clock time (epoch shifted by the stored offset)
   --  into calendar fields, matching git's gmtime-on-shifted-epoch.
   function Break_Down (Epoch : Long_Long_Integer; TZ : String)
      return Broken_Down
   is
      Local : constant Long_Long_Integer := Epoch + TZ_Offset_Seconds (TZ);
      Days  : Long_Long_Integer := Local / 86_400;
      Secs  : Long_Long_Integer := Local mod 86_400;
      Z, Era, DOE, YOE, Y, DOY, MP : Long_Long_Integer;
      Result : Broken_Down;
   begin
      if Secs < 0 then
         Secs := Secs + 86_400;
         Days := Days - 1;
      end if;
      --  Weekday: 1970-01-01 was a Thursday (=4).
      Result.Weekday := Integer (((Days mod 7) + 4) mod 7);
      if Result.Weekday < 0 then
         Result.Weekday := Result.Weekday + 7;
      end if;
      --  Howard Hinnant's civil_from_days.
      Z := Days + 719_468;
      Era := (if Z >= 0 then Z else Z - 146_096) / 146_097;
      DOE := Z - Era * 146_097;
      YOE := (DOE - DOE / 1_460 + DOE / 36_524 - DOE / 146_096) / 365;
      Y := YOE + Era * 400;
      DOY := DOE - (365 * YOE + YOE / 4 - YOE / 100);
      MP := (5 * DOY + 2) / 153;
      Result.Day := Integer (DOY - (153 * MP + 2) / 5 + 1);
      Result.Month := Integer (if MP < 10 then MP + 3 else MP - 9);
      Result.Year := Integer (if Result.Month <= 2 then Y + 1 else Y);
      Result.Hour := Integer (Secs / 3600);
      Result.Minute := Integer ((Secs / 60) mod 60);
      Result.Second := Integer (Secs mod 60);
      return Result;
   end Break_Down;

   function Pad2 (N : Integer) return String is
      S : constant String := Integer'Image (N);
      D : constant String := S (S'First + 1 .. S'Last);
   begin
      return (if N < 10 then "0" & D else D);
   end Pad2;

   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return S (S'First + 1 .. S'Last);
   end Img;

   --  git "default" format: "Thu Apr 7 22:13:13 2005 +0200".
   function Date_Default (Id : Identity) return String is
      B : constant Broken_Down := Break_Down (Id.Epoch, To_String (Id.TZ));
   begin
      return Weekday_Abbrev (B.Weekday) & " " & Month_Abbrev (B.Month) & " "
        & Img (B.Day) & " " & Pad2 (B.Hour) & ":" & Pad2 (B.Minute) & ":"
        & Pad2 (B.Second) & " " & Img (B.Year) & " " & To_String (Id.TZ);
   end Date_Default;

   --  RFC2822: "Thu, 7 Apr 2005 22:13:13 +0200".
   function Date_RFC2822 (Id : Identity) return String is
      B : constant Broken_Down := Break_Down (Id.Epoch, To_String (Id.TZ));
   begin
      return Weekday_Abbrev (B.Weekday) & ", " & Img (B.Day) & " "
        & Month_Abbrev (B.Month) & " " & Img (B.Year) & " "
        & Pad2 (B.Hour) & ":" & Pad2 (B.Minute) & ":" & Pad2 (B.Second)
        & " " & To_String (Id.TZ);
   end Date_RFC2822;

   --  ISO 8601-like: "2005-04-07 22:13:13 +0200".
   function Date_ISO (Id : Identity) return String is
      B : constant Broken_Down := Break_Down (Id.Epoch, To_String (Id.TZ));
   begin
      return Img (B.Year) & "-" & Pad2 (B.Month) & "-" & Pad2 (B.Day) & " "
        & Pad2 (B.Hour) & ":" & Pad2 (B.Minute) & ":" & Pad2 (B.Second)
        & " " & To_String (Id.TZ);
   end Date_ISO;

   --  Strict ISO 8601: "2005-04-07T22:13:13+02:00".
   function Date_ISO_Strict (Id : Identity) return String is
      B  : constant Broken_Down := Break_Down (Id.Epoch, To_String (Id.TZ));
      TZ : constant String := To_String (Id.TZ);
      Colon_TZ : constant String :=
        (if TZ'Length >= 5
         then TZ (TZ'First .. TZ'First + 2) & ":" & TZ (TZ'First + 3 .. TZ'Last)
         else TZ);
   begin
      return Img (B.Year) & "-" & Pad2 (B.Month) & "-" & Pad2 (B.Day) & "T"
        & Pad2 (B.Hour) & ":" & Pad2 (B.Minute) & ":" & Pad2 (B.Second)
        & Colon_TZ;
   end Date_ISO_Strict;

   --  Short: "2005-04-07".
   function Date_Short (Id : Identity) return String is
      B : constant Broken_Down := Break_Down (Id.Epoch, To_String (Id.TZ));
   begin
      return Img (B.Year) & "-" & Pad2 (B.Month) & "-" & Pad2 (B.Day);
   end Date_Short;

   function Date_Unix (Id : Identity) return String is
   begin
      return Img (Integer (Id.Epoch));
   end Date_Unix;

   --  Current time as a Unix timestamp (mirrors the codebase's convention of
   --  Clock - 1970 epoch; correct on a UTC system, as used for these dates).
   function Now_Unix return Long_Long_Integer is
      Epoch : constant Ada.Calendar.Time := Ada.Calendar.Time_Of (1970, 1, 1);
   begin
      return Long_Long_Integer
        (Ada.Calendar."-" (Ada.Calendar.Clock, Epoch));
   end Now_Unix;

   --  "N unit(s) ago" with English pluralisation (LANG=C).
   function Ago (N : Integer; Unit : String) return String is
   begin
      return Img (N) & " " & Unit & (if N = 1 then "" else "s") & " ago";
   end Ago;

   --  git's show_date_relative, byte for byte.
   function Show_Relative (Diff_Seconds : Long_Long_Integer) return String is
      D : Long_Long_Integer := Diff_Seconds;
   begin
      if D < 0 then
         return "in the future";
      elsif D < 90 then
         return Ago (Integer (D), "second");
      end if;
      D := (D + 30) / 60;                    --  minutes
      if D < 90 then
         return Ago (Integer (D), "minute");
      end if;
      D := (D + 30) / 60;                    --  hours
      if D < 36 then
         return Ago (Integer (D), "hour");
      end if;
      D := (D + 12) / 24;                    --  days
      if D < 14 then
         return Ago (Integer (D), "day");
      elsif D < 70 then
         return Ago (Integer ((D + 3) / 7), "week");
      elsif D < 365 then
         return Ago (Integer ((D + 15) / 30), "month");
      elsif D < 1825 then
         declare
            Total_Months : constant Long_Long_Integer :=
              (D * 12 * 2 + 365) / (365 * 2);
            Years  : constant Integer := Integer (Total_Months / 12);
            Months : constant Integer := Integer (Total_Months mod 12);
         begin
            if Months > 0 then
               return Img (Years) & " year" & (if Years = 1 then "" else "s")
                 & ", " & Img (Months) & " month"
                 & (if Months = 1 then "" else "s") & " ago";
            else
               return Ago (Years, "year");
            end if;
         end;
      else
         return Ago (Integer ((D + 183) / 365), "year");
      end if;
   end Show_Relative;

   --  git's show_date_human. Today -> relative; same year -> weekday (+ month
   --  day when older than ~5 days) + time; other years -> "Mon d YYYY".
   function Show_Human (Id : Identity) return String is
      TZ      : constant String := To_String (Id.TZ);
      TM      : constant Broken_Down := Break_Down (Id.Epoch, TZ);
      Now_E   : constant Long_Long_Integer := Now_Unix;
      Now_TM  : constant Broken_Down := Break_Down (Now_E, TZ);
      Hide_Year : constant Boolean := TM.Year = Now_TM.Year;
      Hide_Date : Boolean := False;   --  month + day
      Hide_Wday : Boolean := True;
      Hide_Time : Boolean := False;
      Result    : Unbounded_String;

      procedure Add (S : String) is
      begin
         if Length (Result) > 0 then
            Append (Result, ' ');
         end if;
         Append (Result, S);
      end Add;
   begin
      if Hide_Year and then TM.Month = Now_TM.Month
        and then TM.Day = Now_TM.Day
      then
         return Show_Relative (Now_E - Id.Epoch);   --  today
      end if;

      if Hide_Year then
         Hide_Wday := False;
         if TM.Month = Now_TM.Month and then TM.Day + 5 > Now_TM.Day then
            Hide_Date := True;
         end if;
      else
         Hide_Time := True;   --  other year: no weekday, no time
      end if;

      if not Hide_Wday then
         Add (Weekday_Abbrev (TM.Weekday));
      end if;
      if not Hide_Date then
         Add (Month_Abbrev (TM.Month));
         Add (Img (TM.Day));
      end if;
      if not Hide_Year then
         Add (Img (TM.Year));
      end if;
      if not Hide_Time then
         Add (Pad2 (TM.Hour) & ":" & Pad2 (TM.Minute));
      end if;
      return To_String (Result);
   end Show_Human;

   --------------------------------------------------------------------------
   --  Trailers (%(trailers[:options]))
   --------------------------------------------------------------------------

   type Trailer is record
      Key   : Unbounded_String;
      Value : Unbounded_String;   --  may contain embedded LF (continuations)
   end record;

   package Trailer_Vectors is new Ada.Containers.Vectors (Positive, Trailer);

   --  True if Line looks like "key: value" (token key, no internal spaces).
   function Is_Trailer_Line
     (Line : String; Colon : out Natural) return Boolean
   is
   begin
      Colon := 0;
      for I in Line'Range loop
         if Line (I) = ':' then
            Colon := I;
            exit;
         elsif Line (I) = ' ' or else Line (I) = Character'Val (9) then
            return False;   --  whitespace before a separator: not a trailer
         end if;
      end loop;
      return Colon > Line'First;   --  non-empty key before ':'
   end Is_Trailer_Line;

   --  Parse the commit message's trailing paragraph into trailers, or return
   --  an empty list when the last paragraph is not a trailer block.
   function Parse_Trailers (Message : String) return Trailer_Vectors.Vector is
      Result : Trailer_Vectors.Vector;

      --  Start of the last paragraph (after the final blank line).
      Block_Start : Natural := Message'First;
      Valid       : Boolean := True;
      Have_Trailer : Boolean := False;
      Current     : Natural := 0;   --  index of trailer being extended
      Line_Start  : Natural;
   begin
      if Message'Length = 0 then
         return Result;
      end if;
      for I in Message'First .. Message'Last - 1 loop
         if Message (I) = LF and then Message (I + 1) = LF then
            Block_Start := I + 2;
         end if;
      end loop;

      Line_Start := Block_Start;
      declare
         I : Natural := Block_Start;
      begin
         while I <= Message'Last + 1 loop
            if I > Message'Last or else Message (I) = LF then
               declare
                  Line : constant String := Message (Line_Start .. I - 1);
                  Colon : Natural;
               begin
                  if Line'Length = 0 then
                     null;   --  ignore stray blank line inside the block
                  elsif Line (Line'First) = '#' then
                     null;   --  comment line
                  elsif (Line (Line'First) = ' '
                         or else Line (Line'First) = Character'Val (9))
                    and then Current /= 0
                  then
                     --  Continuation of the previous trailer's value.
                     declare
                        T : Trailer := Result (Current);
                     begin
                        Append (T.Value, LF & Line);
                        Result.Replace_Element (Current, T);
                     end;
                  elsif Is_Trailer_Line (Line, Colon) then
                     declare
                        Key : constant String := Line (Line'First .. Colon - 1);
                        VF  : Natural := Colon + 1;
                     begin
                        while VF <= Line'Last and then Line (VF) = ' ' loop
                           VF := VF + 1;
                        end loop;
                        Result.Append
                          (Trailer'
                             (Key   => To_Unbounded_String (Key),
                              Value => To_Unbounded_String
                                         (Line (VF .. Line'Last))));
                        Current := Positive (Result.Length);
                        Have_Trailer := True;
                     end;
                  else
                     Valid := False;   --  a non-trailer line voids the block
                  end if;
               end;
               Line_Start := I + 1;
            end if;
            I := I + 1;
         end loop;
      end;

      if not (Valid and then Have_Trailer) then
         Result.Clear;
      end if;
      return Result;
   end Parse_Trailers;

   --  Expand %n / %x?? / %% inside a trailer option value (git does this).
   function Unescape_Option (S : String) return String is
      R : Unbounded_String;
      I : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = '%' and then I + 1 <= S'Last then
            case S (I + 1) is
               when '%' => Append (R, '%'); I := I + 2;
               when 'n' => Append (R, LF); I := I + 2;
               when 'x' =>
                  if I + 3 <= S'Last and then Is_Hex (S (I + 2))
                    and then Is_Hex (S (I + 3))
                  then
                     Append (R, Character'Val
                       (Hex_Val (S (I + 2)) * 16 + Hex_Val (S (I + 3))));
                     I := I + 4;
                  else
                     Append (R, S (I)); I := I + 1;
                  end if;
               when others => Append (R, S (I)); I := I + 1;
            end case;
         else
            Append (R, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (R);
   end Unescape_Option;

   --  Fold continuation lines ("\n" + whitespace) into single spaces.
   function Unfold (S : String) return String is
      R : Unbounded_String;
      I : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = LF then
            Append (R, ' ');
            I := I + 1;
            while I <= S'Last
              and then (S (I) = ' ' or else S (I) = Character'Val (9))
            loop
               I := I + 1;
            end loop;
         else
            Append (R, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (R);
   end Unfold;

   --  Format %(trailers:<Options>) for Message.
   function Format_Trailers (Message : String; Options : String) return String
   is
      Trailers : constant Trailer_Vectors.Vector := Parse_Trailers (Message);

      Filter_Key : Unbounded_String;
      Have_Filter : Boolean := False;
      Sep        : Unbounded_String;
      Have_Sep   : Boolean := False;
      KV_Sep     : Unbounded_String := To_Unbounded_String (": ");
      Do_Unfold  : Boolean := False;
      Value_Only : Boolean := False;
      Key_Only   : Boolean := False;

      --  Split Options on top-level commas into name / name=value tokens.
      procedure Parse_Options is
         Start : Natural := Options'First;
      begin
         for I in Options'First .. Options'Last + 1 loop
            if I > Options'Last or else Options (I) = ',' then
               declare
                  Tok : constant String := Options (Start .. I - 1);
                  Eq  : Natural := 0;
               begin
                  for K in Tok'Range loop
                     if Tok (K) = '=' then
                        Eq := K;
                        exit;
                     end if;
                  end loop;
                  declare
                     Name : constant String :=
                       (if Eq = 0 then Tok else Tok (Tok'First .. Eq - 1));
                     Val  : constant String :=
                       (if Eq = 0 then "" else Tok (Eq + 1 .. Tok'Last));
                  begin
                     if Name = "key" then
                        Filter_Key := To_Unbounded_String (Val);
                        Have_Filter := True;
                     elsif Name = "separator" then
                        Sep := To_Unbounded_String (Unescape_Option (Val));
                        Have_Sep := True;
                     elsif Name = "key_value_separator" then
                        KV_Sep := To_Unbounded_String (Unescape_Option (Val));
                     elsif Name = "unfold" then
                        Do_Unfold := Eq = 0 or else Val = "true";
                     elsif Name = "valueonly" then
                        Value_Only := Eq = 0 or else Val = "true";
                     elsif Name = "keyonly" then
                        Key_Only := Eq = 0 or else Val = "true";
                     end if;
                  end;
               end;
               Start := I + 1;
            end if;
         end loop;
      end Parse_Options;

      function Eq_Ignore_Case (A, B : String) return Boolean is
        (Lower (A) = Lower (B));

      Result : Unbounded_String;
      First  : Boolean := True;
   begin
      Parse_Options;
      for T of Trailers loop
         if not Have_Filter
           or else Eq_Ignore_Case (To_String (T.Key), To_String (Filter_Key))
         then
            declare
               Val : constant String :=
                 (if Do_Unfold then Unfold (To_String (T.Value))
                  else To_String (T.Value));
               Piece : constant String :=
                 (if Key_Only then To_String (T.Key)
                  elsif Value_Only then Val
                  else To_String (T.Key) & To_String (KV_Sep) & Val);
            begin
               if Have_Sep then
                  if not First then
                     Append (Result, To_String (Sep));
                  end if;
                  Append (Result, Piece);
               else
                  --  Default: every trailer terminated by a newline.
                  Append (Result, Piece & LF);
               end if;
               First := False;
            end;
         end if;
      end loop;
      return To_String (Result);
   end Format_Trailers;

   --------------------------------------------------------------------------
   --  Column alignment (%<()/%>()/%><()) and line wrapping (%w())
   --------------------------------------------------------------------------

   type Pad_Kind is (Pad_Left, Pad_Right, Pad_Center);
   type Trunc_Kind is (Trunc_None, Trunc_End, Trunc_Left, Trunc_Mid);

   function Spaces (N : Natural) return String is
     (if N = 0 then "" else String'(1 .. N => ' '));

   --  Pad S to Width (git alignment); truncate with ".." only when a truncation
   --  mode is set and S is wider than Width.
   function Align
     (S : String; Kind : Pad_Kind; Width : Natural; Trunc : Trunc_Kind)
      return String
   is
   begin
      if S'Length >= Width then
         if Trunc = Trunc_None or else Width < 2 then
            return S;
         end if;
         declare
            Keep : constant Natural := Width - 2;
         begin
            case Trunc is
               when Trunc_End =>
                  return S (S'First .. S'First + Keep - 1) & "..";
               when Trunc_Left =>
                  return ".." & S (S'Last - Keep + 1 .. S'Last);
               when Trunc_Mid =>
                  declare
                     L : constant Natural := Keep / 2;
                     R : constant Natural := Keep - L;
                  begin
                     return S (S'First .. S'First + L - 1) & ".."
                       & S (S'Last - R + 1 .. S'Last);
                  end;
               when others =>
                  return S;
            end case;
         end;
      else
         declare
            Pad : constant Natural := Width - S'Length;
         begin
            case Kind is
               when Pad_Left   => return S & Spaces (Pad);
               when Pad_Right  => return Spaces (Pad) & S;
               when Pad_Center =>
                  return Spaces (Pad / 2) & S & Spaces (Pad - Pad / 2);
            end case;
         end;
      end if;
   end Align;

   --  git-style greedy word wrap: Width columns, first line indented Ind1,
   --  continuation lines Ind2.
   function Wrap (S : String; Width, Ind1, Ind2 : Natural) return String is
      Result   : Unbounded_String;
      Line     : Unbounded_String := To_Unbounded_String (Spaces (Ind1));
      Line_Len : Natural := Ind1;
      Indent   : Natural := Ind1;
      Have_Line : Boolean := False;
      Word_S   : Natural := S'First;

      procedure Emit_Word (W : String) is
      begin
         if W'Length = 0 then
            return;
         end if;
         if Line_Len > Indent
           and then Line_Len + 1 + W'Length > Width
         then
            if Have_Line then
               Append (Result, LF);
            end if;
            Append (Result, To_String (Line));
            Have_Line := True;
            Indent := Ind2;
            Line := To_Unbounded_String (Spaces (Indent) & W);
            Line_Len := Indent + W'Length;
         elsif Line_Len = Indent then
            Append (Line, W);
            Line_Len := Line_Len + W'Length;
         else
            Append (Line, ' ' & W);
            Line_Len := Line_Len + 1 + W'Length;
         end if;
      end Emit_Word;
   begin
      for I in S'First .. S'Last + 1 loop
         if I > S'Last or else S (I) = ' ' or else S (I) = LF then
            if I > Word_S then
               Emit_Word (S (Word_S .. I - 1));
            end if;
            Word_S := I + 1;
         end if;
      end loop;
      if Have_Line then
         Append (Result, LF);
      end if;
      Append (Result, To_String (Line));
      return To_String (Result);
   end Wrap;

   procedure Parse_Align_Spec
     (S : String; Width : out Natural; Trunc : out Trunc_Kind)
   is
      Comma : Natural := 0;
   begin
      Width := 0;
      Trunc := Trunc_None;
      for I in S'Range loop
         if S (I) = ',' then
            Comma := I;
            exit;
         end if;
      end loop;
      declare
         W  : constant String :=
           Trim (if Comma = 0 then S else S (S'First .. Comma - 1));
         W2 : constant String :=
           (if W'Length > 0 and then W (W'First) = '|'
            then W (W'First + 1 .. W'Last) else W);
      begin
         begin
            Width := Natural'Value (W2);
         exception
            when others => Width := 0;
         end;
      end;
      if Comma /= 0 then
         declare
            M : constant String := Trim (S (Comma + 1 .. S'Last));
         begin
            if M = "trunc" then
               Trunc := Trunc_End;
            elsif M = "ltrunc" then
               Trunc := Trunc_Left;
            elsif M = "mtrunc" then
               Trunc := Trunc_Mid;
            end if;
         end;
      end if;
   end Parse_Align_Spec;

   procedure Parse_Wrap_Spec
     (S : String; Width, Ind1, Ind2 : out Natural)
   is
      Field : Natural := 0;
      Start : Integer := S'First;

      procedure Assign (Text : String) is
         V : Natural := 0;
      begin
         begin
            V := Natural'Value (Trim (Text));
         exception
            when others => V := 0;
         end;
         case Field is
            when 0 => Width := V;
            when 1 => Ind1 := V;
            when 2 => Ind2 := V;
            when others => null;
         end case;
      end Assign;
   begin
      Width := 0;
      Ind1 := 0;
      Ind2 := 0;
      for I in S'First .. S'Last + 1 loop
         if I > S'Last or else S (I) = ',' then
            Assign (S (Start .. I - 1));
            Field := Field + 1;
            Start := I + 1;
         end if;
      end loop;
   end Parse_Wrap_Spec;

   --------------------------------------------------------------------------
   --  Decoration (%d / %D)
   --------------------------------------------------------------------------

   function Starts (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   --  Short display name of a ref for decoration.
   function Decoration_Name (Refname : String) return String is
   begin
      if Starts (Refname, "refs/heads/") then
         return Refname (Refname'First + 11 .. Refname'Last);
      elsif Starts (Refname, "refs/tags/") then
         return "tag: " & Refname (Refname'First + 10 .. Refname'Last);
      elsif Starts (Refname, "refs/remotes/") then
         return Refname (Refname'First + 13 .. Refname'Last);
      elsif Starts (Refname, "refs/") then
         return Refname (Refname'First + 5 .. Refname'Last);
      else
         return Refname;
      end if;
   end Decoration_Name;

   --  git's ref decoration for a commit: "HEAD -> branch, tag: v, remote/x,
   --  branch" in refname-descending order with HEAD grafted to its branch.
   --  Wrapped adds git's leading " (" ... ")" (used by %d); %D is bare.
   function Decoration
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Wrapped   : Boolean)
      return String
   is
      HT      : constant Character := Character'Val (9);
      Target  : constant String := Version.Objects.To_String (Commit_Id);
      Empty   : Version.Ref_Format.String_Vectors.Vector;
      Lines   : Version.Ref_Format.String_Vectors.Vector;
      Matched : Version.Ref_Format.String_Vectors.Vector;

      function Refname_After (L, R : String) return Boolean is (L > R);
      package Sorter is new Version.Ref_Format.String_Vectors.Generic_Sorting
        ("<" => Refname_After);

      Head        : constant Version.Refs.Head_Info :=
        Version.Refs.Read_Head (Repo);
      Head_Attached : constant Boolean := Version.Refs.Is_Attached (Head);
      Graft_Ref   : constant String :=
        (if Head_Attached
         then "refs/heads/" & Version.Refs.Branch_Name (Head) else "");
      Head_Commit : Unbounded_String;
      Result      : Unbounded_String;
      First       : Boolean := True;
   begin
      begin
         Lines := Version.Ref_Format.For_Each_Ref (Repo, Empty);
      exception
         when others => return "";
      end;

      for L of Lines loop
         declare
            Line   : constant String := L;
            SP     : Natural := 0;
            Tab    : Natural := 0;
         begin
            for I in Line'Range loop
               if Line (I) = ' ' and then SP = 0 then
                  SP := I;
               elsif Line (I) = HT then
                  Tab := I;
                  exit;
               end if;
            end loop;
            if SP > 0 and then Tab > SP then
               declare
                  Obj_Name : constant String := Line (Line'First .. SP - 1);
                  Obj_Type : constant String := Line (SP + 1 .. Tab - 1);
                  Refname  : constant String := Line (Tab + 1 .. Line'Last);
                  Peeled   : Unbounded_String;
               begin
                  if Obj_Type = "tag" then
                     begin
                        Peeled := To_Unbounded_String
                          (Version.Objects.To_String
                             (Version.Revisions.Resolve_Commit
                                (Repo, Refname)));
                     exception
                        when others => Peeled := Null_Unbounded_String;
                     end;
                  else
                     Peeled := To_Unbounded_String (Obj_Name);
                  end if;
                  if To_String (Peeled) = Target then
                     Matched.Append (Refname);
                  end if;
               end;
            end if;
         end;
      end loop;

      begin
         Head_Commit :=
           To_Unbounded_String (Version.Refs.Current_Commit_Id (Repo));
      exception
         when others => Head_Commit := Null_Unbounded_String;
      end;

      Sorter.Sort (Matched);

      declare
         Head_At_Target : constant Boolean := To_String (Head_Commit) = Target;

         procedure Emit (S : String) is
         begin
            if not First then
               Append (Result, ", ");
            end if;
            Append (Result, S);
            First := False;
         end Emit;
      begin
         if Head_At_Target then
            if Head_Attached then
               Emit ("HEAD -> " & Version.Refs.Branch_Name (Head));
            else
               Emit ("HEAD");
            end if;
         end if;
         for R of Matched loop
            if not (Head_At_Target and then Head_Attached
                    and then R = Graft_Ref)
            then
               Emit (Decoration_Name (R));
            end if;
         end loop;
      end;

      if Length (Result) = 0 then
         return "";
      elsif Wrapped then
         return " (" & To_String (Result) & ")";
      else
         return To_String (Result);
      end if;
   end Decoration;

   --------------------------------------------------------------------------
   --  Expansion
   --------------------------------------------------------------------------

   function Expand
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String)
      return String
   is
      Cache  : Version.Object_Cache.Object_Cache;
      Obj    : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Cache, Commit_Id);
      Commit : constant String := Version.Objects.Content (Obj);

      Full_Id   : constant String := Version.Objects.To_String (Commit_Id);
      Tree_Id   : constant String := Header_Value (Commit, "tree ");
      Author    : constant Identity :=
        Parse_Identity (Header_Value (Commit, "author "));
      Committer : constant Identity :=
        Parse_Identity (Header_Value (Commit, "committer "));
      Encoding  : constant String := Header_Value (Commit, "encoding ");
      Message   : constant String := Raw_Message (Commit);

      Result : Unbounded_String;

      --  Abbreviation policy from core.abbrev (default "auto" -> floor 7,
      --  extended to uniqueness; a number -> that width, still extended if
      --  ambiguous; "no"/"false" -> the full id).
      Abbrev_Full : Boolean := False;
      Abbrev_Min  : Positive := Default_Abbrev;

      Mailmap : Version.Mailmap.Entries;

      --  gpg signature details are loaded lazily (only if a %G? placeholder is
      --  present) since verification spawns gpg.
      Sig_Ready  : Boolean := False;
      Sig_Cached : Version.Verify.Signature_Details_Result;

      function Sig_Details return Version.Verify.Signature_Details_Result is
      begin
         if not Sig_Ready then
            begin
               Sig_Cached := Version.Verify.Signature_Details (Repo, Commit_Id);
            exception
               when others => null;
            end;
            Sig_Ready := True;
         end if;
         return Sig_Cached;
      end Sig_Details;

      --  Column-alignment (%<()/%>()/%><()) pending state.
      Pad_Active : Boolean := False;
      Pad_Type   : Pad_Kind := Pad_Left;
      Pad_Width  : Natural := 0;
      Pad_Trunc  : Trunc_Kind := Trunc_None;
      Pad_Start  : Natural := 0;   --  Result length when the region opened

      --  Line-wrap (%w()) pending state.
      Wrap_Active : Boolean := False;
      Wrap_Width  : Natural := 0;
      Wrap_Ind1   : Natural := 0;
      Wrap_Ind2   : Natural := 0;
      Wrap_Start  : Natural := 0;

      --  Apply a pending alignment to the region emitted since it opened.
      procedure Flush_Pad is
      begin
         if not Pad_Active then
            return;
         end if;
         declare
            Total  : constant Natural := Length (Result);
            Region : constant String :=
              (if Total > Pad_Start then Slice (Result, Pad_Start + 1, Total)
               else "");
            Prefix : constant String :=
              (if Pad_Start > 0 then Slice (Result, 1, Pad_Start) else "");
         begin
            Result := To_Unbounded_String
              (Prefix & Align (Region, Pad_Type, Pad_Width, Pad_Trunc));
         end;
         Pad_Active := False;
      end Flush_Pad;

      function Abbrev (Hex : String) return String is
      begin
         if Abbrev_Full or else Hex'Length <= Abbrev_Min then
            return Hex;
         end if;
         declare
            Len : constant Natural :=
              Version.Revisions.Unique_Abbrev_Length
                (Repo, Version.Objects.To_Object_Id (Hex), Abbrev_Min);
         begin
            if Len >= Hex'Length then
               return Hex;
            else
               return Hex (Hex'First .. Hex'First + Len - 1);
            end if;
         end;
      exception
         when others =>
            return (if Hex'Length >= Abbrev_Min
                    then Hex (Hex'First .. Hex'First + Abbrev_Min - 1)
                    else Hex);
      end Abbrev;

      --  Space-separated parent ids (full or abbreviated).
      function Parents (Short : Boolean) return String is
         Out_S : Unbounded_String;
         First : Boolean := True;
         I     : Natural := Commit'First;
      begin
         while I <= Commit'Last loop
            declare
               Line_End : Natural := I;
            begin
               while Line_End <= Commit'Last
                 and then Commit (Line_End) /= LF
               loop
                  Line_End := Line_End + 1;
               end loop;
               exit when Line_End = I;   --  blank line: end of headers
               if Line_End - I >= 7
                 and then Commit (I .. I + 6) = "parent "
               then
                  declare
                     P : constant String := Commit (I + 7 .. Line_End - 1);
                  begin
                     if not First then
                        Append (Out_S, ' ');
                     end if;
                     Append (Out_S, (if Short then Abbrev (P) else P));
                     First := False;
                  end;
               end if;
               exit when Line_End > Commit'Last;
               I := Line_End + 1;
            end;
         end loop;
         return To_String (Out_S);
      end Parents;

      I : Natural := Format'First;

      --  Author/committer identity dispatch for "%a?"/"%c?".
      function Ident_Field (Id : Identity; Field : Character) return String is
         function Mapped_Name return String is
            RN, RE : Unbounded_String;
         begin
            Version.Mailmap.Apply (Mailmap, To_String (Id.Name), To_String (Id.Email),
                           RN, RE);
            return To_String (RN);
         end Mapped_Name;
         function Mapped_Email return String is
            RN, RE : Unbounded_String;
         begin
            Version.Mailmap.Apply (Mailmap, To_String (Id.Name), To_String (Id.Email),
                           RN, RE);
            return To_String (RE);
         end Mapped_Email;
      begin
         case Field is
            when 'n' => return To_String (Id.Name);
            when 'N' => return Mapped_Name;
            when 'e' => return To_String (Id.Email);
            when 'E' => return Mapped_Email;
            when 'l' => return Email_Local_Part (To_String (Id.Email));
            when 'L' => return Email_Local_Part (Mapped_Email);
            when 'd' => return Date_Default (Id);
            when 'D' => return Date_RFC2822 (Id);
            when 'i' => return Date_ISO (Id);
            when 'I' => return Date_ISO_Strict (Id);
            when 's' => return Date_Short (Id);
            when 't' => return Date_Unix (Id);
            when 'r' => return Show_Relative (Now_Unix - Id.Epoch);
            when 'h' => return Show_Human (Id);
            when others => return "";   --  caller handles "unknown"
         end case;
      end Ident_Field;

      function Known_Ident_Field (Field : Character) return Boolean is
        (Field in 'n' | 'N' | 'e' | 'E' | 'l' | 'L'
                | 'd' | 'D' | 'i' | 'I' | 's' | 't' | 'r' | 'h');

   begin
      --  Resolve the abbreviation policy once from core.abbrev.
      declare
         Cfg : constant String :=
           (if Version.Config.Has_Key (Repo, "core.abbrev")
            then Ada.Characters.Handling.To_Lower
                   (Version.Config.Get_Value (Repo, "core.abbrev"))
            else "");
      begin
         if Cfg = "no" or else Cfg = "false" then
            Abbrev_Full := True;
         elsif Cfg = "" or else Cfg = "auto" then
            Abbrev_Min := Default_Abbrev;
         else
            begin
               declare
                  N : constant Integer := Integer'Value (Cfg);
               begin
                  if N >= Full_Id'Length then
                     Abbrev_Full := True;
                  elsif N < 4 then
                     Abbrev_Min := 4;
                  else
                     Abbrev_Min := N;
                  end if;
               end;
            exception
               when others => Abbrev_Min := Default_Abbrev;
            end;
         end if;
      end;

      --  Load the worktree .mailmap (if any) for %aN/%aE/%aL and %c* variants.
      --  A bare repository has no worktree root, so Root_Path raises: treat
      --  that as "no mailmap" rather than failing the whole expansion.
      declare
         Root : constant String := Version.Repository.Root_Path (Repo);
         Path : constant String := Version.Files.Join (Root, ".mailmap");
      begin
         if Version.Files.Is_Ordinary_File (Path) then
            Mailmap := Version.Mailmap.Parse
              (Version.Files.Read_Binary_File (Path));
         end if;
      exception
         when others => null;
      end;

      while I <= Format'Last loop
         if Format (I) = '%' and then I < Format'Last then
            declare
               C : constant Character := Format (I + 1);
               Trigger : Boolean := True;   --  flush a pending pad after this
            begin
               case C is
                  when '%' =>
                     Append (Result, '%');
                     I := I + 2;
                  when 'n' =>
                     Append (Result, LF);
                     I := I + 2;
                  when 'H' =>
                     Append (Result, Full_Id);
                     I := I + 2;
                  when 'h' =>
                     Append (Result, Abbrev (Full_Id));
                     I := I + 2;
                  when 'T' =>
                     Append (Result, Tree_Id);
                     I := I + 2;
                  when 't' =>
                     Append (Result, Abbrev (Tree_Id));
                     I := I + 2;
                  when 'P' =>
                     Append (Result, Parents (Short => False));
                     I := I + 2;
                  when 'p' =>
                     Append (Result, Parents (Short => True));
                     I := I + 2;
                  when 's' =>
                     Append (Result, Subject (Message));
                     I := I + 2;
                  when 'f' =>
                     Append (Result, Sanitize_Subject (Subject (Message)));
                     I := I + 2;
                  when 'b' =>
                     --  git's %b is the body followed by one trailing newline
                     --  (empty, with no newline, when there is no body).
                     declare
                        Body_Text : constant String := Message_Body (Message);
                     begin
                        if Body_Text'Length > 0 then
                           Append (Result, Body_Text & LF);
                        end if;
                     end;
                     I := I + 2;
                  when 'B' =>
                     --  git's %B is the raw message normalised to a single
                     --  trailing newline.
                     if Message'Length > 0 then
                        Append (Result, Message & LF);
                     end if;
                     I := I + 2;
                  when 'e' =>
                     Append (Result, Encoding);
                     I := I + 2;
                  when 'd' =>
                     Append
                       (Result, Decoration (Repo, Commit_Id, Wrapped => True));
                     I := I + 2;
                  when 'D' =>
                     Append
                       (Result,
                        Decoration (Repo, Commit_Id, Wrapped => False));
                     I := I + 2;
                  when 'x' =>
                     --  %x?? : a raw byte from two hex digits.
                     if I + 3 <= Format'Last
                       and then Is_Hex (Format (I + 2))
                       and then Is_Hex (Format (I + 3))
                     then
                        Append
                          (Result,
                           Character'Val
                             (Hex_Val (Format (I + 2)) * 16
                              + Hex_Val (Format (I + 3))));
                        I := I + 4;
                     else
                        Append (Result, '%');
                        I := I + 1;
                     end if;
                  when 'G' =>
                     if I + 2 <= Format'Last
                       and then Format (I + 2) in
                                  '?' | 'S' | 'K' | 'F' | 'P' | 'T' | 'G'
                     then
                        declare
                           D : constant Version.Verify.Signature_Details_Result
                             := Sig_Details;
                        begin
                           case Format (I + 2) is
                              when '?' => Append (Result, D.Code);
                              when 'S' => Append (Result, To_String (D.Signer));
                              when 'K' => Append (Result, To_String (D.Key));
                              when 'F' =>
                                 Append (Result, To_String (D.Fingerprint));
                              when 'P' =>
                                 Append (Result, To_String (D.Primary_FP));
                              when 'T' => Append (Result, To_String (D.Trust));
                              when 'G' =>
                                 Append (Result, To_String (D.Raw_Output));
                              when others => null;
                           end case;
                        end;
                        I := I + 3;
                     else
                        Append (Result, '%');
                        I := I + 1;
                     end if;
                  when '(' =>
                     --  %(trailers[:options]) -- other %(...) are unsupported.
                     declare
                        J : Natural := I + 2;
                     begin
                        while J <= Format'Last and then Format (J) /= ')' loop
                           J := J + 1;
                        end loop;
                        if J <= Format'Last then
                           declare
                              Inner : constant String := Format (I + 2 .. J - 1);
                           begin
                              if Inner = "trailers"
                                or else
                                  (Inner'Length >= 9
                                   and then Inner (Inner'First ..
                                                   Inner'First + 8) = "trailers:")
                              then
                                 Append
                                   (Result,
                                    Format_Trailers
                                      (Message,
                                       (if Inner'Length > 8
                                        then Inner (Inner'First + 9 .. Inner'Last)
                                        else "")));
                                 I := J + 1;
                              else
                                 Append (Result, '%');
                                 I := I + 1;
                              end if;
                           end;
                        else
                           Append (Result, '%');
                           I := I + 1;
                        end if;
                     end;
                  when 'a' | 'c' =>
                     if I + 2 <= Format'Last
                       and then Known_Ident_Field (Format (I + 2))
                     then
                        Append
                          (Result,
                           Ident_Field
                             ((if C = 'a' then Author else Committer),
                              Format (I + 2)));
                        I := I + 3;
                     else
                        --  Unknown "%a?"/"%c?": emit "%" literally, continue.
                        Append (Result, '%');
                        I := I + 1;
                     end if;
                  when 'C' =>
                     --  Colour placeholders produce nothing without a colour
                     --  context (export-subst / piped output).
                     Trigger := False;
                     if I + 2 <= Format'Last and then Format (I + 2) = '(' then
                        declare
                           J : Natural := I + 3;
                        begin
                           while J <= Format'Last
                             and then Format (J) /= ')'
                           loop
                              J := J + 1;
                           end loop;
                           I := (if J <= Format'Last then J + 1 else I + 2);
                        end;
                     elsif I + 4 <= Format'Last
                       and then Format (I + 2 .. I + 4) = "red"
                     then
                        I := I + 5;
                     elsif I + 6 <= Format'Last
                       and then Format (I + 2 .. I + 6) = "green"
                     then
                        I := I + 7;
                     elsif I + 5 <= Format'Last
                       and then Format (I + 2 .. I + 5) = "blue"
                     then
                        I := I + 6;
                     elsif I + 6 <= Format'Last
                       and then Format (I + 2 .. I + 6) = "reset"
                     then
                        I := I + 7;
                     else
                        Append (Result, '%');
                        I := I + 1;
                        Trigger := True;
                     end if;
                  when '<' | '>' =>
                     --  Column alignment: %<()/%>()/%><().
                     Trigger := False;
                     declare
                        Kind    : Pad_Kind := Pad_Left;
                        Open    : Natural := 0;
                     begin
                        if C = '<' and then I + 2 <= Format'Last
                          and then Format (I + 2) = '('
                        then
                           Kind := Pad_Left;
                           Open := I + 2;
                        elsif C = '>' and then I + 3 <= Format'Last
                          and then Format (I + 2) = '<'
                          and then Format (I + 3) = '('
                        then
                           Kind := Pad_Center;
                           Open := I + 3;
                        elsif C = '>' and then I + 2 <= Format'Last
                          and then Format (I + 2) = '('
                        then
                           Kind := Pad_Right;
                           Open := I + 2;
                        end if;
                        if Open = 0 then
                           Append (Result, '%');
                           I := I + 1;
                           Trigger := True;
                        else
                           declare
                              J : Natural := Open + 1;
                           begin
                              while J <= Format'Last
                                and then Format (J) /= ')'
                              loop
                                 J := J + 1;
                              end loop;
                              if J > Format'Last then
                                 Append (Result, '%');
                                 I := I + 1;
                                 Trigger := True;
                              else
                                 Flush_Pad;   --  close any prior region first
                                 Parse_Align_Spec
                                   (Format (Open + 1 .. J - 1),
                                    Pad_Width, Pad_Trunc);
                                 Pad_Type := Kind;
                                 Pad_Start := Length (Result);
                                 Pad_Active := True;
                                 I := J + 1;
                              end if;
                           end;
                        end if;
                     end;
                  when 'w' =>
                     --  %w(width,indent1,indent2): line wrapping of what follows.
                     Trigger := False;
                     if I + 2 <= Format'Last and then Format (I + 2) = '(' then
                        declare
                           J : Natural := I + 3;
                        begin
                           while J <= Format'Last
                             and then Format (J) /= ')'
                           loop
                              J := J + 1;
                           end loop;
                           if J > Format'Last then
                              Append (Result, '%');
                              I := I + 1;
                              Trigger := True;
                           else
                              Parse_Wrap_Spec
                                (Format (I + 3 .. J - 1),
                                 Wrap_Width, Wrap_Ind1, Wrap_Ind2);
                              Wrap_Active := Wrap_Width > 0;
                              Wrap_Start := Length (Result);
                              I := J + 1;
                           end if;
                        end;
                     else
                        Append (Result, '%');
                        I := I + 1;
                        Trigger := True;
                     end if;
                  when others =>
                     --  Unknown placeholder: emit "%" literally and advance one.
                     Append (Result, '%');
                     I := I + 1;
               end case;
               if Pad_Active and then Trigger then
                  Flush_Pad;
               end if;
            end;
         else
            Append (Result, Format (I));
            I := I + 1;
         end if;
      end loop;

      --  Apply any pending line wrap to the text emitted after %w().
      if Wrap_Active then
         declare
            Total  : constant Natural := Length (Result);
            Region : constant String :=
              (if Total > Wrap_Start then Slice (Result, Wrap_Start + 1, Total)
               else "");
            Prefix : constant String :=
              (if Wrap_Start > 0 then Slice (Result, 1, Wrap_Start) else "");
         begin
            Result := To_Unbounded_String
              (Prefix & Wrap (Region, Wrap_Width, Wrap_Ind1, Wrap_Ind2));
         end;
      end if;
      return To_String (Result);
   end Expand;

end Version.Pretty_Format;
