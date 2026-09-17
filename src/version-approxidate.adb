with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Characters.Handling;

with Version.Timestamps;

package body Version.Approxidate is

   use type Ada.Calendar.Time;

   --  A broken-down local time in git's tm terms: -1 marks a date field
   --  that no token has set yet.
   type Broken is record
      Year : Integer := -1;   --  full year
      Mon  : Integer := -1;   --  1 .. 12
      Day  : Integer := -1;
      Hour : Integer := 0;
      Min  : Integer := 0;
      Sec  : Integer := 0;
      Wday : Integer := 0;    --  0 = Sunday
      --  The zone offset (seconds east) the time was last split with:
      --  git's tm_isdst carried along, so a relative move keeps the clock
      --  reading of the moment it started from even across a DST change.
      Offset : Long_Long_Integer := 0;
   end record;

   Epoch : constant Ada.Calendar.Time :=
     Ada.Calendar.Formatting.Time_Of
       (1970, 1, 1, 0, 0, 0, Time_Zone => 0);

   function To_Time (U : Long_Long_Integer) return Ada.Calendar.Time is
     (Epoch + Duration (U));

   --  Days since 1970-01-01 of a proleptic Gregorian date (any month/day
   --  overflow is carried, as mktime does).
   function Days_From_Civil (Y0, M0, D : Integer) return Long_Long_Integer is
      Y   : Integer := Y0;
      M   : Integer := M0;
   begin
      while M > 12 loop
         M := M - 12;
         Y := Y + 1;
      end loop;
      while M < 1 loop
         M := M + 12;
         Y := Y - 1;
      end loop;
      declare
         YY  : constant Long_Long_Integer :=
           Long_Long_Integer (if M <= 2 then Y - 1 else Y);
         Era : constant Long_Long_Integer :=
           (if YY >= 0 then YY else YY - 399) / 400;
         YOE : constant Long_Long_Integer := YY - Era * 400;
         MP  : constant Long_Long_Integer :=
           Long_Long_Integer (if M > 2 then M - 3 else M + 9);
         DOY : constant Long_Long_Integer := (153 * MP + 2) / 5 + 1 - 1;
         DOE : constant Long_Long_Integer :=
           YOE * 365 + YOE / 4 - YOE / 100 + DOY;
      begin
         return Era * 146_097 + DOE - 719_468 + Long_Long_Integer (D - 1);
      end;
   end Days_From_Civil;

   procedure Civil_From_Days
     (Days : Long_Long_Integer; Y, M, D : out Integer)
   is
      Z   : constant Long_Long_Integer := Days + 719_468;
      Era : constant Long_Long_Integer :=
        (if Z >= 0 then Z else Z - 146_096) / 146_097;
      DOE : constant Long_Long_Integer := Z - Era * 146_097;
      YOE : constant Long_Long_Integer :=
        (DOE - DOE / 1_460 + DOE / 36_524 - DOE / 146_096) / 365;
      DOY : constant Long_Long_Integer :=
        DOE - (365 * YOE + YOE / 4 - YOE / 100);
      MP  : constant Long_Long_Integer := (5 * DOY + 2) / 153;
   begin
      D := Integer (DOY - (153 * MP + 2) / 5 + 1);
      M := Integer (if MP < 10 then MP + 3 else MP - 9);
      Y := Integer (YOE + Era * 400 + (if M <= 2 then 1 else 0));
   end Civil_From_Days;

   --  The local UTC offset, in seconds, in force at unix time U.
   function Local_Offset (U : Long_Long_Integer) return Long_Long_Integer is
   begin
      return Long_Long_Integer
        (Ada.Calendar.Time_Zones.UTC_Time_Offset (To_Time (U))) * 60;
   exception
      when others =>
         return 0;
   end Local_Offset;

   --  timegm: the broken-down time read as UTC.
   function To_Unix_UTC (B : Broken) return Long_Long_Integer is
     (Days_From_Civil (B.Year, B.Mon, B.Day) * 86_400
      + Long_Long_Integer (B.Hour) * 3_600
      + Long_Long_Integer (B.Min) * 60
      + Long_Long_Integer (B.Sec));

   --  mktime with tm_isdst = -1: the broken-down time read in the local
   --  zone, with the offset that applies at the resulting instant.
   function Mktime (B : Broken) return Long_Long_Integer is
      Naive : constant Long_Long_Integer := To_Unix_UTC (B);
      Off   : constant Long_Long_Integer := Local_Offset (Naive);
      Again : constant Long_Long_Integer := Local_Offset (Naive - Off);
   begin
      return Naive - Again;
   end Mktime;

   --  mktime with the tm_isdst the time was split with: the offset it
   --  carries, whatever the target date's own would be.
   function Mktime_Carried (B : Broken) return Long_Long_Integer is
     (To_Unix_UTC (B) - B.Offset);

   procedure Localtime (U : Long_Long_Integer; B : out Broken) is
      Off  : constant Long_Long_Integer := Local_Offset (U);
      L    : constant Long_Long_Integer := U + Off;
      Days : Long_Long_Integer := L / 86_400;
      Secs : Long_Long_Integer := L mod 86_400;
   begin
      if Secs < 0 then
         Secs := Secs + 86_400;
         Days := Days - 1;
      end if;
      Civil_From_Days (Days, B.Year, B.Mon, B.Day);
      B.Hour := Integer (Secs / 3_600);
      B.Min  := Integer ((Secs mod 3_600) / 60);
      B.Sec  := Integer (Secs mod 60);
      B.Wday := Integer ((Days + 4) mod 7);
      if B.Wday < 0 then
         B.Wday := B.Wday + 7;
      end if;
      B.Offset := Off;
   end Localtime;

   --  update_tm: complete the unset date fields from Now, move Sec seconds
   --  into the past, and renormalize.
   function Update_Tm
     (Tm : in out Broken; Now : Broken; Sec : Long_Long_Integer)
      return Long_Long_Integer
   is
      N   : Long_Long_Integer;
      Back : Long_Long_Integer := Sec;
   begin
      if Tm.Day < 0 then
         --  Day = -2 is date_time's "that hour has not come yet today"
         --  marker: a plain completion steps back one day for it.
         if Sec = 0 and then Tm.Day + 1 < 0 then
            Back := Long_Long_Integer (-(Tm.Day + 1)) * 86_400;
         end if;
         Tm.Day := Now.Day;
      end if;
      if Tm.Mon < 0 then
         Tm.Mon := Now.Mon;
      end if;
      if Tm.Year < 0 then
         Tm.Year := Now.Year;
         if Tm.Mon > Now.Mon then
            Tm.Year := Tm.Year - 1;
         end if;
      end if;
      N := Mktime_Carried (Tm) - Back;
      Localtime (N, Tm);
      return N;
   end Update_Tm;

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');
   function Is_Alpha (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z');
   function Is_Alnum (C : Character) return Boolean is
     (Is_Digit (C) or else Is_Alpha (C));

   --  match_string: how many leading characters of Text (from I) agree
   --  with Word, case-insensitively; 0 on a mismatch, the count when the
   --  text ends or hits a non-alphanumeric first.
   function Match_String (Text : String; I : Positive; Word : String)
     return Natural
   is
      N : Natural := 0;
      K : Natural := I;
      W : Natural := Word'First;
   begin
      while K <= Text'Last loop
         if W <= Word'Last
           and then Ada.Characters.Handling.To_Upper (Text (K))
                    = Ada.Characters.Handling.To_Upper (Word (W))
         then
            null;
         elsif not Is_Alnum (Text (K)) then
            return N;
         else
            return 0;
         end if;
         N := N + 1;
         K := K + 1;
         W := W + 1;
      end loop;
      return N;
   end Match_String;

   Month_Names : constant array (1 .. 12) of String (1 .. 9) :=
     ["January  ", "February ", "March    ", "April    ", "May      ",
      "June     ", "July     ", "August   ", "September", "October  ",
      "November ", "December "];
   Weekday_Names : constant array (0 .. 6) of String (1 .. 10) :=
     ["Sundays   ", "Mondays   ", "Tuesdays  ", "Wednesdays", "Thursdays ",
      "Fridays   ", "Saturdays "];
   Number_Names : constant array (1 .. 10) of String (1 .. 5) :=
     ["one  ", "two  ", "three", "four ", "five ", "six  ", "seven",
      "eight", "nine ", "ten  "];

   function Trimmed (S : String) return String is
      Last : Natural := S'Last;
   begin
      while Last >= S'First and then S (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return S (S'First .. Last);
   end Trimmed;

   --  is_date: accept year/month/day when they make a date (a two-digit
   --  year lands in 1970 .. 2037) that is not more than ten days ahead of
   --  Now (git refuses timestamps "way into the future").
   function Is_Date
     (Year, Month, Day : Integer;
      Now_U            : Long_Long_Integer;
      Check_Future     : Boolean;
      Tm               : in out Broken) return Boolean
   is
      Y : Integer;
   begin
      if Month <= 0 or else Month > 12 or else Day <= 0 or else Day > 31 then
         return False;
      end if;
      if Year = -1 then
         Y := -1;
      elsif Year >= 1970 and then Year < 2100 then
         Y := Year;
      elsif Year > 70 and then Year < 100 then
         Y := 1900 + Year;
      elsif Year < 38 then
         Y := 2000 + Year;
      else
         return False;
      end if;

      if Check_Future then
         declare
            Probe : Broken := Tm;
            Now_B : Broken;
         begin
            Localtime (Now_U, Now_B);
            Probe.Mon := Month;
            Probe.Day := Day;
            Probe.Year := (if Y = -1 then Now_B.Year else Y);
            if To_Unix_UTC (Probe) > Now_U + 10 * 86_400 then
               return False;
            end if;
         end;
      end if;

      Tm.Mon := Month;
      Tm.Day := Day;
      if Y /= -1 then
         Tm.Year := Y;
      end if;
      return True;
   end Is_Date;

   --  Digits from I; Last is the index of the final digit.
   function Read_Number
     (Text : String; I : Positive; Last : out Natural) return Long_Long_Integer
   is
      N : Long_Long_Integer := 0;
      K : Natural := I;
   begin
      while K <= Text'Last and then Is_Digit (Text (K)) loop
         if N < 10_000_000_000 then
            N := N * 10 + Long_Long_Integer
              (Character'Pos (Text (K)) - Character'Pos ('0'));
         end if;
         K := K + 1;
      end loop;
      Last := K - 1;
      return N;
   end Read_Number;

   --  match_multi_number: "num<c>num2[<c>num3]" as a time (':') or a date
   --  ('-', '/', '.').  Returns the index past the match, 0 for no match.
   function Match_Multi_Number
     (Num   : Long_Long_Integer;
      C     : Character;
      Text  : String;
      After : Positive;   --  index of the separator
      Tm    : in out Broken;
      Now_U : Long_Long_Integer) return Natural
   is
      L2, L3 : Natural;
      Num2   : constant Long_Long_Integer := Read_Number (Text, After + 1, L2);
      Num3   : Long_Long_Integer := -1;
      Stop   : Natural := L2;
   begin
      if L2 + 1 <= Text'Last and then Text (L2 + 1) = C
        and then L2 + 2 <= Text'Last and then Is_Digit (Text (L2 + 2))
      then
         Num3 := Read_Number (Text, L2 + 2, L3);
         Stop := L3;
      end if;

      case C is
         when ':' =>
            if Num3 < 0 then
               Num3 := 0;
            end if;
            if Num < 25 and then Num2 >= 0 and then Num2 < 60
              and then Num3 >= 0 and then Num3 <= 60
            then
               Tm.Hour := Integer (Num);
               Tm.Min := Integer (Num2);
               Tm.Sec := Integer (Num3);
               return Stop + 1;
            end if;
            return 0;
         when others =>
            declare
               N1 : constant Integer := Integer (Num);
               N2 : constant Integer := Integer (Num2);
               N3 : constant Integer := Integer (Num3);
            begin
               if N1 > 70 then
                  --  yyyy-mm-dd, then yyyy-dd-mm.
                  if Is_Date (N1, N2, N3, Now_U, False, Tm)
                    or else Is_Date (N1, N3, N2, Now_U, False, Tm)
                  then
                     return Stop + 1;
                  end if;
               end if;
               --  mm/dd/yy[yy] unless the separator is '.', then the
               --  European dd.mm.yy[yy], then the funny mm.dd.yy.
               if C /= '.' and then Is_Date (N3, N1, N2, Now_U, True, Tm) then
                  return Stop + 1;
               end if;
               if Is_Date (N3, N2, N1, Now_U, True, Tm) then
                  return Stop + 1;
               end if;
               if C = '.' and then Is_Date (N3, N1, N2, Now_U, True, Tm) then
                  return Stop + 1;
               end if;
               return 0;
            end;
      end case;
   end Match_Multi_Number;

   --  pending_number: a bare number fills the first unset field it fits --
   --  day of month, then month, then year.
   procedure Pending_Number (Tm : in out Broken; Num : in out Integer) is
      N : constant Integer := Num;
   begin
      if N = 0 then
         return;
      end if;
      Num := 0;
      if Tm.Day < 0 and then N < 32 then
         Tm.Day := N;
      elsif Tm.Mon < 0 and then N < 13 then
         Tm.Mon := N;
      elsif Tm.Year < 0 then
         if N > 1969 and then N < 2100 then
            Tm.Year := N;
         elsif N > 69 and then N < 100 then
            Tm.Year := 1900 + N;
         elsif N < 38 then
            Tm.Year := 2000 + N;
         end if;
      end if;
   end Pending_Number;

   --  approxidate_digit: a number at I; returns the index past it.
   function Digit
     (Text  : String;
      I     : Positive;
      Tm    : in out Broken;
      Num   : in out Integer;
      Now_U : Long_Long_Integer) return Positive
   is
      Last   : Natural;
      Number : constant Long_Long_Integer := Read_Number (Text, I, Last);
      Next   : constant Character :=
        (if Last + 1 <= Text'Last then Text (Last + 1) else ' ');
   begin
      if Next in ':' | '.' | '/' | '-'
        and then Last + 2 <= Text'Last and then Is_Digit (Text (Last + 2))
      then
         declare
            M : constant Natural :=
              Match_Multi_Number (Number, Next, Text, Last + 1, Tm, Now_U);
         begin
            if M > 0 then
               return M;
            end if;
         end;
      end if;
      --  Zero padding only for small numbers ("Dec 02", never "Dec 0002").
      if Text (I) /= '0' or else Last - I + 1 <= 2 then
         Num := Integer (Long_Long_Integer'Min (Number, 100_000));
      end if;
      return Last + 1;
   end Digit;

   --  date_time: a named hour; with no day chosen yet and that hour still
   --  ahead, the most recent one was yesterday (Day = -2 tells Update_Tm).
   procedure Date_Time (Tm : in out Broken; Hour : Integer) is
   begin
      if Tm.Day < 0 and then Tm.Hour < Hour then
         Tm.Day := -2;
      end if;
      Tm.Hour := Hour;
      Tm.Min := 0;
      Tm.Sec := 0;
   end Date_Time;

   --  approxidate_alpha: a word at I; returns the index past it.
   function Alpha
     (Text    : String;
      I       : Positive;
      Tm      : in out Broken;
      Now     : Broken;
      Num     : in out Integer;
      Touched : in out Boolean) return Positive
   is
      Stop  : Natural := I;
      Dummy : Long_Long_Integer;
   begin
      while Stop <= Text'Last and then Is_Alpha (Text (Stop)) loop
         Stop := Stop + 1;
      end loop;

      for M in Month_Names'Range loop
         if Match_String (Text, I, Trimmed (Month_Names (M))) >= 3 then
            Tm.Mon := M;
            Touched := True;
            return Stop;
         end if;
      end loop;

      declare
         function Special (Word : String) return Boolean is
           (Match_String (Text, I, Word) = Word'Length);
      begin
         if Special ("yesterday") then
            Num := 0;
            Tm.Day := -1;
            Dummy := Update_Tm (Tm, Now, 86_400);
            Touched := True;
            return Stop;
         elsif Special ("today") then
            if Tm.Hour = Now.Hour and then Tm.Min = Now.Min
              and then Tm.Sec = Now.Sec
            then
               Date_Time (Tm, 0);
            end if;
            Num := 0;
            Tm.Day := -1;
            Dummy := Update_Tm (Tm, Now, 0);
            Touched := True;
            return Stop;
         elsif Special ("midnight") then
            Pending_Number (Tm, Num);
            Date_Time (Tm, 0);
            Touched := True;
            return Stop;
         elsif Special ("noon") then
            Pending_Number (Tm, Num);
            Date_Time (Tm, 12);
            Touched := True;
            return Stop;
         elsif Special ("tea") then
            Pending_Number (Tm, Num);
            Date_Time (Tm, 17);
            Touched := True;
            return Stop;
         elsif Special ("PM") or else Special ("AM") then
            declare
               Hour : Integer := Tm.Hour;
            begin
               if Num /= 0 then
                  Hour := Num;
                  Num := 0;
                  Tm.Min := 0;
                  Tm.Sec := 0;
               end if;
               Tm.Hour :=
                 (if Special ("PM") then (Hour mod 12) + 12 else Hour mod 12);
            end;
            Touched := True;
            return Stop;
         elsif Special ("never") then
            Localtime (0, Tm);
            Num := 0;
            Touched := True;
            return Stop;
         elsif Special ("now") then
            Num := 0;
            Dummy := Update_Tm (Tm, Now, 0);
            Touched := True;
            return Stop;
         end if;
      end;

      if Num = 0 then
         for K in Number_Names'Range loop
            declare
               Name : constant String := Trimmed (Number_Names (K));
            begin
               if Match_String (Text, I, Name) = Name'Length then
                  Num := K;
                  Touched := True;
                  return Stop;
               end if;
            end;
         end loop;
         if Match_String (Text, I, "last") = 4 then
            Num := 1;
            Touched := True;
         end if;
         return Stop;
      end if;

      declare
         type Unit is record
            Name   : String (1 .. 7);
            Length : Long_Long_Integer;
         end record;
         Units : constant array (1 .. 5) of Unit :=
           [("seconds", 1), ("minutes", 60), ("hours  ", 3_600),
            ("days   ", 86_400), ("weeks  ", 604_800)];
      begin
         for U of Units loop
            declare
               Name : constant String := Trimmed (U.Name);
            begin
               if Match_String (Text, I, Name) >= Name'Length - 1 then
                  Dummy :=
                    Update_Tm (Tm, Now, U.Length * Long_Long_Integer (Num));
                  Num := 0;
                  Touched := True;
                  return Stop;
               end if;
            end;
         end loop;
      end;

      for W in Weekday_Names'Range loop
         if Match_String (Text, I, Trimmed (Weekday_Names (W))) >= 3 then
            declare
               Diff : Integer := Tm.Wday - W;
               N    : Integer := Num - 1;
            begin
               Num := 0;
               if Diff <= 0 then
                  N := N + 1;
               end if;
               Diff := Diff + 7 * N;
               Dummy := Update_Tm (Tm, Now, Long_Long_Integer (Diff) * 86_400);
               Touched := True;
               return Stop;
            end;
         end if;
      end loop;

      if Match_String (Text, I, "months") >= 5 then
         declare
            Diff : constant Integer := Num;
         begin
            Num := 0;
            Dummy := Update_Tm (Tm, Now, 0);
            Tm.Mon := Tm.Mon - Diff;
            while Tm.Mon < 1 loop
               Tm.Mon := Tm.Mon + 12;
               Tm.Year := Tm.Year - 1;
            end loop;
            Touched := True;
            return Stop;
         end;
      end if;

      if Match_String (Text, I, "years") >= 4 then
         Dummy := Update_Tm (Tm, Now, 0);
         Tm.Year := Tm.Year - Num;
         Num := 0;
         Touched := True;
         return Stop;
      end if;

      return Stop;
   end Alpha;

   --  parse_date_basic's strict forms: "@<unix>", a bare unix time (nine or
   --  more digits), "<unix> <±HHMM>", ISO 8601 (date, optional 'T'/space
   --  time, optional zone), RFC 2822 and "D Mon YYYY [HH:MM:SS] [zone]".
   --  Without a zone the local one applies, as git does.
   function Parse_Basic
     (Text   : String;
      Result : out Long_Long_Integer) return Boolean
   is
      Tm       : Broken;
      Have_Y, Have_M, Have_D, Have_Time : Boolean := False;
      Offset   : Long_Long_Integer := 0;
      Have_Off : Boolean := False;
      I        : Positive := Text'First;

      procedure Skip_Blanks is
      begin
         while I <= Text'Last and then Text (I) in ' ' | ',' | ASCII.HT loop
            I := I + 1;
         end loop;
      end Skip_Blanks;
   begin
      Result := 0;
      if Text'Length = 0 then
         return False;
      end if;

      --  "@<unix>" and a bare unix time.
      declare
         S : constant Natural :=
           (if Text (Text'First) = '@' then Text'First + 1 else Text'First);
         Last : Natural;
         N    : Long_Long_Integer;
      begin
         if S <= Text'Last and then Is_Digit (Text (S)) then
            N := Read_Number (Text, S, Last);
            if Last = Text'Last
              and then (Text (Text'First) = '@' or else Last - S + 1 >= 9)
            then
               Result := N;
               return True;
            end if;
            if Last - S + 1 >= 9 and then Last + 1 < Text'Last
              and then Text (Last + 1) = ' '
              and then Text (Last + 2) in '+' | '-'
              and then Last + 6 = Text'Last
            then
               Result := N;
               return True;
            end if;
         end if;
      end;

      Tm.Hour := 0;
      Tm.Min := 0;
      Tm.Sec := 0;

      while I <= Text'Last loop
         Skip_Blanks;
         exit when I > Text'Last;
         if Is_Digit (Text (I)) then
            declare
               Last : Natural;
               N    : constant Long_Long_Integer := Read_Number (Text, I, Last);
               Next : constant Character :=
                 (if Last + 1 <= Text'Last then Text (Last + 1) else ' ');
            begin
               if Next = '-' and then Last + 2 <= Text'Last
                 and then Is_Digit (Text (Last + 2)) and then Last - I + 1 = 4
               then
                  --  YYYY-MM-DD
                  declare
                     L2, L3 : Natural;
                     M : constant Long_Long_Integer :=
                       Read_Number (Text, Last + 2, L2);
                     D : Long_Long_Integer := 0;
                  begin
                     if L2 + 1 <= Text'Last and then Text (L2 + 1) = '-'
                       and then L2 + 2 <= Text'Last
                       and then Is_Digit (Text (L2 + 2))
                     then
                        D := Read_Number (Text, L2 + 2, L3);
                     else
                        return False;
                     end if;
                     if M < 1 or else M > 12 or else D < 1 or else D > 31 then
                        return False;
                     end if;
                     Tm.Year := Integer (N);
                     Tm.Mon := Integer (M);
                     Tm.Day := Integer (D);
                     Have_Y := True;
                     Have_M := True;
                     Have_D := True;
                     I := L3 + 1;
                     if I <= Text'Last and then Text (I) = 'T' then
                        I := I + 1;
                     end if;
                  end;
               elsif Next = ':' then
                  --  HH:MM[:SS][.frac]
                  declare
                     L2, L3 : Natural;
                     Mi : constant Long_Long_Integer :=
                       Read_Number (Text, Last + 2, L2);
                     S  : Long_Long_Integer := 0;
                  begin
                     if L2 < Last + 2 or else N > 24 or else Mi > 59 then
                        return False;
                     end if;
                     L3 := L2;
                     if L2 + 1 <= Text'Last and then Text (L2 + 1) = ':'
                       and then L2 + 2 <= Text'Last
                       and then Is_Digit (Text (L2 + 2))
                     then
                        S := Read_Number (Text, L2 + 2, L3);
                        if S > 60 then
                           return False;
                        end if;
                     end if;
                     if L3 + 1 <= Text'Last and then Text (L3 + 1) = '.' then
                        declare
                           L4 : Natural;
                           F  : constant Long_Long_Integer :=
                             Read_Number (Text, L3 + 2, L4);
                           pragma Unreferenced (F);
                        begin
                           L3 := L4;
                        end;
                     end if;
                     Tm.Hour := Integer (N);
                     Tm.Min := Integer (Mi);
                     Tm.Sec := Integer (S);
                     Have_Time := True;
                     I := L3 + 1;
                  end;
               elsif Last - I + 1 = 8 and then not Have_Y then
                  --  Compact ISO 8601: YYYYMMDD, maybe followed by
                  --  T[HH[MM[SS]]].
                  declare
                     M : constant Long_Long_Integer := (N / 100) mod 100;
                     D : constant Long_Long_Integer := N mod 100;
                  begin
                     if M < 1 or else M > 12 or else D < 1 or else D > 31 then
                        return False;
                     end if;
                     Tm.Year := Integer (N / 10_000);
                     Tm.Mon := Integer (M);
                     Tm.Day := Integer (D);
                     Have_Y := True;
                     Have_M := True;
                     Have_D := True;
                     I := Last + 1;
                     if I < Text'Last and then Text (I) = 'T'
                       and then Is_Digit (Text (I + 1))
                     then
                        declare
                           L2 : Natural;
                           T  : constant Long_Long_Integer :=
                             Read_Number (Text, I + 1, L2);
                           W  : constant Natural := L2 - I;
                        begin
                           case W is
                              when 6 =>
                                 Tm.Hour := Integer (T / 10_000);
                                 Tm.Min := Integer ((T / 100) mod 100);
                                 Tm.Sec := Integer (T mod 100);
                              when 4 =>
                                 Tm.Hour := Integer (T / 100);
                                 Tm.Min := Integer (T mod 100);
                                 Tm.Sec := 0;
                              when 2 =>
                                 Tm.Hour := Integer (T);
                                 Tm.Min := 0;
                                 Tm.Sec := 0;
                              when others =>
                                 return False;
                           end case;
                           if Tm.Hour > 24 or else Tm.Min > 59
                             or else Tm.Sec > 60
                           then
                              return False;
                           end if;
                           Have_Time := True;
                           I := L2 + 1;
                        end;
                     end if;
                  end;
               elsif Last - I + 1 = 4 and then not Have_Y then
                  Tm.Year := Integer (N);
                  Have_Y := True;
                  I := Last + 1;
               elsif N >= 1 and then N <= 31 and then not Have_D then
                  Tm.Day := Integer (N);
                  Have_D := True;
                  I := Last + 1;
               else
                  return False;
               end if;
            end;
         elsif Text (I) in '+' | '-' and then I < Text'Last
           and then Is_Digit (Text (I + 1))
         then
            --  ±HHMM, ±HH:MM, ±HH
            declare
               Sign : constant Long_Long_Integer :=
                 (if Text (I) = '-' then -1 else 1);
               Last : Natural;
               N    : constant Long_Long_Integer :=
                 Read_Number (Text, I + 1, Last);
               HH, MM : Long_Long_Integer;
            begin
               if Last - I = 4 then
                  HH := N / 100;
                  MM := N mod 100;
               elsif Last - I = 2 then
                  HH := N;
                  MM := 0;
                  if Last + 1 <= Text'Last and then Text (Last + 1) = ':' then
                     declare
                        L2 : Natural;
                     begin
                        MM := Read_Number (Text, Last + 2, L2);
                        Last := L2;
                     end;
                  end if;
               else
                  return False;
               end if;
               Offset := Sign * (HH * 3_600 + MM * 60);
               Have_Off := True;
               I := Last + 1;
            end;
         elsif Text (I) = 'Z' and then I = Text'Last then
            Offset := 0;
            Have_Off := True;
            I := I + 1;
         elsif Is_Alpha (Text (I)) then
            declare
               Stop : Natural := I;
               Done : Boolean := False;
            begin
               while Stop <= Text'Last and then Is_Alpha (Text (Stop)) loop
                  Stop := Stop + 1;
               end loop;
               if Match_String (Text, I, "GMT") = 3
                 or else Match_String (Text, I, "UTC") = 3
               then
                  Offset := 0;
                  Have_Off := True;
                  Done := True;
               end if;
               if not Done then
                  for M in Month_Names'Range loop
                     if Match_String (Text, I, Trimmed (Month_Names (M))) >= 3
                     then
                        Tm.Mon := M;
                        Have_M := True;
                        Done := True;
                        exit;
                     end if;
                  end loop;
               end if;
               if not Done then
                  for W in Weekday_Names'Range loop
                     if Match_String (Text, I, Trimmed (Weekday_Names (W)))
                        >= 3
                     then
                        Done := True;   --  a weekday name is decoration
                        exit;
                     end if;
                  end loop;
               end if;
               if not Done then
                  return False;
               end if;
               I := Stop;
            end;
         else
            return False;
         end if;
      end loop;

      if not (Have_Y and then Have_M and then Have_D) then
         return False;
      end if;

      --  Without a time of day git's strict parser gives up (its
      --  tm_to_time_t refuses an unset hour) and the loose one takes over,
      --  keeping the clock's time of day.
      if not Have_Time then
         return False;
      end if;

      if Have_Off then
         Result := To_Unix_UTC (Tm) - Offset;
      else
         Result := Mktime (Tm);
      end if;
      return True;
   end Parse_Basic;

   procedure Parse
     (Text       : String;
      Result     : out Long_Long_Integer;
      Recognized : out Boolean;
      Now        : Long_Long_Integer := 0)
   is
      Now_U : constant Long_Long_Integer :=
        (if Now = 0 then Version.Timestamps.Unix_Now else Now);
      Now_B : Broken;
      Tm    : Broken;
      Num   : Integer := 0;
      I     : Positive := Text'First;
   begin
      if Parse_Basic (Text, Result) then
         Recognized := True;
         return;
      end if;

      Localtime (Now_U, Now_B);
      Tm := Now_B;
      Tm.Year := -1;
      Tm.Mon := -1;
      Tm.Day := -1;
      Recognized := False;

      while I <= Text'Last loop
         if Is_Digit (Text (I)) then
            Pending_Number (Tm, Num);
            I := Digit (Text, I, Tm, Num, Now_U);
            Recognized := True;
         elsif Is_Alpha (Text (I)) then
            I := Alpha (Text, I, Tm, Now_B, Num, Recognized);
         else
            I := I + 1;
         end if;
      end loop;
      Pending_Number (Tm, Num);

      Result := Update_Tm (Tm, Now_B, 0);
   end Parse;

   function Value
     (Text : String; Now : Long_Long_Integer := 0) return Long_Long_Integer
   is
      Result     : Long_Long_Integer;
      Recognized : Boolean;
   begin
      Parse (Text, Result, Recognized, Now);
      return Result;
   end Value;

end Version.Approxidate;
