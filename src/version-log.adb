with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Revisions;
with Version.Shallow_Cache;
with Version.Ref_Cache;
with Version.Pretty_Format;
with Version.Diff;
with Version.Verify;

package body Version.Log is

   use Ada.Strings.Unbounded;

   function Line_Value (Text : String; Prefix : String) return String is
      Start : Natural := Text'First;
   begin
      while Start <= Text'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            if Stop > Start then
               declare
                  Line : constant String := Text (Start .. Stop - 1);
               begin
                  if Line'Length >= Prefix'Length
                    and then
                      Line (Line'First .. Line'First + Prefix'Length - 1)
                      = Prefix
                  then
                     return Line (Line'First + Prefix'Length .. Line'Last);
                  end if;
               end;
            end if;

            Start := Stop + 1;
         end;
      end loop;

      return "";
   end Line_Value;

   function Message_Body (Text : String) return String is
      Pos : Natural := Text'First;
   begin
      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10)
           and then Pos < Text'Last
           and then Text (Pos + 1) = Character'Val (10)
         then
            if Pos + 2 <= Text'Last then
               return Text (Pos + 2 .. Text'Last);
            else
               return "";
            end if;
         end if;

         Pos := Pos + 1;
      end loop;

      return "";
   end Message_Body;

   function Author_Name_Date (Commit_Text : String) return String is
      Author  : constant String := Line_Value (Commit_Text, "author ");
      Last_GT : Natural := 0;
   begin
      if Author'Length = 0 then
         return "";
      end if;

      for I in reverse Author'Range loop
         if Author (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;

      if Last_GT = 0 or else Last_GT = Author'Last then
         return Author;
      end if;

      return Author (Author'First .. Last_GT);
   end Author_Name_Date;

   function Author_Date (Commit_Text : String) return String is
      Author  : constant String := Line_Value (Commit_Text, "author ");
      Last_GT : Natural := 0;
   begin
      if Author'Length = 0 then
         return "";
      end if;

      for I in reverse Author'Range loop
         if Author (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;

      if Last_GT = 0 or else Last_GT + 2 > Author'Last then
         return "";
      end if;

      return Author (Last_GT + 2 .. Author'Last);
   end Author_Date;

   function Format_Git_Date (Raw : String) return String is
      --  Raw is "<epoch-seconds> <±HHMM>" from a commit author line. Render
      --  git's default log format: "Www Mmm D HH:MM:SS YYYY ±HHMM", with the
      --  day space-padded to width 2 (strftime %e) and the wall clock in the
      --  commit's own timezone.
      Weekdays : constant array (0 .. 6) of String (1 .. 3) :=
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      Months   : constant array (1 .. 12) of String (1 .. 3) :=
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      Sep : Natural := 0;
   begin
      for I in Raw'Range loop
         if Raw (I) = ' ' then
            Sep := I;
            exit;
         end if;
      end loop;
      if Sep = 0 then
         return Raw;
      end if;

      declare
         Tz      : constant String := Raw (Sep + 1 .. Raw'Last);
         Epoch   : Long_Long_Integer;
         Off_Sec : Long_Long_Integer := 0;
      begin
         begin
            Epoch := Long_Long_Integer'Value (Raw (Raw'First .. Sep - 1));
         exception
            when others =>
               return Raw;
         end;

         if Tz'Length = 5
           and then (Tz (Tz'First) = '+' or else Tz (Tz'First) = '-')
         then
            begin
               Off_Sec :=
                 ((Long_Long_Integer'Value (Tz (Tz'First + 1 .. Tz'First + 2))
                   * 60)
                  + Long_Long_Integer'Value (Tz (Tz'First + 3 .. Tz'First + 4)))
                 * 60;
               if Tz (Tz'First) = '-' then
                  Off_Sec := -Off_Sec;
               end if;
            exception
               when others =>
                  return Raw;
            end;
         end if;

         declare
            T         : constant Long_Long_Integer := Epoch + Off_Sec;
            Day_Count : Long_Long_Integer := T / 86_400;
            Secs      : Long_Long_Integer := T mod 86_400;
         begin
            if Secs < 0 then
               Secs := Secs + 86_400;
               Day_Count := Day_Count - 1;
            end if;

            declare
               Wd  : constant Long_Long_Integer := (Day_Count + 4) mod 7;
               Z   : constant Long_Long_Integer := Day_Count + 719_468;
               Era : constant Long_Long_Integer :=
                 (if Z >= 0 then Z else Z - 146_096) / 146_097;
               DOE : constant Long_Long_Integer := Z - Era * 146_097;
               YOE : constant Long_Long_Integer :=
                 (DOE - DOE / 1_460 + DOE / 36_524 - DOE / 146_096) / 365;
               Y0  : constant Long_Long_Integer := YOE + Era * 400;
               DOY : constant Long_Long_Integer :=
                 DOE - (365 * YOE + YOE / 4 - YOE / 100);
               MP  : constant Long_Long_Integer := (5 * DOY + 2) / 153;
               D   : constant Long_Long_Integer := DOY - (153 * MP + 2) / 5 + 1;
               M   : constant Long_Long_Integer :=
                 (if MP < 10 then MP + 3 else MP - 9);
               Y   : constant Long_Long_Integer := Y0 + (if M <= 2 then 1 else 0);
               HH  : constant Long_Long_Integer := Secs / 3_600;
               Mn  : constant Long_Long_Integer := (Secs mod 3_600) / 60;
               Sc  : constant Long_Long_Integer := Secs mod 60;

               function Trim (V : Long_Long_Integer) return String is
                  S : constant String := Long_Long_Integer'Image (V);
               begin
                  return S (S'First + 1 .. S'Last);
               end Trim;

               function Pad2 (V : Long_Long_Integer) return String is
                  D2 : constant String := Trim (V);
               begin
                  return (if D2'Length = 1 then "0" & D2 else D2);
               end Pad2;

               --  git's default log date does not pad the day of month
               --  ("Feb 1", not "Feb  1").
               function Day_Pad (V : Long_Long_Integer) return String is
               begin
                  return Trim (V);
               end Day_Pad;
            begin
               return
                 Weekdays (Natural (Wd)) & " "
                 & Months (Natural (M)) & " "
                 & Day_Pad (D) & " "
                 & Pad2 (HH) & ":" & Pad2 (Mn) & ":" & Pad2 (Sc) & " "
                 & Trim (Y) & " " & Tz;
            end;
         end;
      end;
   end Format_Git_Date;

   procedure Append_Line (Result : in out Unbounded_String; Text : String) is
   begin
      Append (Result, Text);
      Append (Result, Character'Val (10));
   end Append_Line;

   procedure Append_Indented_Message
     (Result : in out Unbounded_String; Message : String)
   is
      Start : Natural := Message'First;
   begin
      if Message'Length = 0 then
         return;
      end if;

      while Start <= Message'Last loop
         declare
            Stop : Natural := Start;
         begin
            while Stop <= Message'Last
              and then Message (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            if Stop = Start then
               Append_Line (Result, "");
            else
               Append_Line (Result, "    " & Message (Start .. Stop - 1));
            end if;

            Start := Stop + 1;
         end;
      end loop;
   end Append_Indented_Message;

   function Format_Commit_Oneline_With_Cache
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Version.Object_Cache.Object_Cache;
      Commit_Id : Version.Objects.Hex_Object_Id) return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Full : constant String := To_String (Commit_Id);
      --  git's `log --oneline` abbreviates to the shortest unique prefix,
      --  floored at 7 (core.abbrev=auto), not a fixed width.
      Abbrev : constant Natural :=
        Version.Revisions.Unique_Abbrev_Length (Repo, Commit_Id, 7);
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      return
        Full (Full'First .. Full'First + Abbrev - 1)
        & " "
        & Version.Objects.Commit_Message_First_Line (Obj);
   end Format_Commit_Oneline_With_Cache;

   function Format_Commit_With_Cache
     (Repo           : Version.Repository.Repository_Handle;
      Cache          : in out Version.Object_Cache.Object_Cache;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Full_Message   : Boolean := False;
      Show_Signature : Boolean := False) return String
   is
      use type Version.Verify.Verify_Result;
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Result  : Unbounded_String;
      Message : constant String :=
        (if Full_Message
         then Message_Body (Content)
         else Version.Objects.Commit_Message_First_Line (Obj));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      Append_Line (Result, "commit " & To_String (Commit_Id));
      if Show_Signature then
         declare
            VR       : Version.Verify.Verify_Result;
            Out_Text : Unbounded_String;
         begin
            Version.Verify.Verify_Object_Reporting
              (Repo, Commit_Id, VR, Out_Text);
            if VR /= Version.Verify.No_Signature then
               Append (Result, To_String (Out_Text));
            end if;
         end;
      end if;
      Append_Line (Result, "Author: " & Author_Name_Date (Content));
      Append_Line
        (Result, "Date:   " & Format_Git_Date (Author_Date (Content)));
      Append_Line (Result, "");
      Append_Indented_Message (Result, Message);

      return To_String (Result);
   end Format_Commit_With_Cache;

   function Format_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False) return String
   is
      Cache : Version.Object_Cache.Object_Cache;
   begin
      return
        Format_Commit_With_Cache
          (Repo         => Repo,
           Cache        => Cache,
           Commit_Id    => Commit_Id,
           Full_Message => Full_Message);
   end Format_Commit;

   function Log_From_Commit
     (Repo           : Version.Repository.Repository_Handle;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3) return String
   is
      Current : Unbounded_String := To_Unbounded_String (To_String (Commit_Id));
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
      First   : Boolean := True;
      Shown   : Natural := 0;
   begin
      while Length (Current) > 0 loop
         exit when Max_Count > 0 and then Shown = Max_Count;
         declare
            Id_Text : constant String := To_String (Current);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt repository: invalid commit id";
            end if;

            declare
               Current_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id (Id_Text);
               Obj        : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object
                   (Repo => Repo, Cache => Objects, Id => Current_Id);
            begin
               if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "object is not a commit: " & To_String (Current_Id);
               end if;

               if not First then
                  Append_Line (Result, "");
               end if;
               First := False;
               Shown := Shown + 1;
               Append
                 (Result,
                  Format_Commit_With_Cache
                    (Repo           => Repo,
                     Cache          => Objects,
                     Commit_Id      => Current_Id,
                     Show_Signature => Show_Signature));
               if Stat or else Patch then
                  --  git's --stat/-p: a blank line, then the diffstat or the
                  --  patch against the first parent (or the empty tree for a
                  --  root commit).
                  declare
                     Parent : constant String :=
                       Version.Objects.Commit_Parent_Id (Obj);
                     Opts : constant Version.Diff.Diff_Options :=
                       (Stat          => Stat,
                        Context_Lines => Context,
                        others        => <>);
                  begin
                     Append_Line (Result, "");
                     if Parent'Length > 0 then
                        Append
                          (Result,
                           Version.Diff.Diff_Commits
                             (Repo,
                              Version.Objects.To_Object_Id (Parent),
                              Current_Id, Opts));
                     else
                        Append
                          (Result,
                           Version.Diff.Diff_Root_Commit
                             (Repo, Current_Id, Opts));
                     end if;
                  end;
               end if;
               if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Current_Id)
               then
                  Current := Null_Unbounded_String;
               else
                  Current :=
                    To_Unbounded_String
                      (Version.Objects.Commit_Parent_Id (Obj));
               end if;
            end;
         end;
      end loop;

      return To_String (Result);
   end Log_From_Commit;

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Max_Count : Natural := 0) return String
   is
      Current : Unbounded_String := To_Unbounded_String (To_String (Commit_Id));
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
      Shown   : Natural := 0;
   begin
      while Length (Current) > 0 loop
         exit when Max_Count > 0 and then Shown = Max_Count;
         declare
            Id_Text : constant String := To_String (Current);
         begin
            if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text) then
               raise Ada.IO_Exceptions.Data_Error
                 with "corrupt repository: invalid commit id";
            end if;

            declare
               Current_Id : constant Version.Objects.Hex_Object_Id :=
                 Version.Objects.To_Object_Id (Id_Text);
               Obj        : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object
                   (Repo => Repo, Cache => Objects, Id => Current_Id);
            begin
               if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object
               then
                  raise Ada.IO_Exceptions.Data_Error
                    with "object is not a commit: " & To_String (Current_Id);
               end if;

               Shown := Shown + 1;
               Append_Line
                 (Result,
                  Format_Commit_Oneline_With_Cache
                    (Repo => Repo, Cache => Objects, Commit_Id => Current_Id));

               if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Current_Id)
               then
                  Current := Null_Unbounded_String;
               else
                  Current :=
                    To_Unbounded_String
                      (Version.Objects.Commit_Parent_Id (Obj));
               end if;
            end;
         end;
      end loop;

      return To_String (Result);
   end Log_Oneline_From_Commit;

   function Log_Head
     (Repo           : Version.Repository.Repository_Handle;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3) return String
   is
      Refs    : Version.Ref_Cache.Ref_Cache;
      Current : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Current'Length = 0 then
         return "No saved history" & Character'Val (10);
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Current) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt repository: invalid commit id";
      end if;

      return Log_From_Commit
        (Repo, Version.Objects.To_Object_Id (Current), Show_Signature,
         Max_Count, Stat, Patch, Context);
   end Log_Head;

   function Log_Oneline_Head
     (Repo      : Version.Repository.Repository_Handle;
      Max_Count : Natural := 0) return String
   is
      Refs    : Version.Ref_Cache.Ref_Cache;
      Current : constant String :=
        Version.Ref_Cache.Current_Commit_Id (Repo => Repo, Cache => Refs);
   begin
      if Current'Length = 0 then
         return "No saved history" & Character'Val (10);
      end if;

      if not Version.Objects.Is_Valid_Hex_Object_Id (Current) then
         raise Ada.IO_Exceptions.Data_Error
           with "corrupt repository: invalid commit id";
      end if;

      return
        Log_Oneline_From_Commit
          (Repo, Version.Objects.To_Object_Id (Current), Max_Count);
   end Log_Oneline_Head;

   function Log_Formatted_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String;
      Terminate_Records : Boolean := True;
      Max_Count : Natural := 0) return String
   is
      LF      : constant Character := Character'Val (10);
      Current : Unbounded_String := To_Unbounded_String (To_String (Commit_Id));
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
      First   : Boolean := True;
      Shown   : Natural := 0;
   begin
      while Length (Current) > 0 loop
         exit when Max_Count > 0 and then Shown = Max_Count;
         declare
            Id_Text    : constant String := To_String (Current);
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (Id_Text);
            Obj        : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Objects, Id => Current_Id);
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
               raise Ada.IO_Exceptions.Data_Error
                 with "object is not a commit: " & Id_Text;
            end if;

            if not First and then not Terminate_Records then
               Append (Result, LF);
            end if;
            First := False;
            Shown := Shown + 1;
            Append (Result, Version.Pretty_Format.Expand
                              (Repo, Current_Id, Format));
            if Terminate_Records then
               Append (Result, LF);
            end if;

            if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Current_Id)
            then
               Current := Null_Unbounded_String;
            else
               Current := To_Unbounded_String
                 (Version.Objects.Commit_Parent_Id (Obj));
            end if;
         end;
      end loop;
      return To_String (Result);
   end Log_Formatted_From_Commit;

end Version.Log;
