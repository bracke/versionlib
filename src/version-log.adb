with Ada.Containers.Indefinite_Hashed_Sets;
with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;

with Version.Objects; use Version.Objects;
with Version.Object_Cache;
with Version.Revisions;
with Version.Shallow_Cache;
with Version.Ref_Cache;
with Version.Pretty_Format;
with Version.Verify;
with Version.Refs;
with Version.Ref_Format;
with Version.Notes;
with Version.Log_Graph;
with Version.Ignore;
with Version.Mailmap;
with Version.Combine_Diff;

package body Version.Log is

   use Ada.Strings.Unbounded;

   package Decor_Maps renames Decoration_Maps;

   --  Build git's `--decorate` map: commit id -> "HEAD -> main, tag: v2".
   --  Refs are gathered in git's decoration order (the current branch first,
   --  then other branches, then tags, then remotes), each peeled to the commit
   --  it names.
   function Has_Prefix (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  git's --decorate-refs DWIM: a pattern is tried as given, under
   --  "refs/", and under any one "refs/<kind>/" hierarchy.
   function Ref_Matches (Pattern, Refname : String) return Boolean is
      Has_Glob : constant Boolean :=
        (for some C of Pattern => C in '*' | '?' | '[');
      function M (P : String) return Boolean is
        (Version.Ignore.Wildcard_Matches (P, Refname)
         or else (not Has_Glob
                  and then Version.Ignore.Wildcard_Matches (P & "/*", Refname)));
   begin
      return M (Pattern)
        or else M ("refs/" & Pattern)
        or else M ("refs/*/" & Pattern);
   end Ref_Matches;

   function Build_Decorations
     (Repo    : Version.Repository.Repository_Handle;
      Mode    : Decorate_Mode;
      Include : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Exclude : String_Vectors.Vector := String_Vectors.Empty_Vector)
      return Decor_Maps.Map
   is
      Map : Decor_Maps.Map;

      --  --decorate-refs / --decorate-refs-exclude: a ref decorates when it
      --  matches none of the excludes and (given any includes) one include.
      function Wanted (Refname : String) return Boolean is
      begin
         for P of Exclude loop
            if Ref_Matches (P, Refname) then
               return False;
            end if;
         end loop;
         if Include.Is_Empty then
            return True;
         end if;
         for P of Include loop
            if Ref_Matches (P, Refname) then
               return True;
            end if;
         end loop;
         return False;
      end Wanted;

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

      --  git loads every ref in sorted order and prepends each decoration
      --  as it goes, so they read in reverse ref order (tags, stash,
      --  remotes, heads, ...) after the "HEAD -> <branch>" entry.  Without
      --  --decorate-refs[-exclude] only the decorated namespaces (heads,
      --  remotes, tags, stash) take part; with any pattern, every ref does.
      Default_Namespaces : constant Boolean :=
        Include.Is_Empty and then Exclude.Is_Empty;

      function In_Default_Namespace (Refname : String) return Boolean is
        (Has_Prefix (Refname, "refs/heads/")
         or else Has_Prefix (Refname, "refs/remotes/")
         or else Has_Prefix (Refname, "refs/tags/")
         or else Refname = "refs/stash");

      All_Refs : constant Version.Ref_Format.String_Vectors.Vector :=
        Version.Ref_Format.For_Each_Ref
          (Repo, Version.Ref_Format.String_Vectors.Empty_Vector, "%(refname)");
   begin
      --  Current branch first, shown as "HEAD -> <branch>".
      if Head_Branch /= "" and then Wanted (Head_Branch) then
         begin
            Add (Version.Objects.To_String
                   (Version.Revisions.Resolve_Commit (Repo, Head_Branch)),
                 "HEAD -> " & Label (Head_Branch));
         exception
            when others => null;
         end;
      end if;
      for I in reverse All_Refs.First_Index .. All_Refs.Last_Index loop
         declare
            R : constant String := All_Refs.Element (I);
         begin
            if R /= Head_Branch
              and then not Has_Prefix (R, "refs/replace/")
              and then (not Default_Namespaces or else In_Default_Namespace (R))
              and then Wanted (R)
            then
               begin
                  Add (Version.Objects.To_String
                         (Version.Revisions.Resolve_Commit (Repo, R)),
                       Label (R));
               exception
                  when others => null;
               end;
            end if;
         end;
      end loop;
      return Map;
   end Build_Decorations;

   function Decorations
     (Repo : Version.Repository.Repository_Handle;
      Mode : Decorate_Mode := Short_Decorate) return Decoration_Maps.Map
   is (Build_Decorations (Repo, Mode));

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
      elsif Mode /= "" and then Mode /= "default" and then Mode /= "short"
        and then Mode /= "iso" and then Mode /= "iso8601"
        and then Mode /= "iso-strict" and then Mode /= "iso8601-strict"
        and then Mode /= "rfc2822" and then Mode /= "rfc"
      then
         --  relative, human, format:<strftime>, the -local variants:
         --  the pretty-format engine renders those.
         return Version.Pretty_Format.Format_Date (Raw, Mode);
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
               elsif Mode = "rfc2822" or else Mode = "rfc" then
                  --  git's DATE_RFC2822: "Www, D Mmm YYYY HH:MM:SS ±ZZZZ" with
                  --  the day of month unpadded (git's "%d").
                  return
                    Weekdays (Natural (Wd)) & ", " & Trim (D) & " "
                    & Months (Natural (M)) & " " & Trim (Y) & " "
                    & Pad2 (HH) & ":" & Pad2 (Mn) & ":" & Pad2 (Sc) & " " & Tz;
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

   --  A message line with its tabs expanded to Tab_Width columns (git's
   --  strbuf_add_tabexpand, measured from the line's own start, not the
   --  indent); 0 leaves tabs alone.
   function Expanded (Line : String; Tab_Width : Natural) return String is
      Result : Unbounded_String;
      Col    : Natural := 0;
   begin
      if Tab_Width = 0 then
         return Line;
      end if;
      for C of Line loop
         if C = ASCII.HT then
            declare
               Fill : constant Natural := Tab_Width - (Col mod Tab_Width);
            begin
               Append (Result, [1 .. Fill => ' ']);
               Col := Col + Fill;
            end;
         else
            Append (Result, C);
            Col := Col + 1;
         end if;
      end loop;
      return To_String (Result);
   end Expanded;

   procedure Append_Indented_Message
     (Result    : in out Unbounded_String;
      Message   : String;
      Tab_Width : Natural := 0)
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
               Append_Line
                 (Result, "    " & Expanded (Message (Start .. Stop - 1), Tab_Width));
            end if;

            Start := Stop + 1;
         end;
      end loop;
   end Append_Indented_Message;

   --  The id as `log` prints it: --abbrev=<n> when given, else the shortest
   --  unique prefix floored at 7 (core.abbrev=auto); Full spells it out.
   function Shown_Id
     (Repo   : Version.Repository.Repository_Handle;
      Id     : Version.Objects.Hex_Object_Id;
      Header : Header_Options;
      Full   : Boolean) return String
   is
      Hex : constant String := To_String (Id);
      N   : constant Natural :=
        (if Full then Hex'Length
         elsif Header.Abbrev_Len > 0
         then Natural'Min (Natural'Max (Header.Abbrev_Len, 4), Hex'Length)
         else Version.Revisions.Unique_Abbrev_Length (Repo, Id, 7));
   begin
      return Hex (Hex'First .. Hex'First + N - 1);
   end Shown_Id;

   --  git's put_revision_mark: the --left-right/--cherry/--boundary mark
   --  and a space before the id, nothing without one.
   function Mark_Prefix (Note : Annotation) return String is
     (if Note.Mark = ' ' then "" else Note.Mark & " ");

   function Format_Commit_Oneline_With_Cache
     (Repo          : Version.Repository.Repository_Handle;
      Cache         : in out Version.Object_Cache.Object_Cache;
      Commit_Id     : Version.Objects.Hex_Object_Id;
      With_Parents  : Boolean := False;
      Children_Text : String := "";
      Header        : Header_Options := (others => <>);
      Note          : Annotation := (others => <>);
      Decoration    : String := "";
      From_Parent   : String := "") return String
   is
      Obj : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);

      --  --parents inserts the abbreviated parent ids after the commit id.
      function Parents_Text return String is
         Result : Unbounded_String;
      begin
         for P of Version.Objects.Commit_Parent_Ids (Obj) loop
            Append
              (Result, " " & Shown_Id (Repo, P, Header, Header.Full_Oneline));
         end loop;
         return To_String (Result);
      end Parents_Text;

      --  Children_Text arrives space-terminated ("c1 c2 ").
      function Children return String is
        (if Children_Text'Length = 0 then ""
         else " " & Children_Text (Children_Text'First .. Children_Text'Last - 1));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Commit_Object then
         raise Ada.IO_Exceptions.Data_Error
           with "object is not a commit: " & To_String (Commit_Id);
      end if;

      --  A reflog walk (-g) shows the entry in place of the subject.
      if Length (Note.Reflog_Selector) > 0 then
         return
           Mark_Prefix (Note)
           & Shown_Id (Repo, Commit_Id, Header, Header.Full_Oneline)
           & " " & To_String (Note.Reflog_Selector) & ": "
           & To_String (Note.Reflog_Message);
      end if;

      --  git's show_log order: mark, id, parents, children, source,
      --  decorations, then the subject -- with --log-size wedged between
      --  as its own line, exactly as git prints it.
      declare
         Subject : constant String :=
           Version.Objects.Commit_Message_First_Line (Obj);
         Size    : constant String := Natural'Image (Subject'Length);
      begin
         return
           Mark_Prefix (Note)
           & Shown_Id (Repo, Commit_Id, Header, Header.Full_Oneline)
           & (if With_Parents then Parents_Text else "")
           & Children
           & (if From_Parent'Length > 0 then " (from " & From_Parent & ")" else "")
           & (if Length (Note.Source) > 0
              then ASCII.HT & To_String (Note.Source) else "")
           & (if Decoration'Length > 0 then " (" & Decoration & ")" else "")
           & " "
           & (if Header.Log_Size
              then "log size " & Size (Size'First + 1 .. Size'Last) & ASCII.LF
              else "")
           & Subject;
      end;
   end Format_Commit_Oneline_With_Cache;

   --  The "Notes:" blocks for Commit_Id under Header's notes selection --
   --  each a blank line, its label, and the indented text -- or "".
   function Notes_Block
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Header    : Header_Options;
      Tab_Width : Natural) return String
   is
      Body_Text : Unbounded_String;

      procedure Show_Note (Ref : String; Label : String) is
         Text : constant String :=
           Version.Notes.Show (Repo, Commit_Id, Ref);
         Last : Natural := Text'Last;
      begin
         while Last >= Text'First
           and then Text (Last) = Character'Val (10)
         loop
            Last := Last - 1;
         end loop;
         if Last >= Text'First then
            Append_Line (Body_Text, "");
            Append_Line (Body_Text, Label);
            Append_Indented_Message
              (Body_Text, Text (Text'First .. Last), Tab_Width);
         end if;
      exception
         when others =>
            null;
      end Show_Note;
   begin
      --  The default ref reads "Notes:"; any other names itself
      --  ("Notes (<ref>):", the refs/notes/ prefix dropped).
      if Header.Standard_Notes then
         Show_Note (Version.Notes.Default_Ref, "Notes:");
      end if;
      for R of Header.Notes_Refs loop
         declare
            Full : constant String :=
              (if R'Length >= 11
                 and then R (R'First .. R'First + 10) = "refs/notes/"
               then R
               elsif R'Length >= 6
                 and then R (R'First .. R'First + 5) = "notes/"
               then "refs/" & R
               else "refs/notes/" & R);
            Short : constant String :=
              Full (Full'First + 11 .. Full'Last);
         begin
            if Full /= Version.Notes.Default_Ref
              or else not Header.Standard_Notes
            then
               Show_Note
                 (Full,
                  (if Full = Version.Notes.Default_Ref then "Notes:"
                   else "Notes (" & Short & "):"));
            end if;
         end;
      end loop;
      return To_String (Body_Text);
   end Notes_Block;

   function Format_Commit_With_Cache
     (Repo           : Version.Repository.Repository_Handle;
      Cache          : in out Version.Object_Cache.Object_Cache;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Full_Message   : Boolean := False;
      Show_Signature : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Date_Mode      : String := "";
      Header         : Header_Options := (others => <>);
      Note           : Annotation := (others => <>);
      Decoration     : String := "";
      From_Parent    : String := "";
      Children_Text  : String := "") return String
   is
      use type Version.Verify.Verify_Result;

      --  --parents: the parent ids after the commit id, abbreviated only
      --  under --abbrev-commit.
      function Parents_Suffix return String is
         R : Unbounded_String;
      begin
         if Header.Parents then
            for P of Version.Objects.Commit_Parent_Ids
              (Version.Object_Cache.Read_Object (Repo, Cache, Commit_Id))
            loop
               Append (R, " " & Shown_Id (Repo, P, Header, not Header.Abbrev_Commit));
            end loop;
         end if;
         return To_String (R);
      end Parents_Suffix;
      Obj     : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo => Repo, Cache => Cache, Id => Commit_Id);
      Content : constant String := Version.Objects.Content (Obj);
      Result  : Unbounded_String;
      --  Everything after the commit line (and the reflog lines) is what
      --  git measures for --log-size, so it is built apart.
      Body_Text : Unbounded_String;

      --  --[no-]use-mailmap rewrites the identity on the Author/Commit
      --  lines; the date tail stays.
      Map : constant Version.Mailmap.Entries :=
        (if Header.Mailmap then Version.Mailmap.Load (Repo)
         else Version.Mailmap.Parse (""));

      function Mapped (Ident_Line : String) return String is
         LT, GT : Natural := 0;
      begin
         if not Header.Mailmap then
            return Ident_Line;
         end if;
         for K in Ident_Line'Range loop
            if Ident_Line (K) = '<' and then LT = 0 then
               LT := K;
            elsif Ident_Line (K) = '>' then
               GT := K;
            end if;
         end loop;
         if LT = 0 or else GT < LT then
            return Ident_Line;
         end if;
         declare
            Name  : constant String :=
              (if LT > Ident_Line'First + 1
               then Ident_Line (Ident_Line'First .. LT - 2) else "");
            Email : constant String := Ident_Line (LT + 1 .. GT - 1);
            New_Name, New_Email : Unbounded_String;
         begin
            Version.Mailmap.Apply (Map, Name, Email, New_Name, New_Email);
            return To_String (New_Name) & " <" & To_String (New_Email) & ">"
              & Ident_Line (GT + 1 .. Ident_Line'Last);
         end;
      end Mapped;

      --  --expand-tabs: git's default is 8 for the indented layouts.
      Tab_Width : constant Natural :=
        (if Header.Expand_Tabs >= 0 then Header.Expand_Tabs
         elsif Kind in Pretty_Medium | Pretty_Full | Pretty_Fuller then 8
         else 0);
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

      Append_Line
        (Result,
         "commit " & Mark_Prefix (Note)
         & Shown_Id (Repo, Commit_Id, Header, not Header.Abbrev_Commit)
         & Parents_Suffix
         & (if Children_Text'Length = 0 then ""
            else " " & Children_Text (Children_Text'First .. Children_Text'Last - 1))
         & (if From_Parent'Length > 0 then " (from " & From_Parent & ")" else "")
         & (if Length (Note.Source) > 0
            then ASCII.HT & To_String (Note.Source) else "")
         & (if Decoration'Length > 0 then " (" & Decoration & ")" else ""));
      if Length (Note.Reflog_Selector) > 0 then
         Append_Line
           (Result,
            "Reflog: " & To_String (Note.Reflog_Selector)
            & " (" & To_String (Note.Reflog_Ident) & ")");
         Append_Line
           (Result, "Reflog message: " & To_String (Note.Reflog_Message));
      end if;

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
               Append_Line (Body_Text, Content (Content'First .. Sep - 1));
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
                     Append (Line, " " & Shown_Id (Repo, P, Header, False));
                  end loop;
                  Append_Line (Body_Text, To_String (Line));
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
                  Append (Body_Text, To_String (Out_Text));
               end if;
            end;
         end if;

         --  The identity/date lines differ per format: short has the author
         --  only, medium adds the author date, full adds the committer, and
         --  fuller shows both identities with both dates (colon-aligned to 12).
         case Kind is
            when Pretty_Short =>
               Append_Line (Body_Text, "Author: " & Mapped (Author_Name_Date (Content)));
            when Pretty_Medium =>
               Append_Line (Body_Text, "Author: " & Mapped (Author_Name_Date (Content)));
               Append_Line
                 (Body_Text,
                  "Date:   "
                  & Format_Git_Date (Author_Date (Content), Date_Mode));
            when Pretty_Full =>
               Append_Line (Body_Text, "Author: " & Mapped (Author_Name_Date (Content)));
               Append_Line
                 (Body_Text, "Commit: " & Mapped (Committer_Name_Date (Content)));
            when Pretty_Fuller =>
               Append_Line
                 (Body_Text, "Author:     " & Mapped (Author_Name_Date (Content)));
               Append_Line
                 (Body_Text,
                  "AuthorDate: "
                  & Format_Git_Date (Author_Date (Content), Date_Mode));
               Append_Line
                 (Body_Text, "Commit:     " & Mapped (Committer_Name_Date (Content)));
               Append_Line
                 (Body_Text,
                  "CommitDate: "
                  & Format_Git_Date (Committer_Date (Content), Date_Mode));
            when Pretty_Raw =>
               null;
         end case;
      end if;

      Append_Line (Body_Text, "");
      Append_Indented_Message (Body_Text, Message, Tab_Width);

      --  git shows the commit's note (from the default notes ref) after the
      --  message, blank-separated and indented like the message -- but the
      --  automatic display is suppressed once an explicit --pretty/--format is
      --  given (Show_Notes carries that), and the raw format never carries it.
      if Full_Message and then Kind /= Pretty_Raw and then Show_Notes then
         Append (Body_Text, Notes_Block (Repo, Commit_Id, Header, Tab_Width));
      end if;

      if Header.Log_Size then
         declare
            Img : constant String := Natural'Image (Length (Body_Text));
         begin
            Append_Line (Result, "log size " & Img (Img'First + 1 .. Img'Last));
         end;
      end if;
      Append (Result, Body_Text);
      return To_String (Result);
   end Format_Commit_With_Cache;

   function Format_Commit
     (Repo         : Version.Repository.Repository_Handle;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False;
      Kind         : Pretty_Kind := Pretty_Medium;
      Show_Notes   : Boolean := True;
      Date_Mode    : String := "";
      Header       : Header_Options := (others => <>);
      Note         : Annotation := (others => <>)) return String
   is
      Cache : Version.Object_Cache.Object_Cache;
   begin
      return
        Format_Commit_With_Cache
          (Repo         => Repo,
           Cache        => Cache,
           Commit_Id    => Commit_Id,
           Full_Message => Full_Message,
           Header       => Header,
           Note         => Note,
           Kind         => Kind,
           Show_Notes   => Show_Notes,
           Date_Mode    => Date_Mode);
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

   --  The annotation for the Index-th shown commit; none when the caller
   --  gave no annotations.
   function Note_At (Header : Header_Options; Index : Natural)
     return Annotation
   is
   begin
      if Index >= Header.Annotations.First_Index
        and then Index <= Header.Annotations.Last_Index
      then
         return Header.Annotations.Element (Index);
      end if;
      return (others => <>);
   end Note_At;

   --  The one-element annotation vector for a listing of a single commit
   --  (the graph renderer formats each commit on its own).
   function Note_Of (Header : Header_Options; Index : Natural)
     return Annotation_Vectors.Vector
   is
      V : Annotation_Vectors.Vector;
   begin
      V.Append (Note_At (Header, Index));
      return V;
   end Note_Of;

   --  Whether Parent_Id is a parent of the commit Child_Hex names.
   function Is_Parent_Of
     (Repo      : Version.Repository.Repository_Handle;
      Objects   : in out Version.Object_Cache.Object_Cache;
      Parent_Id : Version.Objects.Hex_Object_Id;
      Child_Hex : Unbounded_String) return Boolean
   is
      Child : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo, Objects,
           Version.Objects.To_Object_Id (To_String (Child_Hex)));
   begin
      for P of Version.Objects.Commit_Parent_Ids (Child) loop
         if Version.Objects.To_String (P)
            = Version.Objects.To_String (Parent_Id)
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Parent_Of;

   --  git's `--children`: for each shown commit, the shown commits that
   --  list it as a parent, abbreviated and space-terminated ("c1 c2 ").
   --  git records a child by prepending it as the (newest-first) walk
   --  reaches it, so iterating Commits in display order and prepending
   --  reproduces its per-commit order.
   function Children_Map
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Header  : Header_Options;
      Full    : Boolean) return Decor_Maps.Map
   is
      Kids   : Decor_Maps.Map;
      In_Set : Id_Sets.Set;
   begin
      for C of Commits loop
         In_Set.Include (Version.Objects.To_String (C));
      end loop;
      for C of Commits loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, C);
            Child : constant String := Shown_Id (Repo, C, Header, Full);
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
      return Kids;
   end Children_Map;

   --  git's `--boundary`: the excluded parents of the shown commits (the
   --  uninteresting frontier of a range).
   function Boundary_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Commits : Version.History.Commit_Id_Vectors.Vector)
      return Version.History.Commit_Id_Vectors.Vector
   is
      In_Set   : Id_Sets.Set;
      Seen     : Id_Sets.Set;
      Boundary : Version.History.Commit_Id_Vectors.Vector;
   begin
      for C of Commits loop
         In_Set.Include (Version.Objects.To_String (C));
      end loop;
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
      --  git records a boundary parent as each shown commit comes out (in
      --  parent order), builds its list by prepending, and then sorts that
      --  list topologically in graph order -- which keeps the list order
      --  for unrelated commits and puts a boundary commit's own boundary
      --  ancestors after it.
      declare
         Reversed : Version.History.Commit_Id_Vectors.Vector;
      begin
         for I in reverse Boundary.First_Index .. Boundary.Last_Index loop
            Reversed.Append (Boundary.Element (I));
         end loop;
         return Version.History.Topological_Order (Repo, Reversed);
      end;
   end Boundary_Commits;

   --  A name-only rendering of the same pairs the caller's options select:
   --  stands in for git's diff queue when deciding whether a commit has
   --  anything to show.
   function Probe_Opts
     (Base         : Version.Diff.Diff_Options;
      Detect       : Version.Diff.Rename_Detection;
      Rename_Score : Natural) return Version.Diff.Diff_Options
   is ((Base with delta
        Name_Only => True, Name_Status => False, Stat => False,
        Summary => False, Numstat => False, Shortstat => False, Raw => False,
        Compact_Summary => False, Detect_Renames => Detect,
        Rename_Score => Rename_Score));

   --  Two consecutive shown commits are "linear" when one is the other's
   --  parent -- whichever way round, so --reverse reads the same.
   function Linear
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Current : Version.Objects.Hex_Object_Id;
      Previous_Hex : Unbounded_String) return Boolean
   is (Is_Parent_Of (Repo, Objects, Current, Previous_Hex)
       or else Is_Parent_Of
                 (Repo, Objects,
                  Version.Objects.To_Object_Id (To_String (Previous_Hex)),
                  To_Unbounded_String (Version.Objects.To_String (Current))));

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
      Paths          : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Rename_Score   : Natural := 0;
      Date_Mode      : String := "";
      Stat_Width      : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Base       : Version.Diff.Diff_Options := (others => <>);
      Header          : Header_Options := (others => <>);
      Separate_Merges : Boolean := False;
      Combined_Merges : Boolean := False;
      Dense_Combined  : Boolean := False;
      Format          : String := "";
      Terminate_Records : Boolean := True;
      Always_Show_Header : Boolean := False)
      return String
   is
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      First   : Boolean := True;
      Decor   : constant Decor_Maps.Map :=
        (if Header.Decorate = No_Decorate then Decor_Maps.Empty_Map
         else Build_Decorations
                (Repo, Header.Decorate,
                 Header.Decorate_Refs, Header.Decorate_Refs_Exclude));
      Previous : Unbounded_String;   --  the last shown commit, for the break
      Kids     : constant Decor_Maps.Map :=
        (if Header.Children
         then Children_Map (Repo, Objects, Commits, Header, not Header.Abbrev_Commit)
         else Decor_Maps.Empty_Map);
      --  A custom --format/--pretty layout for the header.
      Custom   : constant Boolean := Format'Length > 0;
   begin
      for Index in Commits.First_Index .. Commits.Last_Index loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Commits.Element (Index);
            Obj        : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object
                (Repo => Repo, Cache => Objects, Id => Current_Id);
            Hex        : constant String := Version.Objects.To_String (Current_Id);
            Note       : constant Annotation := Note_At (Header, Index);
            Decoration : constant String :=
              (if Decor.Contains (Hex) then Decor.Element (Hex) else "");
            --  One log entry: the header, then the diff against Parent
            --  when a diff format is on.  A merge under -m gets one entry
            --  per parent, labelled "(from <parent>)".
            procedure Emit_Entry
              (Parent : String; From_Label : String; Show_Diff : Boolean) is
            begin
               if Custom then
                  --  The expanded format, terminated for tformat/--format
                  --  (git's use_terminator), bare for `format:`; --log-size
                  --  names the record's length first.
                  declare
                     Text : constant String :=
                       Version.Pretty_Format.Expand
                         (Repo, Current_Id, Format, Date_Mode,
                          Reflog => (Selector => Note.Reflog_Selector,
                                     Ident    => Note.Reflog_Ident,
                                     Message  => Note.Reflog_Message));
                     Img : constant String := Natural'Image (Text'Length);
                  begin
                     if Header.Log_Size then
                        Append_Line
                          (Result, "log size " & Img (Img'First + 1 .. Img'Last));
                     end if;
                     Append (Result, Text);
                     if Terminate_Records then
                        Append
                          (Result,
                           (if Header.Nul_Separated then ASCII.NUL else ASCII.LF));
                     end if;
                  end;
               elsif Oneline then
                  Append
                    (Result,
                     Format_Commit_Oneline_With_Cache
                       (Repo => Repo, Cache => Objects, Commit_Id => Current_Id,
                        Header => Header, Note => Note,
                        Decoration => Decoration,
                        From_Parent => From_Label));
                  if not Header.Nul_Separated
                    or else Length (Note.Reflog_Selector) > 0
                  then
                     Append (Result, ASCII.LF);
                  end if;
                  --  An explicit --notes shows the note under the oneline
                  --  header too, blank-terminated.
                  if Show_Notes and then Header.Notes_Explicit then
                     declare
                        Block : constant String :=
                          Notes_Block (Repo, Current_Id, Header, 0);
                     begin
                        if Block'Length > 0 then
                           Append (Result, Block (Block'First + 1 .. Block'Last));
                           Append_Line (Result, "");
                        end if;
                     end;
                  end if;
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
                        Date_Mode      => Date_Mode,
                        Header         => Header,
                        Note           => Note,
                        Decoration     => Decoration,
                        From_Parent    => From_Label,
                        Children_Text  =>
                          (if Kids.Contains (Hex) then Kids.Element (Hex) else "")));
               end if;
               if Show_Diff then
                  --  git's --stat/-p: a blank line, then the diffstat or the
                  --  patch against Parent (or the empty tree for a root commit).
                  declare
                     Has_Summary : constant Boolean :=
                       Stat or else Name_Only or else Name_Status
                       or else Numstat or else Shortstat or else Raw
                       or else Diff_Base.Summary;
                     --  A summary format (--stat/--name-only/...) and a patch (-p)
                     --  need separate diff passes: Diff_Options suppresses the
                     --  patch body whenever a summary field is set.
                     --  --raw goes through the porcelain engine (Diff_Options.Raw)
                     --  so it detects renames by default (git's diff.renames), as
                     --  `log --raw` does -- the diff-tree plumbing raw does not.
                     --  git's -M<n>/-C<n> sets the rename similarity threshold;
                     --  a non-zero score forces rename detection on (it is on by
                     --  default for these summaries anyway).
                     Detect : constant Version.Diff.Rename_Detection :=
                       (if Rename_Score > 0 then Version.Diff.Renames_On
                        else Version.Diff.Renames_Default);
                     --  Diff_Base carries the caller's diff switches (-w, --color,
                     --  --diff-algorithm, ...); the log-level fields go on top.
                     Summary_Opts : constant Version.Diff.Diff_Options :=
                       (Diff_Base with delta
                        Stat           => Stat,
                        Name_Only      => Name_Only,
                        Name_Status    => Name_Status,
                        Numstat        => Numstat,
                        Shortstat      => Shortstat,
                        Raw            => Raw,
                        Detect_Renames => Detect,
                        Rename_Score   => Rename_Score,
                        Context_Lines  => Context,
                        Stat_Width      => Stat_Width,
                        Stat_Name_Width => Stat_Name_Width,
                        Stat_Count      => Stat_Count);
                     Patch_Opts : constant Version.Diff.Diff_Options :=
                       (Diff_Base with delta
                        Detect_Renames => Detect,
                        Rename_Score   => Rename_Score,
                        Context_Lines  => Context);

                     --  Use the pathspec overload only when a limit is present;
                     --  the plain overload is the exact unlimited rendering.
                     function Diff_Of (Opts : Version.Diff.Diff_Options)
                        return String
                     is (if Paths.Is_Empty then
                           (if Parent'Length > 0
                            then Version.Diff.Diff_Commits
                                   (Repo, Version.Objects.To_Object_Id (Parent),
                                    Current_Id, Opts)
                            else Version.Diff.Diff_Root_Commit
                                   (Repo, Current_Id, Opts))
                         elsif Parent'Length > 0
                         then Version.Diff.Diff_Commits
                                (Repo, Version.Objects.To_Object_Id (Parent),
                                 Current_Id, Paths, Opts)
                         else Version.Diff.Diff_Root_Commit
                                (Repo, Current_Id, Paths, Opts));
                     Summary_Text : constant String :=
                       (if Has_Summary then Diff_Of (Summary_Opts) else "");
                     Patch_Text   : constant String :=
                       (if Patch and then not (Name_Only or else Name_Status)
                        then Diff_Of (Patch_Opts) else "");
                     --  git prints the separator whenever the diff queue has
                     --  a pair, even when the chosen format then says nothing
                     --  (--summary of a plain edit); a queue emptied by
                     --  --relative or whitespace folding gets none.  A
                     --  name-only pass stands in for the queue.
                     Has_Pairs : constant Boolean :=
                       Summary_Text'Length > 0 or else Patch_Text'Length > 0
                       or else Diff_Of (Probe_Opts (Diff_Base, Detect, Rename_Score))'Length > 0;
                  begin
                     --  The full header ends with the message, so a separator
                     --  precedes the file changes; the oneline header runs
                     --  straight into them. git leads a diffstat that is followed
                     --  by a patch with "---" rather than a blank line.
                     if not Oneline and then Has_Pairs then
                        if Stat and then Patch then
                           Append_Line (Result, "---");
                        else
                           Append_Line (Result, "");
                        end if;
                     end if;

                     Append (Result, Summary_Text);

                     --  git shows the patch after the summary, blank-separated --
                     --  but the name-only/name-status formats replace the patch
                     --  entirely, so -p adds nothing there.
                     if Patch_Text'Length > 0 then
                        if Has_Summary then
                           Append_Line (Result, "");
                        end if;
                        Append (Result, Patch_Text);
                     end if;
                  end;
               end if;
            end Emit_Entry;

            Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
              Version.Objects.Commit_Parent_Ids (Obj);
            Is_Merge : constant Boolean := Natural (Parents.Length) >= 2;
            Any_Diff : constant Boolean :=
              Stat or else Patch or else Name_Only or else Name_Status
              or else Numstat or else Shortstat or else Raw
              or else Diff_Base.Summary;
         begin
            --  --diff-filter prunes a commit whose diff has nothing left to
            --  show (git shows the header only when the diff did).
            if Any_Diff and then Length (Diff_Base.Diff_Filter) > 0
              and then not Always_Show_Header
            then
               declare
                  Detect : constant Version.Diff.Rename_Detection :=
                    (if Rename_Score > 0 then Version.Diff.Renames_On
                     else Version.Diff.Renames_Default);
                  Probe  : constant Version.Diff.Diff_Options :=
                    Probe_Opts (Diff_Base, Detect, Rename_Score);
                  Any    : Boolean := False;
               begin
                  if Is_Merge and then not Separate_Merges and then not First_Parent
                  then
                     Any := False;
                  else
                     for K in Parents.First_Index .. Parents.Last_Index loop
                        exit when not Separate_Merges and then K > Parents.First_Index;
                        if String'(if Paths.Is_Empty
                                   then Version.Diff.Diff_Commits
                                          (Repo, Parents.Element (K), Current_Id,
                                           Probe)
                                   else Version.Diff.Diff_Commits
                                          (Repo, Parents.Element (K), Current_Id,
                                           Paths, Probe))'Length > 0
                        then
                           Any := True;
                        end if;
                     end loop;
                     if Parents.Is_Empty
                       and then String'(if Paths.Is_Empty
                                        then Version.Diff.Diff_Root_Commit
                                               (Repo, Current_Id, Probe)
                                        else Version.Diff.Diff_Root_Commit
                                               (Repo, Current_Id, Paths,
                                                Probe))'Length > 0
                     then
                        Any := True;
                     end if;
                  end if;
                  if not Any then
                     goto Skip_Commit;
                  end if;
               end;
            end if;

            --  --show-linear-break: "\n<bar>\n" before a commit that is not
            --  the parent of the one shown before it (git prints it ahead
            --  of the usual separator).
            if not First and then Length (Header.Linear_Break) > 0
              and then not Linear (Repo, Objects, Current_Id, Previous)
            then
               Append (Result, ASCII.LF);
               Append_Line (Result, To_String (Header.Linear_Break));
            end if;
            --  The full-header format blank-separates entries; the oneline
            --  form (and a terminated custom format) runs them together, as
            --  git does; an unterminated `format:` gets one newline between
            --  records.  -z puts a NUL where the separator would go.
            if not First then
               if Header.Nul_Separated then
                  Append (Result, ASCII.NUL);
               elsif Custom then
                  if not Terminate_Records then
                     Append (Result, ASCII.LF);
                  end if;
               elsif not Oneline then
                  Append_Line (Result, "");
               end if;
            end if;
            First := False;
            Previous := To_Unbounded_String (Hex);
            if Is_Merge and then Any_Diff and then Separate_Merges then
               --  Each parent's entry is a separate, blank-separated block
               --  (git's -m), the label abbreviated in the oneline form.
               for K in Parents.First_Index .. Parents.Last_Index loop
                  if K > Parents.First_Index then
                     if Header.Nul_Separated then
                        Append (Result, ASCII.NUL);
                     elsif not Oneline then
                        Append_Line (Result, "");
                     end if;
                  end if;
                  Emit_Entry
                    (Version.Objects.To_String (Parents.Element (K)),
                     Shown_Id (Repo, Parents.Element (K), Header,
                               Full => not Oneline),
                     Show_Diff => True);
               end loop;
            elsif Is_Merge and then Any_Diff and then Combined_Merges
              and then not First_Parent
            then
               --  -c/--cc (git's diff_tree_combined): the header, a newline
               --  in every layout (oneline included), the summary formats
               --  against the FIRST parent, then the combined patch.
               if not Diff_Base.Ignore_Regexes.Is_Empty then
                  raise Ada.IO_Exceptions.Data_Error with
                    "combined diff and '--ignore-matching-lines' cannot be used together";
               end if;
               if Header.Output_To_File then
                  raise Ada.IO_Exceptions.Data_Error with
                    "combined diff and '--output' cannot be used together";
               end if;
               Emit_Entry
                 (Version.Objects.Commit_Parent_Id (Obj), "", Show_Diff => False);
               Append (Result, (if Header.Nul_Separated then ASCII.NUL else ASCII.LF));
               declare
                  Detect : constant Version.Diff.Rename_Detection :=
                    (if Rename_Score > 0 then Version.Diff.Renames_On
                     else Version.Diff.Renames_Default);
                  Has_Summary : constant Boolean :=
                    Stat or else Name_Only or else Name_Status
                    or else Numstat or else Shortstat or else Raw
                    or else Diff_Base.Summary;
                  Summary_Opts : constant Version.Diff.Diff_Options :=
                    (Diff_Base with delta
                     Stat           => Stat,
                     Name_Only      => Name_Only,
                     Name_Status    => Name_Status,
                     Numstat        => Numstat,
                     Shortstat      => Shortstat,
                     Raw            => Raw,
                     Detect_Renames => Detect,
                     Rename_Score   => Rename_Score,
                     Context_Lines  => Context,
                     Stat_Width      => Stat_Width,
                     Stat_Name_Width => Stat_Name_Width,
                     Stat_Count      => Stat_Count);
                  First_P : constant Version.Objects.Hex_Object_Id :=
                    Parents.First_Element;
                  --  The list formats are combined (show_raw_diff); the
                  --  stat ones diff against the first parent.
                  Listed : constant Boolean :=
                    Raw or else Name_Only or else Name_Status;
                  Summary_Text : constant String :=
                    (if Listed
                     then Version.Combine_Diff.Combined_Listing
                            (Repo, Current_Id, Parents, Paths,
                             (Diff_Base with delta Detect_Renames => Detect),
                             (if Raw then Version.Combine_Diff.Raw_Listing
                              elsif Name_Status
                              then Version.Combine_Diff.Name_Status_Listing
                              else Version.Combine_Diff.Name_Only_Listing),
                             Header.Pickaxe)
                     elsif not Has_Summary then ""
                     elsif Paths.Is_Empty
                     then Version.Diff.Diff_Commits
                            (Repo, First_P, Current_Id, Summary_Opts)
                     else Version.Diff.Diff_Commits
                            (Repo, First_P, Current_Id, Paths, Summary_Opts));
                  --  git's needsep: a summary format was shown and the
                  --  combined path set is non-empty -- whatever the
                  --  first-parent stat itself printed.
                  Has_Paths : constant Boolean :=
                    Has_Summary
                    and then Version.Combine_Diff.Combined_Listing
                               (Repo, Current_Id, Parents, Paths,
                                Diff_Base, Pick => Header.Pickaxe)'Length > 0;
                  --  --check has no combined form: nothing is printed.
                  Combined_Text : constant String :=
                    (if Patch and then not (Name_Only or else Name_Status)
                       and then not Diff_Base.Check_Whitespace
                     then Version.Combine_Diff.Combined_Patch
                            (Repo, Current_Id, Parents, Paths,
                             (Diff_Base with delta
                              Context_Lines => Context,
                              Detect_Renames => Detect,
                              Rename_Score => Rename_Score),
                             Dense => Dense_Combined,
                             Pick  => Header.Pickaxe)
                     else "");
               begin
                  Append (Result, Summary_Text);
                  if Patch and then not (Name_Only or else Name_Status) then
                     if Has_Paths then
                        Append_Line (Result, "");
                     end if;
                     Append (Result, Combined_Text);
                  end if;
               end;
            else
               Emit_Entry
                 (Version.Objects.Commit_Parent_Id (Obj), "",
                  Show_Diff => Any_Diff and then (not Is_Merge or else First_Parent));
            end if;
            <<Skip_Commit>>
         end;
      end loop;

      --  --boundary: the range's excluded parents, marked "-", after the
      --  shown commits.
      if Header.Boundary and then not Oneline then
         for B of Boundary_Commits (Repo, Objects, Commits) loop
            Append_Line (Result, "");
            Append
              (Result,
               Format_Commit_With_Cache
                 (Repo           => Repo,
                  Cache          => Objects,
                  Commit_Id      => B,
                  Full_Message   => True,
                  Show_Signature => Show_Signature,
                  Kind           => Kind,
                  Show_Notes     => Show_Notes,
                  Date_Mode      => Date_Mode,
                  Header         => Header,
                  Note           => (Mark => '-', others => <>)));
         end loop;
      end if;

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
      Decorate      : Decorate_Mode := No_Decorate;
      Header        : Header_Options := (others => <>)) return String
   is
      Result  : Unbounded_String;
      Objects : Version.Object_Cache.Object_Cache;
      Decor   : constant Decor_Maps.Map :=
        (if Decorate = No_Decorate then Decor_Maps.Empty_Map
         else Build_Decorations
                (Repo, Decorate,
                 Header.Decorate_Refs, Header.Decorate_Refs_Exclude));

      Kids : Decor_Maps.Map;

      procedure Append_Boundary is
      begin
         for B of Boundary_Commits (Repo, Objects, Commits) loop
            Append_Line
              (Result,
               Format_Commit_Oneline_With_Cache
                 (Repo => Repo, Cache => Objects, Commit_Id => B,
                  Header => Header, Note => (Mark => '-', others => <>)));
         end loop;
      end Append_Boundary;

   begin
      if With_Children then
         Kids := Children_Map (Repo, Objects, Commits, Header, Header.Full_Oneline);
      end if;

      for Index in Commits.First_Index .. Commits.Last_Index loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Commits.Element (Index);
            Hex : constant String := Version.Objects.To_String (Current_Id);
         begin
            --  --show-linear-break before a commit that does not parent the
            --  one above it.
            if Index > Commits.First_Index
              and then Length (Header.Linear_Break) > 0
              and then not Linear
                             (Repo, Objects, Current_Id,
                              To_Unbounded_String
                                (Version.Objects.To_String
                                   (Commits.Element (Index - 1))))
            then
               Append (Result, ASCII.LF);
               Append_Line (Result, To_String (Header.Linear_Break));
            end if;
            Append
              (Result,
               Format_Commit_Oneline_With_Cache
                 (Repo => Repo, Cache => Objects, Commit_Id => Current_Id,
                  With_Parents  => With_Parents,
                  Children_Text =>
                    (if With_Children and then Kids.Contains (Hex)
                     then Kids.Element (Hex) else ""),
                  Header        => Header,
                  Note          => Note_At (Header, Index),
                  Decoration    =>
                    (if Decor.Contains (Hex) then Decor.Element (Hex)
                     else "")));
            --  -z terminates each line with NUL instead of a newline; a
            --  reflog entry line keeps its newline (git prints it itself).
            Append
              (Result,
               (if Header.Nul_Separated
                  and then Length (Note_At (Header, Index).Reflog_Selector) = 0
                then ASCII.NUL else ASCII.LF));
            --  An explicit --notes shows the note under the line too.
            if Header.Notes_Explicit then
               declare
                  Block : constant String :=
                    Notes_Block (Repo, Current_Id, Header, 0);
               begin
                  if Block'Length > 0 then
                     Append (Result, Block (Block'First + 1 .. Block'Last));
                     Append_Line (Result, "");
                  end if;
               end;
            end if;
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
      Decorate      : Decorate_Mode := No_Decorate;
      Header        : Header_Options := (others => <>);
      Known         : Version.History.Commit_Id_Vectors.Vector :=
        Version.History.Commit_Id_Vectors.Empty_Vector) return String
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
           Decorate      => Decorate,
           Header        => (Header with delta Nul_Separated => False));

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
      --  Edges go to every parent the walk would show: with -<n> cutting
      --  the listing short, Known (the uncapped selection) says which.
      for C of Version.History.Commit_Id_Vectors.Vector'
        (if Known.Is_Empty then Commits else Known)
      loop
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
      Oneline        : Boolean := False;
      First_Parent   : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Paths          : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Rename_Score   : Natural := 0;
      Date_Mode      : String := "";
      Stat_Width      : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Base       : Version.Diff.Diff_Options := (others => <>);
      Header          : Header_Options := (others => <>);
      Separate_Merges : Boolean := False;
      Combined_Merges : Boolean := False;
      Dense_Combined  : Boolean := False;
      Format          : String := "";
      Terminate_Records : Boolean := True;
      Always_Show_Header : Boolean := False;
      Known           : Version.History.Commit_Id_Vectors.Vector :=
        Version.History.Commit_Id_Vectors.Empty_Vector)
      return String
   is
      Objects : Version.Object_Cache.Object_Cache;
      In_Set  : Id_Sets.Set;
      G       : Version.Log_Graph.Graph;
      Result  : Unbounded_String;
      First   : Boolean := True;
   begin
      for C of Version.History.Commit_Id_Vectors.Vector'
        (if Known.Is_Empty then Commits else Known)
      loop
         In_Set.Include (Version.Objects.To_String (C));
      end loop;

      Version.Log_Graph.Init (G);

      for I in Commits.First_Index .. Commits.Last_Index loop
         declare
            C   : constant Version.Objects.Hex_Object_Id := Commits.Element (I);
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
                  Oneline        => Oneline,
                  First_Parent   => First_Parent,
                  Kind           => Kind,
                  Show_Notes     => Show_Notes,
                  Paths          => Paths,
                  Rename_Score   => Rename_Score,
                  Date_Mode      => Date_Mode,
                  Stat_Width      => Stat_Width,
                  Stat_Name_Width => Stat_Name_Width,
                  Stat_Count      => Stat_Count,
                  Diff_Base       => Diff_Base,
                  Header          => (Header with delta
                                        Annotations => Note_Of (Header, I)),
                  Separate_Merges => Separate_Merges,
                  Combined_Merges => Combined_Merges,
                  Dense_Combined  => Dense_Combined,
                  Format          => Format,
                  Terminate_Records => Terminate_Records,
                  Always_Show_Header => Always_Show_Header));

            Version.Log_Graph.Update (G, C, Parents);

            --  git separates commits with a graph-prefixed blank line, drawn
            --  from the freshly updated (post-Update) lane state -- never
            --  for the oneline layout or a terminated custom format.
            if not First and then not Oneline
              and then not (Format'Length > 0 and then Terminate_Records)
            then
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

   function Log_Follow_Text
     (Repo           : Version.Repository.Repository_Handle;
      Start          : Version.Objects.Hex_Object_Id;
      Path           : String;
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
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Max_Count      : Natural := 0;
      Rename_Score   : Natural := 0;
      Date_Mode      : String := "";
      Stat_Width      : Natural := 0;
      Stat_Name_Width : Natural := 0;
      Stat_Count      : Natural := 0;
      Diff_Base       : Version.Diff.Diff_Options := (others => <>);
      Header          : Header_Options := (others => <>);
      Separate_Merges : Boolean := False;
      Combined_Merges : Boolean := False;
      Dense_Combined  : Boolean := False;
      Format          : String := "";
      Terminate_Records : Boolean := True;
      Always_Show_Header : Boolean := False)
      return String
   is
      Objects  : Version.Object_Cache.Object_Cache;
      Has_Diff : constant Boolean :=
        Stat or else Patch or else Name_Only or else Name_Status
        or else Numstat or else Shortstat or else Raw;

      Shown : Version.History.Commit_Id_Vectors.Vector;
      --  The file's name(s) to limit each shown commit's diff to: one name for
      --  an edit/add, or the old and new names at a rename (so it shows as R).
      package Name_Vectors is new Ada.Containers.Indefinite_Vectors
        (Index_Type => Natural, Element_Type => String);
      Old_Names : Name_Vectors.Vector;
      New_Names : Name_Vectors.Vector;

      --  Scan a rename-detected raw diff for the record whose child-side path
      --  is P: set Found, and for a rename Is_Rename plus the old Source name.
      procedure Scan_For_Path
        (Raw_Text  : String;
         P         : String;
         Found     : out Boolean;
         Is_Rename : out Boolean;
         Source    : out Unbounded_String)
      is
         Pos : Natural := Raw_Text'First;
      begin
         Found := False;
         Is_Rename := False;
         Source := Null_Unbounded_String;
         while Pos <= Raw_Text'Last loop
            declare
               Stop : Natural := Pos;
               Tab  : Natural := 0;
            begin
               while Stop <= Raw_Text'Last
                 and then Raw_Text (Stop) /= Character'Val (10)
               loop
                  if Raw_Text (Stop) = Character'Val (9) and then Tab = 0 then
                     Tab := Stop;
                  end if;
                  Stop := Stop + 1;
               end loop;

               if Tab > 0 and then Raw_Text (Pos) = ':' then
                  declare
                     Header : constant String := Raw_Text (Pos .. Tab - 1);
                     St     : Natural := Header'Last;
                     Letter : Character;
                     Paths  : constant String := Raw_Text (Tab + 1 .. Stop - 1);
                     P2     : Natural := 0;
                  begin
                     --  The status is the last space-separated field of the
                     --  header; its first character is A/M/D/T or R/C.
                     while St >= Header'First and then Header (St) /= ' ' loop
                        St := St - 1;
                     end loop;
                     Letter := Header (St + 1);

                     if Letter = 'R' or else Letter = 'C' then
                        for I in Paths'Range loop
                           if Paths (I) = Character'Val (9) then
                              P2 := I;
                              exit;
                           end if;
                        end loop;
                        if P2 > 0
                          and then Paths (P2 + 1 .. Paths'Last) = P
                        then
                           Found := True;
                           Is_Rename := True;
                           Source :=
                             To_Unbounded_String (Paths (Paths'First .. P2 - 1));
                        end if;
                     elsif Letter /= 'D' and then Paths = P then
                        Found := True;
                     end if;
                  end;
               end if;

               exit when Found;
               Pos := Stop + 1;
            end;
         end loop;
      end Scan_For_Path;

      Current : Version.Objects.Hex_Object_Id := Start;
      P       : Unbounded_String := To_Unbounded_String (Path);
      Result  : Unbounded_String;
      Detect  : constant Version.Diff.Diff_Options :=
        (Raw            => True,
         Detect_Renames => Version.Diff.Renames_On,
         others         => <>);
   begin
      loop
         declare
            Obj : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Current);
            Parent : constant String := Version.Objects.Commit_Parent_Id (Obj);
            Raw_Text : constant String :=
              (if Parent'Length > 0
               then Version.Diff.Diff_Commits
                      (Repo, Version.Objects.To_Object_Id (Parent),
                       Current, Detect)
               else Version.Diff.Diff_Root_Commit (Repo, Current, Detect));
            Found     : Boolean;
            Is_Rename : Boolean;
            Source    : Unbounded_String;
         begin
            Scan_For_Path (Raw_Text, To_String (P), Found, Is_Rename, Source);

            if Found then
               Shown.Append (Current);
               New_Names.Append (To_String (P));
               Old_Names.Append
                 (if Is_Rename then To_String (Source) else To_String (P));
               if Is_Rename then
                  P := Source;
               end if;
            end if;

            exit when Parent'Length = 0
              or else (Max_Count > 0
                       and then Natural (Shown.Length) >= Max_Count);
            Current := Version.Objects.To_Object_Id (Parent);
         end;
      end loop;

      --  Without a diff format the path only affects which commits show, so
      --  render the whole list in one pass.
      if not Has_Diff then
         return Log_List_Text
           (Repo, Shown,
            Show_Signature => Show_Signature,
            Oneline        => Oneline,
            Kind           => Kind,
            Show_Notes     => Show_Notes,
            Date_Mode      => Date_Mode);
      end if;

      --  Each commit's diff is limited to the file's name(s) at that commit,
      --  so a rename renders as an R record rather than an add.
      for I in Shown.First_Index .. Shown.Last_Index loop
         declare
            One  : Version.History.Commit_Id_Vectors.Vector;
            Spec : Version.Pathspec.Pathspec_Vectors.Vector;
         begin
            One.Append (Shown (I));
            Version.Pathspec.Append_Parse (Spec, New_Names (I), "");
            if Old_Names (I) /= New_Names (I) then
               Version.Pathspec.Append_Parse (Spec, Old_Names (I), "");
            end if;

            if I > Shown.First_Index and then not Oneline then
               Append (Result, Character'Val (10));
            end if;

            Append
              (Result,
               Log_List_Text
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
                  Oneline        => Oneline,
                  Kind           => Kind,
                  Show_Notes     => Show_Notes,
                  Paths          => Spec,
                  Rename_Score   => Rename_Score,
                  Date_Mode      => Date_Mode,
                  Stat_Width      => Stat_Width,
                  Stat_Name_Width => Stat_Name_Width,
                  Stat_Count      => Stat_Count,
                  Diff_Base       => Diff_Base,
                  Header          => Header,
                  Separate_Merges => Separate_Merges,
                  Combined_Merges => Combined_Merges,
                  Dense_Combined  => Dense_Combined,
                  Format          => Format,
                  Terminate_Records => Terminate_Records,
                  Always_Show_Header => Always_Show_Header));
         end;
      end loop;

      return To_String (Result);
   end Log_Follow_Text;

   function Log_Formatted_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Format  : String;
      Terminate_Records : Boolean := True;
      Date_Mode : String := "";
      Header    : Header_Options := (others => <>)) return String
   is
      LF      : constant Character := Character'Val (10);
      Result  : Unbounded_String;
      First   : Boolean := True;
      --  -z: NUL where the record terminator / separator would go.
      Sep     : constant Character :=
        (if Header.Nul_Separated then ASCII.NUL else LF);
   begin
      for Index in Commits.First_Index .. Commits.Last_Index loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Commits.Element (Index);
            Note : constant Annotation := Note_At (Header, Index);
            Text : constant String :=
              Version.Pretty_Format.Expand
                (Repo, Current_Id, Format, Date_Mode,
                 Reflog => (Selector => Note.Reflog_Selector,
                            Ident    => Note.Reflog_Ident,
                            Message  => Note.Reflog_Message));
         begin
            if not First and then not Terminate_Records then
               Append (Result, Sep);
            end if;
            First := False;
            --  --log-size names the record's length ahead of it.
            if Header.Log_Size then
               declare
                  Img : constant String := Natural'Image (Text'Length);
               begin
                  Append (Result, "log size " & Img (Img'First + 1 .. Img'Last) & LF);
               end;
            end if;
            Append (Result, Text);
            if Terminate_Records then
               Append (Result, Sep);
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
