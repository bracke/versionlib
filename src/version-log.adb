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
with Version.Refs;
with Version.Ref_Format;
with Version.Notes;
with Version.Log_Graph;
with Ada.Containers.Indefinite_Hashed_Maps;

package body Version.Log is

   use Ada.Strings.Unbounded;

   package Decor_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => String,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   --  Build git's `--decorate` map: commit id -> "HEAD -> main, tag: v2".
   --  Refs are gathered in git's decoration order (the current branch first,
   --  then other branches, then tags, then remotes), each peeled to the commit
   --  it names.
   function Build_Decorations
     (Repo : Version.Repository.Repository_Handle;
      Mode : Decorate_Mode) return Decor_Maps.Map
   is
      Map : Decor_Maps.Map;

      Head : constant Version.Refs.Head_Info :=
        Version.Refs.Read_Head (Repo);
      Head_Branch : constant String :=
        (if Version.Refs.Is_Attached (Head)
         then "refs/heads/" & Version.Refs.Branch_Name (Head) else "");

      procedure Add (Commit_Hex, Label : String) is
      begin
         if Map.Contains (Commit_Hex) then
            Map.Replace (Commit_Hex, Map.Element (Commit_Hex) & ", " & Label);
         else
            Map.Insert (Commit_Hex, Label);
         end if;
      end Add;

      --  The label a ref contributes, per --decorate mode and ref type.
      function Label (Refname : String) return String is
         function Strip (Prefix : String) return String is
           (Refname (Refname'First + Prefix'Length .. Refname'Last));
      begin
         if Mode = Full_Decorate then
            if Refname (Refname'First) = 'r'
              and then Refname'Length >= 10
              and then Refname (Refname'First .. Refname'First + 9)
                       = "refs/tags/"
            then
               return "tag: " & Refname;
            else
               return Refname;
            end if;
         else
            if Refname'Length >= 11
              and then Refname (Refname'First .. Refname'First + 10)
                       = "refs/heads/"
            then
               return Strip ("refs/heads/");
            elsif Refname'Length >= 10
              and then Refname (Refname'First .. Refname'First + 9)
                       = "refs/tags/"
            then
               return "tag: " & Strip ("refs/tags/");
            elsif Refname'Length >= 13
              and then Refname (Refname'First .. Refname'First + 12)
                       = "refs/remotes/"
            then
               return Strip ("refs/remotes/");
            else
               return Refname;
            end if;
         end if;
      end Label;

      procedure Scan (Prefix : String; Skip_Head_Branch : Boolean) is
         Pats : Version.Ref_Format.String_Vectors.Vector;
      begin
         Pats.Append (Prefix);
         for R of Version.Ref_Format.For_Each_Ref
           (Repo, Pats, "%(refname)")
         loop
            if not (Skip_Head_Branch and then R = Head_Branch) then
               begin
                  Add (Version.Objects.To_String
                         (Version.Revisions.Resolve_Commit (Repo, R)),
                       Label (R));
               exception
                  when others => null;
               end;
            end if;
         end loop;
      end Scan;
   begin
      --  Current branch first, shown as "HEAD -> <branch>".
      if Head_Branch /= "" then
         begin
            Add (Version.Objects.To_String
                   (Version.Revisions.Resolve_Commit (Repo, Head_Branch)),
                 "HEAD -> " & Label (Head_Branch));
         exception
            when others => null;
         end;
      end if;
      Scan ("refs/heads", Skip_Head_Branch => True);
      Scan ("refs/tags", Skip_Head_Branch => False);
      Scan ("refs/remotes", Skip_Head_Branch => False);
      return Map;
   end Build_Decorations;

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

   --  The message's first paragraph, verbatim (kept multi-line, NOT folded the
   --  way the oneline subject is): git's short/medium/... show the title with
   --  its own line breaks, ending at the first blank line.
   function Message_Title (Text : String) return String is
      Body_Text  : constant String := Message_Body (Text);
      Line_Start : Natural := Body_Text'First;
      Last_Kept  : Integer := Body_Text'First - 1;
   begin
      while Line_Start <= Body_Text'Last loop
         declare
            Line_End : Natural := Line_Start;
            Blank    : Boolean := True;
         begin
            while Line_End <= Body_Text'Last
              and then Body_Text (Line_End) /= Character'Val (10)
            loop
               if Body_Text (Line_End) /= ' '
                 and then Body_Text (Line_End) /= Character'Val (9)
               then
                  Blank := False;
               end if;
               Line_End := Line_End + 1;
            end loop;
            exit when Blank;
            Last_Kept := Line_End - 1;
            Line_Start := Line_End + 1;
         end;
      end loop;

      if Last_Kept < Body_Text'First then
         return "";
      end if;
      return Body_Text (Body_Text'First .. Last_Kept);
   end Message_Title;

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

   --  The committer counterparts of the two above, used by the full/fuller
   --  formats, which show the committer identity (and, for fuller, date).
   function Committer_Name_Date (Commit_Text : String) return String is
      Committer : constant String := Line_Value (Commit_Text, "committer ");
      Last_GT   : Natural := 0;
   begin
      if Committer'Length = 0 then
         return "";
      end if;
      for I in reverse Committer'Range loop
         if Committer (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;
      if Last_GT = 0 or else Last_GT = Committer'Last then
         return Committer;
      end if;
      return Committer (Committer'First .. Last_GT);
   end Committer_Name_Date;

   function Committer_Date (Commit_Text : String) return String is
      Committer : constant String := Line_Value (Commit_Text, "committer ");
      Last_GT   : Natural := 0;
   begin
      if Committer'Length = 0 then
         return "";
      end if;
      for I in reverse Committer'Range loop
         if Committer (I) = '>' then
            Last_GT := I;
            exit;
         end if;
      end loop;
      if Last_GT = 0 or else Last_GT + 2 > Committer'Last then
         return "";
      end if;
      return Committer (Last_GT + 2 .. Committer'Last);
   end Committer_Date;

   function Format_Git_Date (Raw : String; Mode : String := "") return String is
      --  Raw is "<epoch-seconds> <±HHMM>" from a commit author line. The
      --  default renders git's log format "Www Mmm D HH:MM:SS YYYY ±HHMM";
      --  Mode selects `--date=<mode>` variants (iso/iso-strict/short/raw/unix).
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

      --  These two need no calendar arithmetic.
      if Mode = "raw" then
         return Raw;
      elsif Mode = "unix" then
         return Raw (Raw'First .. Sep - 1);
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
               if Mode = "short" then
                  return Trim (Y) & "-" & Pad2 (M) & "-" & Pad2 (D);
               elsif Mode = "iso" or else Mode = "iso8601" then
                  return
                    Trim (Y) & "-" & Pad2 (M) & "-" & Pad2 (D) & " "
                    & Pad2 (HH) & ":" & Pad2 (Mn) & ":" & Pad2 (Sc)
                    & " " & Tz;
               elsif Mode = "iso-strict" or else Mode = "iso8601-strict" then
                  return
                    Trim (Y) & "-" & Pad2 (M) & "-" & Pad2 (D) & "T"
                    & Pad2 (HH) & ":" & Pad2 (Mn) & ":" & Pad2 (Sc)
                    & (if Tz = "+0000" or else Tz = "-0000" then "Z"
                       elsif Tz'Length = 5
                       then Tz (Tz'First .. Tz'First + 2) & ":"
                            & Tz (Tz'First + 3 .. Tz'Last)
                       else Tz);
               end if;
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
               --  git indents every message line, so a blank line in the body
               --  becomes the 4-space prefix alone, not an empty line.
               Append_Line (Result, "    ");
            else
               Append_Line (Result, "    " & Message (Start .. Stop - 1));
            end if;

            Start := Stop + 1;
         end;
      end loop;
   end Append_Indented_Message;

   function Format_Commit_Oneline_With_Cache
     (Repo          : Version.Repository.Repository_Handle;
      Cache         : in out Version.Object_Cache.Object_Cache;
      Commit_Id     : Version.Objects.Hex_Object_Id;
      With_Parents  : Boolean := False;
      Children_Text : String := "") return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Full : constant String := To_String (Commit_Id);
      --  git's `log --oneline` abbreviates to the shortest unique prefix,
      --  floored at 7 (core.abbrev=auto), not a fixed width.
      Abbrev : constant Natural :=
        Version.Revisions.Unique_Abbrev_Length (Repo, Commit_Id, 7);

      --  --parents inserts the abbreviated parent ids after the commit id.
      function Parents_Text return String is
         Result : Unbounded_String;
      begin
         for P of Version.Objects.Commit_Parent_Ids (Obj) loop
            declare
               PS : constant String := Version.Objects.To_String (P);
               PA : constant Natural :=
                 Version.Revisions.Unique_Abbrev_Length (Repo, P, 7);
            begin
               Append (Result, PS (PS'First .. PS'First + PA - 1) & " ");
            end;
         end loop;
         return To_String (Result);
      end Parents_Text;
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      return
        Full (Full'First .. Full'First + Abbrev - 1)
        & " "
        & (if With_Parents then Parents_Text else "")
        & Children_Text
        & Version.Objects.Commit_Message_First_Line (Obj);
   end Format_Commit_Oneline_With_Cache;

   function Format_Commit_With_Cache
     (Repo           : Version.Repository.Repository_Handle;
      Cache          : in out Version.Object_Cache.Object_Cache;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Full_Message   : Boolean := False;
      Show_Signature : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Date_Mode      : String := "") return String
   is
      use type Version.Verify.Verify_Result;
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Result  : Unbounded_String;
      --  Short shows only the folded subject; every other format shows the
      --  whole message when Full_Message asks for it.
      Show_Body : constant Boolean :=
        Full_Message and then Kind /= Pretty_Short;
      Message : constant String :=
        (if Kind = Pretty_Short
         then Message_Title (Content)
         elsif Show_Body
         then Message_Body (Content)
         else Version.Objects.Commit_Message_First_Line (Obj));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      Append_Line (Result, "commit " & To_String (Commit_Id));

      if Kind = Pretty_Raw then
         --  Raw prints the commit object's own headers verbatim (tree, parent
         --  lines, author/committer with the epoch timestamp), so find the
         --  blank line that ends the header and copy everything before it.
         declare
            Sep : Natural := 0;
         begin
            for I in Content'First .. Content'Last - 1 loop
               if Content (I) = Character'Val (10)
                 and then Content (I + 1) = Character'Val (10)
               then
                  Sep := I;
                  exit;
               end if;
            end loop;
            if Sep >= Content'First then
               Append_Line (Result, Content (Content'First .. Sep - 1));
            end if;
         end;
      else
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
                        Full_P : constant String :=
                          Version.Objects.To_String (P);
                        Abbrev : constant Natural :=
                          Version.Revisions.Unique_Abbrev_Length (Repo, P, 7);
                     begin
                        Append
                          (Line,
                           " "
                           & Full_P (Full_P'First .. Full_P'First + Abbrev - 1));
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

         --  The identity/date lines differ per format: short has the author
         --  only, medium adds the author date, full adds the committer, and
         --  fuller shows both identities with both dates (colon-aligned to 12).
         case Kind is
            when Pretty_Short =>
               Append_Line (Result, "Author: " & Author_Name_Date (Content));
            when Pretty_Medium =>
               Append_Line (Result, "Author: " & Author_Name_Date (Content));
               Append_Line
                 (Result,
                  "Date:   "
                  & Format_Git_Date (Author_Date (Content), Date_Mode));
            when Pretty_Full =>
               Append_Line (Result, "Author: " & Author_Name_Date (Content));
               Append_Line
                 (Result, "Commit: " & Committer_Name_Date (Content));
            when Pretty_Fuller =>
               Append_Line
                 (Result, "Author:     " & Author_Name_Date (Content));
               Append_Line
                 (Result,
                  "AuthorDate: "
                  & Format_Git_Date (Author_Date (Content), Date_Mode));
               Append_Line
                 (Result, "Commit:     " & Committer_Name_Date (Content));
               Append_Line
                 (Result,
                  "CommitDate: "
                  & Format_Git_Date (Committer_Date (Content), Date_Mode));
            when Pretty_Raw =>
               null;
         end case;
      end if;

      Append_Line (Result, "");
      Append_Indented_Message (Result, Message);

      --  git shows the commit's note (from the default notes ref) after the
      --  message, blank-separated and indented like the message -- but the
      --  automatic display is suppressed once an explicit --pretty/--format is
      --  given (Show_Notes carries that), and the raw format never carries it.
      if Full_Message and then Kind /= Pretty_Raw and then Show_Notes then
         declare
            Note : constant String :=
              Version.Notes.Show (Repo, Commit_Id);
            Last : Natural := Note'Last;
         begin
            while Last >= Note'First
              and then Note (Last) = Character'Val (10)
            loop
               Last := Last - 1;
            end loop;
            if Last >= Note'First then
               Append_Line (Result, "");
               Append_Line (Result, "Notes:");
               Append_Indented_Message (Result, Note (Note'First .. Last));
            end if;
         end;
      end if;

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

   --  Shorten the two 40-hex ids of each diff-tree raw line (":<m> <m> <id>
   --  <id> <status>\t<path>") to 7 chars, which is what git log --raw shows.
   function Abbreviate_Raw_Ids (Raw : String) return String is
      Result : Unbounded_String;
      First  : Natural := Raw'First;
      LF     : constant Character := Character'Val (10);
   begin
      while First <= Raw'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Raw'Last and then Raw (Last) /= LF loop
               Last := Last + 1;
            end loop;

            declare
               Line : constant String := Raw (First .. Last - 1);
            begin
               if Line'Length > 0 and then Line (Line'First) = ':' then
                  --  Fields are space-separated up to the tab; abbreviate the
                  --  3rd and 4th (the ids).
                  declare
                     Out_Line : Unbounded_String;
                     P : Natural := Line'First;
                     Field : Natural := 0;
                  begin
                     while P <= Line'Last loop
                        declare
                           E : Natural := P;
                        begin
                           while E <= Line'Last
                             and then Line (E) /= ' '
                             and then Line (E) /= Character'Val (9)
                           loop
                              E := E + 1;
                           end loop;

                           declare
                              Tok : constant String := Line (P .. E - 1);
                           begin
                              Field := Field + 1;
                              if (Field = 3 or else Field = 4)
                                and then Tok'Length >= 7
                              then
                                 Append
                                   (Out_Line,
                                    Tok (Tok'First .. Tok'First + 6));
                              else
                                 Append (Out_Line, Tok);
                              end if;
                              if E <= Line'Last then
                                 Append (Out_Line, Line (E));
                              end if;
                           end;

                           P := E + 1;
                        end;
                     end loop;
                     Append (Result, To_String (Out_Line) & LF);
                  end;
               elsif Line'Length > 0 then
                  Append (Result, Line & LF);
               end if;
            end;

            First := Last + 1;
         end;
      end loop;
      return To_String (Result);
   end Abbreviate_Raw_Ids;

   function Log_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Context        : Natural := 3;
      Oneline        : Boolean := False;
      First_Parent   : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Date_Mode      : String := "") return String
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
            --  The full-header format blank-separates entries; the oneline
            --  form runs them together, as git does.
            if not First and then not Oneline then
               Append_Line (Result, "");
            end if;
            First := False;
            if Oneline then
               Append_Line
                 (Result,
                  Format_Commit_Oneline_With_Cache
                    (Repo => Repo, Cache => Objects, Commit_Id => Current_Id));
            else
               Append
                 (Result,
                  Format_Commit_With_Cache
                    (Repo           => Repo,
                     Cache          => Objects,
                     Commit_Id      => Current_Id,
                     Full_Message   => True,
                     Show_Signature => Show_Signature,
                     Kind           => Kind,
                     Show_Notes     => Show_Notes,
                     Date_Mode      => Date_Mode));
            end if;
            if (Stat or else Patch or else Name_Only or else Name_Status
                or else Numstat or else Shortstat or else Raw)
              and then
                (Natural (Version.Objects.Commit_Parent_Ids (Obj).Length) < 2
                 or else First_Parent)
            then
               --  git's --stat/-p: a blank line, then the diffstat or the
               --  patch against the first parent (or the empty tree for a
               --  root commit). Merge commits (two or more parents) produce
               --  no diff by default -- git needs -m/-c/--cc, or --first-parent
               --  to diff the merge against its first parent.
               declare
                  Parent : constant String :=
                    Version.Objects.Commit_Parent_Id (Obj);
                  Has_Summary : constant Boolean :=
                    Stat or else Name_Only or else Name_Status
                    or else Numstat or else Shortstat or else Raw;
                  --  A summary format (--stat/--name-only/...) and a patch (-p)
                  --  need separate diff passes: Diff_Options suppresses the
                  --  patch body whenever a summary field is set.
                  Summary_Opts : constant Version.Diff.Diff_Options :=
                    (Stat          => Stat,
                     Name_Only     => Name_Only,
                     Name_Status   => Name_Status,
                     Numstat       => Numstat,
                     Shortstat     => Shortstat,
                     Context_Lines => Context,
                     others        => <>);
                  Patch_Opts : constant Version.Diff.Diff_Options :=
                    (Context_Lines => Context, others => <>);
                  --  --raw prints diff-tree's record format, which the
                  --  unified-diff path does not produce; take it from the
                  --  tree diff directly.
                  function Tree_Of (C : Version.Objects.Hex_Object_Id)
                     return Version.Objects.Hex_Object_Id
                  is (Version.Objects.Commit_Tree_Id
                        (Version.Objects.Read_Object (Repo, C)));

                  function Diff_Of (Opts : Version.Diff.Diff_Options)
                     return String
                  is (if Parent'Length > 0
                      then Version.Diff.Diff_Commits
                             (Repo, Version.Objects.To_Object_Id (Parent),
                              Current_Id, Opts)
                      else Version.Diff.Diff_Root_Commit
                             (Repo, Current_Id, Opts));
               begin
                  --  The full header ends with the message, so a separator
                  --  precedes the file changes; the oneline header runs
                  --  straight into them. git leads a diffstat that is followed
                  --  by a patch with "---" rather than a blank line.
                  if not Oneline then
                     if Stat and then Patch then
                        Append_Line (Result, "---");
                     else
                        Append_Line (Result, "");
                     end if;
                  end if;

                  if Has_Summary then
                     if Raw then
                        --  git log --raw abbreviates the two object ids to
                        --  7 hex (its --abbrev default) where diff-tree --raw
                        --  shows them in full.
                        Append
                          (Result,
                           Abbreviate_Raw_Ids
                             ((if Parent'Length > 0
                               then Version.Diff.Raw_Diff_Trees
                                 (Repo,
                                  Tree_Of
                                    (Version.Objects.To_Object_Id (Parent)),
                                  True, Tree_Of (Current_Id), True)
                               else Version.Diff.Raw_Diff_Trees
                                 (Repo, Tree_Of (Current_Id), False,
                                  Tree_Of (Current_Id), True))));
                     else
                        Append (Result, Diff_Of (Summary_Opts));
                     end if;
                  end if;

                  --  git shows the patch after the summary, blank-separated --
                  --  but the name-only/name-status formats replace the patch
                  --  entirely, so -p adds nothing there.
                  if Patch and then not (Name_Only or else Name_Status) then
                     if Has_Summary then
                        Append_Line (Result, "");
                     end if;
                     Append (Result, Diff_Of (Patch_Opts));
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
         Show_Signature => Show_Signature, Stat => Stat, Patch => Patch,
         Context => Context);
   end Log_From_Commit;

   function Log_Oneline_List_Text
     (Repo          : Version.Repository.Repository_Handle;
      Commits       : Version.History.Commit_Id_Vectors.Vector;
      With_Parents  : Boolean := False;
      With_Children : Boolean := False;
      With_Boundary : Boolean := False;
      Decorate      : Decorate_Mode := No_Decorate) return String
   is
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Decor   : constant Decor_Maps.Map :=
        (if Decorate = No_Decorate then Decor_Maps.Empty_Map
         else Build_Decorations (Repo, Decorate));

      --  git's `--children`: the shown commits that list each commit as a
      --  parent. git records a child by prepending it as the (newest-first)
      --  walk reaches it, so iterating Commits in display order and prepending
      --  reproduces its per-commit order.
      Kids : Decor_Maps.Map;

      procedure Build_Children_Map is
         In_Set : Id_Sets.Set;
      begin
         for C of Commits loop
            In_Set.Include (Version.Objects.To_String (C));
         end loop;
         for C of Commits loop
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, C);
               C_Hex : constant String := Version.Objects.To_String (C);
               Ab    : constant Natural :=
                 Version.Revisions.Unique_Abbrev_Length (Repo, C, 7);
               Child : constant String := C_Hex (C_Hex'First .. C_Hex'First + Ab - 1);
            begin
               for P of Version.Objects.Commit_Parent_Ids (Obj) loop
                  declare
                     P_Hex : constant String := Version.Objects.To_String (P);
                  begin
                     if In_Set.Contains (P_Hex) then
                        Kids.Include
                          (P_Hex,
                           Child & " "
                           & (if Kids.Contains (P_Hex) then Kids.Element (P_Hex)
                              else ""));
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end Build_Children_Map;

      procedure Append_Boundary is
         In_Set   : Id_Sets.Set;
         Seen     : Id_Sets.Set;
         Boundary : Version.History.Commit_Id_Vectors.Vector;
      begin
         for C of Commits loop
            In_Set.Include (Version.Objects.To_String (C));
         end loop;
         --  Excluded parents of the shown commits are the boundary.
         for C of Commits loop
            declare
               Obj : constant Version.Objects.Git_Object :=
                 Version.Object_Cache.Read_Object (Repo, Objects, C);
            begin
               for P of Version.Objects.Commit_Parent_Ids (Obj) loop
                  declare
                     P_Hex : constant String := Version.Objects.To_String (P);
                  begin
                     if not In_Set.Contains (P_Hex)
                       and then not Seen.Contains (P_Hex)
                     then
                        Seen.Include (P_Hex);
                        Boundary.Append (P);
                     end if;
                  end;
               end loop;
            end;
         end loop;
         --  git emits them in its priority-queue order: newest date first.
         declare
            function Date_Of (Id : Version.Objects.Hex_Object_Id)
              return Long_Long_Integer
            is (Commit_Date_Value
                  (Version.Objects.Content
                     (Version.Object_Cache.Read_Object (Repo, Objects, Id))));
         begin
            for A in Boundary.First_Index .. Boundary.Last_Index loop
               declare
                  Max : Natural := A;
               begin
                  for B in A + 1 .. Boundary.Last_Index loop
                     if Date_Of (Boundary (B)) > Date_Of (Boundary (Max)) then
                        Max := B;
                     end if;
                  end loop;
                  if Max /= A then
                     declare
                        Tmp : constant Version.Objects.Hex_Object_Id :=
                          Boundary (A);
                     begin
                        Boundary.Replace_Element (A, Boundary (Max));
                        Boundary.Replace_Element (Max, Tmp);
                     end;
                  end if;
               end;
            end loop;
         end;
         for B of Boundary loop
            Append_Line
              (Result,
               "- "
               & Format_Commit_Oneline_With_Cache
                   (Repo => Repo, Cache => Objects, Commit_Id => B));
         end loop;
      end Append_Boundary;

      --  git puts the "(refs)" between the id (and parents) and the subject;
      --  splice it in after the first space that ends the id/parents run.
      function With_Decoration (Line, Hex : String) return String is
      begin
         if not Decor.Contains (Hex) then
            return Line;
         end if;
         declare
            Cut : Natural := Line'First;
         begin
            --  Skip the id and any parent ids (space-separated hex runs); the
            --  subject begins after them. For oneline the id is one token, so
            --  the first space is the split point (parents keep their own).
            while Cut <= Line'Last and then Line (Cut) /= ' ' loop
               Cut := Cut + 1;
            end loop;
            return Line (Line'First .. Cut - 1)
              & " (" & Decor.Element (Hex) & ")"
              & Line (Cut .. Line'Last);
         end;
      end With_Decoration;
   begin
      if With_Children then
         Build_Children_Map;
      end if;

      for Current_Id of Commits loop
         declare
            Hex : constant String := Version.Objects.To_String (Current_Id);
         begin
            Append_Line
              (Result,
               With_Decoration
                 (Format_Commit_Oneline_With_Cache
                    (Repo => Repo, Cache => Objects, Commit_Id => Current_Id,
                     With_Parents  => With_Parents,
                     Children_Text =>
                       (if With_Children and then Kids.Contains (Hex)
                        then Kids.Element (Hex) else "")),
                  Hex));
         end;
      end loop;

      if With_Boundary then
         Append_Boundary;
      end if;

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

   function Log_Graph_Oneline_List_Text
     (Repo          : Version.Repository.Repository_Handle;
      Commits       : Version.History.Commit_Id_Vectors.Vector;
      With_Parents  : Boolean := False;
      With_Children : Boolean := False;
      Decorate      : Decorate_Mode := No_Decorate) return String
   is
      --  Render each commit's oneline content once through the shared path, so
      --  ids/subjects/decorations match `--oneline` exactly, then draw the
      --  graph around it. Boundary output is a distinct graph feature ('o'
      --  nodes) and is not requested here.
      Content : constant String :=
        Log_Oneline_List_Text
          (Repo, Commits,
           With_Parents  => With_Parents,
           With_Children => With_Children,
           With_Boundary => False,
           Decorate      => Decorate);

      Objects : Version.Object_Cache.Object_Cache;
      In_Set  : Id_Sets.Set;
      G       : Version.Log_Graph.Graph;
      Result  : Unbounded_String;

      --  Cursor that hands back Content one newline-terminated line at a time,
      --  in step with the walk (one line per commit).
      Cursor  : Natural := Content'First;

      function Next_Content_Line return String is
         Start : constant Natural := Cursor;
         Stop  : Natural := Cursor;
      begin
         while Stop <= Content'Last and then Content (Stop) /= ASCII.LF loop
            Stop := Stop + 1;
         end loop;
         Cursor := Stop + 1;
         return Content (Start .. Stop - 1);
      end Next_Content_Line;
   begin
      for C of Commits loop
         In_Set.Include (Version.Objects.To_String (C));
      end loop;

      Version.Log_Graph.Init (G);

      for C of Commits loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, C);
            Parents : Version.Objects.Object_Id_Vectors.Vector;
            Step    : Version.Log_Graph.Step;
         begin
            for P of Version.Objects.Commit_Parent_Ids (Obj) loop
               if In_Set.Contains (Version.Objects.To_String (P)) then
                  Parents.Append (P);
               end if;
            end loop;

            Step := Version.Log_Graph.Advance (G, C, Parents);

            for L of Step.Pre_Lines loop
               Append (Result, L & ASCII.LF);
            end loop;

            Append
              (Result,
               To_String (Step.Commit_Prefix) & Next_Content_Line & ASCII.LF);

            for L of Version.Log_Graph.Remainder (G) loop
               Append (Result, L & ASCII.LF);
            end loop;
         end;
      end loop;

      return To_String (Result);
   end Log_Graph_Oneline_List_Text;

   function Log_Graph_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Context        : Natural := 3;
      First_Parent   : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Date_Mode      : String := "") return String
   is
      Objects : Version.Object_Cache.Object_Cache;
      In_Set  : Id_Sets.Set;
      G       : Version.Log_Graph.Graph;
      Result  : Unbounded_String;
      First   : Boolean := True;
   begin
      for C of Commits loop
         In_Set.Include (Version.Objects.To_String (C));
      end loop;

      Version.Log_Graph.Init (G);

      for C of Commits loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, C);
            Parents : Version.Objects.Object_Id_Vectors.Vector;
            One     : Version.History.Commit_Id_Vectors.Vector;

            --  This commit's full text block, formatted exactly as `log`
            --  would show it on its own (no leading/trailing blank line).
            Block   : Unbounded_String;
            Pos     : Natural;
            Line_No : Natural := 0;
            Step    : Version.Log_Graph.Step;
         begin
            for P of Version.Objects.Commit_Parent_Ids (Obj) loop
               if In_Set.Contains (Version.Objects.To_String (P)) then
                  Parents.Append (P);
               end if;
            end loop;

            One.Append (C);
            Block := To_Unbounded_String
              (Log_List_Text
                 (Repo, One,
                  Show_Signature => Show_Signature,
                  Stat           => Stat,
                  Patch          => Patch,
                  Name_Only      => Name_Only,
                  Name_Status    => Name_Status,
                  Numstat        => Numstat,
                  Shortstat      => Shortstat,
                  Raw            => Raw,
                  Context        => Context,
                  First_Parent   => First_Parent,
                  Kind           => Kind,
                  Show_Notes     => Show_Notes,
                  Date_Mode      => Date_Mode));

            Version.Log_Graph.Update (G, C, Parents);

            --  git separates commits with a graph-prefixed blank line, drawn
            --  from the freshly updated (post-Update) lane state.
            if not First then
               Append (Result, Version.Log_Graph.Separator_Line (G) & ASCII.LF);
            end if;
            First := False;

            Step := Version.Log_Graph.Begin_Commit (G);
            for L of Step.Pre_Lines loop
               Append (Result, L & ASCII.LF);
            end loop;

            --  Prefix every line of the block: the commit line takes the
            --  commit prefix, each following line one graph column line.
            Pos := 1;
            while Pos <= Length (Block) loop
               declare
                  Stop : Natural := Pos;
               begin
                  while Stop <= Length (Block)
                    and then Element (Block, Stop) /= ASCII.LF
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Text : constant String := Slice (Block, Pos, Stop - 1);
                  begin
                     if Line_No = 0 then
                        Append
                          (Result,
                           To_String (Step.Commit_Prefix) & Text & ASCII.LF);
                     else
                        Append
                          (Result,
                           Version.Log_Graph.Next_Line (G) & Text & ASCII.LF);
                     end if;
                  end;

                  Line_No := Line_No + 1;
                  Pos := Stop + 1;
               end;
            end loop;

            --  Any connector rows the commit still owes (a merge whose block
            --  was shorter than its post-merge/collapse output).
            while not Version.Log_Graph.Is_Finished (G) loop
               Append (Result, Version.Log_Graph.Next_Line (G) & ASCII.LF);
            end loop;
         end;
      end loop;

      return To_String (Result);
   end Log_Graph_List_Text;

   function Log_Formatted_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Format  : String;
      Terminate_Records : Boolean := True;
      Date_Mode : String := "") return String
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
                              (Repo, Current_Id, Format, Date_Mode));
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
      Max_Count : Natural := 0;
      Date_Mode : String := "") return String
   is
      Objects : Version.Object_Cache.Object_Cache;
   begin
      return Log_Formatted_List_Text
        (Repo,
         To_Commit_List (Collect_History
                           (Repo, Objects, Commit_Id, Max_Count)),
         Format, Terminate_Records, Date_Mode);
   end Log_Formatted_From_Commit;

end Version.Log;
