with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.IO_Exceptions;
with Ada.Strings.Hash;
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
      --  git prints "Merge: <p1> <p2> ..." (abbreviated parent ids) right
      --  after the commit line for any commit with two or more parents.
      declare
         Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
           Version.Objects.Commit_Parent_Ids (Obj);
      begin
         if Natural (Parents.Length) >= 2 then
            declare
               Line : Unbounded_String := To_Unbounded_String ("Merge:");
            begin
               for P of Parents loop
                  declare
                     Full_P : constant String := Version.Objects.To_String (P);
                     Abbrev : constant Natural :=
                       Version.Revisions.Unique_Abbrev_Length (Repo, P, 7);
                  begin
                     Append
                       (Line,
                        " " & Full_P (Full_P'First .. Full_P'First + Abbrev - 1));
                  end;
               end loop;
               Append_Line (Result, To_String (Line));
            end;
         end if;
      end;
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

   --  git's default `log` is a full reachability walk over ALL parents in
   --  commit-date order (a priority queue keyed on the committer timestamp),
   --  not a linear follow of the first parent. Walking only the first parent
   --  silently drops every commit reachable solely through a merge's later
   --  parents. Collect_History reproduces git's order: pop the most recent
   --  unseen commit, then enqueue its parents (deduplicated).

   function Commit_Date_Value (Commit_Text : String) return Long_Long_Integer is
      --  The committer line is "Name <email> <epoch> <±HHMM>"; the epoch is
      --  the second-to-last whitespace-separated token.
      Line     : constant String := Line_Value (Commit_Text, "committer ");
      Last_Sp  : Natural := 0;
      Prev_Sp  : Natural := 0;
   begin
      if Line'Length = 0 then
         return 0;
      end if;
      for I in reverse Line'Range loop
         if Line (I) = ' ' then
            if Last_Sp = 0 then
               Last_Sp := I;
            else
               Prev_Sp := I;
               exit;
            end if;
         end if;
      end loop;
      if Prev_Sp = 0 or else Last_Sp <= Prev_Sp then
         return 0;
      end if;
      return Long_Long_Integer'Value (Line (Prev_Sp + 1 .. Last_Sp - 1));
   exception
      when others =>
         return 0;
   end Commit_Date_Value;

   type Walk_Item is record
      Date : Long_Long_Integer := 0;
      Seq  : Natural := 0;
      Id   : Unbounded_String;
   end record;

   function Item_Less (Left, Right : Walk_Item) return Boolean is
     (Left.Date > Right.Date
      or else (Left.Date = Right.Date and then Left.Seq < Right.Seq));
   --  Order the frontier by descending commit date; ties keep insertion
   --  order (Seq is unique, so no two items compare equal).

   package Frontier_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Walk_Item, "<" => Item_Less);

   package Id_Sets is new Ada.Containers.Indefinite_Hashed_Sets
     (Element_Type => String, Hash => Ada.Strings.Hash, Equivalent_Elements =>
        "=");

   package Id_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Unbounded_String);

   function Collect_History
     (Repo      : Version.Repository.Repository_Handle;
      Cache     : in out Version.Object_Cache.Object_Cache;
      Start_Id  : Version.Objects.Hex_Object_Id;
      Max_Count : Natural) return Id_Vectors.Vector
   is
      Shallow  : Version.Shallow_Cache.Shallow_Cache;
      Frontier : Frontier_Sets.Set;
      Visited  : Id_Sets.Set;
      Result   : Id_Vectors.Vector;
      Seq      : Natural := 0;

      procedure Enqueue (Id_Text : String) is
      begin
         if not Version.Objects.Is_Valid_Hex_Object_Id (Id_Text)
           or else Visited.Contains (Id_Text)
         then
            return;
         end if;
         Visited.Insert (Id_Text);
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Cache,
                 Id   => Version.Objects.To_Object_Id (Id_Text));
         begin
            if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
               return;
            end if;
            Seq := Seq + 1;
            Frontier.Insert
              ((Date => Commit_Date_Value (Version.Objects.Content (Obj)),
                Seq  => Seq,
                Id   => To_Unbounded_String (Id_Text)));
         end;
      end Enqueue;
   begin
      Enqueue (To_String (Start_Id));
      while not Frontier.Is_Empty loop
         exit when Max_Count > 0 and then Natural (Result.Length) = Max_Count;
         declare
            Top : constant Walk_Item := Frontier.First_Element;
            Top_Id : constant Version.Objects.Hex_Object_Id :=
              Version.Objects.To_Object_Id (To_String (Top.Id));
         begin
            Frontier.Delete_First;
            Result.Append (Top.Id);
            if not Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Top_Id)
            then
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Object_Cache.Read_Object
                      (Repo => Repo, Cache => Cache, Id => Top_Id);
               begin
                  for P of Version.Objects.Commit_Parent_Ids (Obj) loop
                     Enqueue (Version.Objects.To_String (P));
                  end loop;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Collect_History;

   function To_Commit_List
     (Ids : Id_Vectors.Vector)
      return Version.History.Commit_Id_Vectors.Vector
   is
      Result : Version.History.Commit_Id_Vectors.Vector;
   begin
      --  The internal walker still yields its own id vector; the renderers
      --  now take the shared one.
      for Id of Ids loop
         Result.Append (Version.Objects.To_Object_Id (To_String (Id)));
      end loop;

      return Result;
   end To_Commit_List;

   function Log_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3) return String
   is
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      First   : Boolean := True;
   begin
      for Current_Id of Commits loop
         declare
            Obj        : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Objects, Id => Current_Id);
         begin
            if not First then
               Append_Line (Result, "");
            end if;
            First := False;
            Append
              (Result,
               Format_Commit_With_Cache
                 (Repo           => Repo,
                  Cache          => Objects,
                  Commit_Id      => Current_Id,
                  Show_Signature => Show_Signature));
            if (Stat or else Patch)
              and then Natural (Version.Objects.Commit_Parent_Ids (Obj).Length)
                       < 2
            then
               --  git's --stat/-p: a blank line, then the diffstat or the
               --  patch against the first parent (or the empty tree for a
               --  root commit). Merge commits (two or more parents) produce
               --  no diff by default -- git needs -m/-c/--cc for that.
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
         end;
      end loop;

      return To_String (Result);
   end Log_List_Text;

   function Log_From_Commit
     (Repo           : Version.Repository.Repository_Handle;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3) return String
   is
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Log_List_Text
        (Repo, To_Commit_List (Collect_History
                                 (Repo, Objects, Commit_Id, Max_Count)),
         Show_Signature, Stat, Patch, Context);
   end Log_From_Commit;

   function Log_Oneline_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector) return String
   is
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
   begin
      for Current_Id of Commits loop
         Append_Line
           (Result,
            Format_Commit_Oneline_With_Cache
              (Repo => Repo, Cache => Objects, Commit_Id => Current_Id));
      end loop;

      return To_String (Result);
   end Log_Oneline_List_Text;

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Max_Count : Natural := 0) return String
   is
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Log_Oneline_List_Text
        (Repo, To_Commit_List (Collect_History
                                 (Repo, Objects, Commit_Id, Max_Count)));
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

   function Log_Formatted_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Format  : String;
      Terminate_Records : Boolean := True) return String
   is
      LF      : constant Character := Character'Val (10);
      Result  : Unbounded_String;
      First   : Boolean := True;
   begin
      for Current_Id of Commits loop
         declare
         begin
            if not First and then not Terminate_Records then
               Append (Result, LF);
            end if;
            First := False;
            Append (Result, Version.Pretty_Format.Expand
                              (Repo, Current_Id, Format));
            if Terminate_Records then
               Append (Result, LF);
            end if;
         end;
      end loop;
      return To_String (Result);
   end Log_Formatted_List_Text;

   function Log_Formatted_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String;
      Terminate_Records : Boolean := True;
      Max_Count : Natural := 0) return String
   is
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Log_Formatted_List_Text
        (Repo,
         To_Commit_List (Collect_History
                           (Repo, Objects, Commit_Id, Max_Count)),
         Format, Terminate_Records);
   end Log_Formatted_From_Commit;

end Version.Log;
