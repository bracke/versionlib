with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Version.Diff;

package body Version.Format_Patch is
   use Version.Objects;

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Trim (N : Long_Long_Integer) return String is
     (Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N), Ada.Strings.Left));

   function Pad2 (N : Long_Long_Integer) return String is
      S : constant String := Trim (N);
   begin
      return (if S'Length = 1 then "0" & S else S);
   end Pad2;

   --  The value of the named header line ("author "/"committer ") in a raw
   --  commit object, or "" when absent.
   function Header_Value (Content, Prefix : String) return String is
      Pos : Natural := Content'First;
   begin
      while Pos <= Content'Last loop
         declare
            EOL : Natural := Content'Last + 1;
         begin
            for K in Pos .. Content'Last loop
               if Content (K) = LF then
                  EOL := K;
                  exit;
               end if;
            end loop;

            exit when Pos = EOL;  --  blank line: headers end

            declare
               Line : constant String := Content (Pos .. EOL - 1);
            begin
               if Line'Length >= Prefix'Length
                 and then Line (Line'First .. Line'First + Prefix'Length - 1)
                          = Prefix
               then
                  return Line (Line'First + Prefix'Length .. Line'Last);
               end if;
            end;

            Pos := EOL + 1;
         end;
      end loop;
      return "";
   end Header_Value;

   --  Format a Unix timestamp + "+HHMM"/"-HHMM" zone as an RFC2822 date in that
   --  zone, e.g. "Thu, 1 Jan 1970 00:00:00 +0000".
   function Format_Date (Ts : Long_Long_Integer; Tz : String) return String is
      Weekday : constant array (0 .. 6) of String (1 .. 3) :=
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      Month   : constant array (1 .. 12) of String (1 .. 3) :=
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

      Sign : constant Long_Long_Integer :=
        (if Tz'Length >= 1 and then Tz (Tz'First) = '-' then -1 else 1);
      HH   : constant Long_Long_Integer :=
        (if Tz'Length >= 3
         then Long_Long_Integer'Value (Tz (Tz'First + 1 .. Tz'First + 2))
         else 0);
      MM   : constant Long_Long_Integer :=
        (if Tz'Length >= 5
         then Long_Long_Integer'Value (Tz (Tz'First + 3 .. Tz'First + 4))
         else 0);

      Local : constant Long_Long_Integer := Ts + Sign * (HH * 3600 + MM * 60);
      Days  : Long_Long_Integer := Local / 86400;
      Secs  : Long_Long_Integer := Local mod 86400;
   begin
      if Secs < 0 then
         Secs := Secs + 86400;
         Days := Days - 1;
      end if;

      declare
         Wd : Integer := Integer ((Days + 4) mod 7);
         Z   : constant Long_Long_Integer := Days + 719468;
         Era : constant Long_Long_Integer :=
           (if Z >= 0 then Z else Z - 146096) / 146097;
         Doe : constant Long_Long_Integer := Z - Era * 146097;
         Yoe : constant Long_Long_Integer :=
           (Doe - Doe / 1460 + Doe / 36524 - Doe / 146096) / 365;
         Y   : Long_Long_Integer := Yoe + Era * 400;
         Doy : constant Long_Long_Integer :=
           Doe - (365 * Yoe + Yoe / 4 - Yoe / 100);
         Mp  : constant Long_Long_Integer := (5 * Doy + 2) / 153;
         D   : constant Long_Long_Integer := Doy - (153 * Mp + 2) / 5 + 1;
         M   : constant Long_Long_Integer := (if Mp < 10 then Mp + 3 else Mp - 9);
      begin
         if Wd < 0 then
            Wd := Wd + 7;
         end if;
         if M <= 2 then
            Y := Y + 1;
         end if;

         return Weekday (Wd) & ", " & Trim (D) & " "
           & Month (Integer (M)) & " " & Trim (Y) & " "
           & Pad2 (Secs / 3600) & ":" & Pad2 ((Secs mod 3600) / 60) & ":"
           & Pad2 (Secs mod 60) & " " & Tz;
      end;
   end Format_Date;

   function Patch_For_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Number    : Positive := 1;
      Total     : Positive := 1)
      return String
   is
      Obj     : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Author  : constant String := Header_Value (Content, "author ");

      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Obj);

      --  format-patch implies git's --binary, so a binary change travels as
      --  an appliable patch rather than a "differ" line.
      Bin_Opts : constant Version.Diff.Diff_Options :=
        (Binary_Patch => True, others => <>);

      Diff : constant String :=
        (if Parents.Is_Empty
         then Version.Diff.Diff_Root_Commit (Repo, Commit_Id, Bin_Opts)
         else Version.Diff.Diff_Commits
                (Repo, Parents.First_Element, Commit_Id, Bin_Opts));

      --  git format-patch puts a diffstat + summary block between the "---"
      --  line and the patch body (the same content as `git diff --stat
      --  --summary`).
      Stat_Opts : constant Version.Diff.Diff_Options :=
        (Stat => True, Summary => True, others => <>);
      Stat : constant String :=
        (if Parents.Is_Empty
         then Version.Diff.Diff_Root_Commit (Repo, Commit_Id, Stat_Opts)
         else Version.Diff.Diff_Commits
                (Repo, Parents.First_Element, Commit_Id, Stat_Opts));

      --  Split "Name <email> <ts> <tz>".
      Last_GT : Natural := 0;
      Result  : Unbounded_String;
   begin
      for I in reverse Author'Range loop
         if Author (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;

      declare
         Name_Email : constant String :=
           (if Last_GT = 0 then Author else Author (Author'First .. Last_GT));
         Date_Field : constant String :=
           (if Last_GT = 0 or else Last_GT + 2 > Author'Last then ""
            else Author (Last_GT + 2 .. Author'Last));  --  "<ts> <tz>"

         Sp        : Natural := 0;
         RFC_Date  : Unbounded_String;

         --  Commit message (after the blank line that ends the headers).
         Msg_Start : Natural := Content'Last + 1;
      begin
         --  RFC2822 date from "<ts> <tz>".
         for I in Date_Field'Range loop
            if Date_Field (I) = ' ' then
               Sp := I;
               exit;
            end if;
         end loop;
         if Sp /= 0 then
            RFC_Date := To_Unbounded_String
              (Format_Date
                 (Long_Long_Integer'Value
                    (Date_Field (Date_Field'First .. Sp - 1)),
                  Date_Field (Sp + 1 .. Date_Field'Last)));
         end if;

         for I in Content'First .. Content'Last - 1 loop
            if Content (I) = LF and then Content (I + 1) = LF then
               Msg_Start := I + 2;
               exit;
            end if;
         end loop;

         declare
            Message : constant String :=
              (if Msg_Start <= Content'Last
               then Content (Msg_Start .. Content'Last) else "");
            NL1     : Natural := Message'Last + 1;
         begin
            for I in Message'Range loop
               if Message (I) = LF then
                  NL1 := I;
                  exit;
               end if;
            end loop;

            declare
               Subject : constant String :=
                 Message (Message'First .. NL1 - 1);
               Rest    : constant String :=
                 (if NL1 <= Message'Last
                  then Message (NL1 + 1 .. Message'Last) else "");
               --  Drop the single blank line separating subject and body.
               Body_Text : constant String :=
                 (if Rest'Length >= 1 and then Rest (Rest'First) = LF
                  then Rest (Rest'First + 1 .. Rest'Last) else Rest);
               Tag : constant String :=
                 (if Total > 1
                  then "[PATCH " & Ada.Strings.Fixed.Trim
                         (Integer'Image (Number), Ada.Strings.Left) & "/"
                       & Ada.Strings.Fixed.Trim
                         (Integer'Image (Total), Ada.Strings.Left) & "]"
                  else "[PATCH]");
            begin
               Append (Result,
                 "From " & To_String (Commit_Id)
                 & " Mon Sep 17 00:00:00 2001" & LF);
               Append (Result, "From: " & Name_Email & LF);
               Append (Result, "Date: " & To_String (RFC_Date) & LF);
               Append (Result, "Subject: " & Tag & " " & Subject & LF);
               Append (Result, "" & LF);

               --  git runs the body straight into the "---" line; no blank
               --  line between them.
               if Body_Text'Length > 0 then
                  Append (Result, Body_Text);
                  if Body_Text (Body_Text'Last) /= LF then
                     Append (Result, LF);
                  end if;
               end if;

               Append (Result, "---" & LF);
               if Stat'Length > 0 then
                  Append (Result, Stat);
                  if Stat (Stat'Last) /= LF then
                     Append (Result, LF);
                  end if;
                  Append (Result, "" & LF);   --  blank line before the diff
               end if;
               Append (Result, Diff);
               if Diff'Length > 0 and then Diff (Diff'Last) /= LF then
                  Append (Result, LF);
               end if;
               Append (Result, "-- " & LF);
               Append (Result, "2.43.0" & LF & LF);
            end;
         end;
      end;

      return To_String (Result);
   end Patch_For_Commit;

end Version.Format_Patch;
