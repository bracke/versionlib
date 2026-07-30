with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Characters.Handling;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
with Version.Config;
with Version.Files;
with Version.Objects;
with Version.Refs;
with Version.Tracking;
with Version.Reftable;
with Version.Packed_Refs;

package body Version.Ref_Format is

   HT : constant Character := Character'Val (9);

   ----------------------------------------------------------------------
   --  Date formatting
   ----------------------------------------------------------------------

   Weekday_Names : constant array (0 .. 6) of String (1 .. 3) :=
     ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
   Month_Names   : constant array (1 .. 12) of String (1 .. 3) :=
     ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

   function Pad2 (N : Integer) return String is
      S : constant String := Ada.Strings.Fixed.Trim (Integer'Image (N),
                                                      Ada.Strings.Left);
   begin
      return (if N < 10 then "0" & S else S);
   end Pad2;

   function Img (N : Long_Long_Integer) return String is
   begin
      return Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (N),
                                      Ada.Strings.Left);
   end Img;

   function Git_Date
     (Ident_Value : String;
      Modifier    : String := "")
      return String
   is
      --  Ident_Value is "<unixtime> <tz>", e.g. "1600000000 +0200".
      Sp   : constant Natural :=
        Ada.Strings.Fixed.Index (Ident_Value, " ");
      Unix : Long_Long_Integer;
      TZ   : String (1 .. 5) := "+0000";

      Sign      : Long_Long_Integer := 1;
      TZ_Min    : Long_Long_Integer := 0;
      Local     : Long_Long_Integer;
      Days      : Long_Long_Integer;
      Secs      : Long_Long_Integer;
      Z, Era, DOE, YOE, DOY, MP : Long_Long_Integer;
      Y_Civil   : Long_Long_Integer;
      Year, Month, Day, Hour, Minute, Second, WD : Integer;
   begin
      if Ident_Value'Length = 0 or else Sp = 0 then
         return Ident_Value;
      end if;

      Unix := Long_Long_Integer'Value
        (Ident_Value (Ident_Value'First .. Sp - 1));

      declare
         Rest : constant String :=
           Ada.Strings.Fixed.Trim
             (Ident_Value (Sp + 1 .. Ident_Value'Last), Ada.Strings.Both);
      begin
         if Rest'Length = 5 then
            TZ := Rest;
         end if;
      end;

      if Modifier = "unix" then
         return Img (Unix);
      elsif Modifier = "raw" then
         return Img (Unix) & " " & TZ;
      end if;

      --  Apply the timezone offset to obtain the displayed local time.
      if TZ (TZ'First) = '-' then
         Sign := -1;
      end if;
      TZ_Min :=
        Long_Long_Integer'Value (TZ (TZ'First + 1 .. TZ'First + 2)) * 60
        + Long_Long_Integer'Value (TZ (TZ'First + 3 .. TZ'First + 4));
      Local := Unix + Sign * TZ_Min * 60;

      Days := Local / 86_400;
      Secs := Local mod 86_400;
      if Secs < 0 then
         Secs := Secs + 86_400;
         Days := Days - 1;
      end if;

      Hour   := Integer (Secs / 3_600);
      Minute := Integer ((Secs mod 3_600) / 60);
      Second := Integer (Secs mod 60);

      --  Weekday: 1970-01-01 was a Thursday (index 4, Sun=0).
      WD := Integer ((Days mod 7 + 4 + 7) mod 7);

      --  Civil date from days since the Unix epoch (Howard Hinnant).
      Z   := Days + 719_468;
      Era := (if Z >= 0 then Z else Z - 146_096) / 146_097;
      DOE := Z - Era * 146_097;
      YOE := (DOE - DOE / 1_460 + DOE / 36_524 - DOE / 146_096) / 365;
      Y_Civil := YOE + Era * 400;
      DOY := DOE - (365 * YOE + YOE / 4 - YOE / 100);
      MP  := (5 * DOY + 2) / 153;
      Day := Integer (DOY - (153 * MP + 2) / 5 + 1);
      Month := Integer (if MP < 10 then MP + 3 else MP - 9);
      if Month <= 2 then
         Y_Civil := Y_Civil + 1;
      end if;
      Year := Integer (Y_Civil);

      if Modifier = "short" then
         return Img (Long_Long_Integer (Year)) & "-" & Pad2 (Month)
           & "-" & Pad2 (Day);
      elsif Modifier = "iso" or else Modifier = "iso8601" then
         return Img (Long_Long_Integer (Year)) & "-" & Pad2 (Month) & "-"
           & Pad2 (Day) & " " & Pad2 (Hour) & ":" & Pad2 (Minute) & ":"
           & Pad2 (Second) & " " & TZ;
      elsif Modifier = "iso-strict" or else Modifier = "iso8601-strict" then
         return Img (Long_Long_Integer (Year)) & "-" & Pad2 (Month) & "-"
           & Pad2 (Day) & "T" & Pad2 (Hour) & ":" & Pad2 (Minute) & ":"
           & Pad2 (Second) & TZ (TZ'First .. TZ'First + 2) & ":"
           & TZ (TZ'First + 3 .. TZ'First + 4);
      else
         --  Default git date: "Www Mmm D HH:MM:SS YYYY +ZZZZ".
         return Weekday_Names (WD) & " " & Month_Names (Month) & " "
           & Img (Long_Long_Integer (Day)) & " " & Pad2 (Hour) & ":"
           & Pad2 (Minute) & ":" & Pad2 (Second) & " "
           & Img (Long_Long_Integer (Year)) & " " & TZ;
      end if;
   end Git_Date;

   ----------------------------------------------------------------------
   --  Pattern matching (git for-each-ref semantics)
   ----------------------------------------------------------------------

   function Has_Glob (P : String) return Boolean is
   begin
      for C of P loop
         if C = '*' or else C = '?' or else C = '[' then
            return True;
         end if;
      end loop;
      return False;
   end Has_Glob;

   --  wildmatch with WM_PATHNAME: '*' does not cross '/', '**' does.
   function Wildmatch (Pat, Text : String) return Boolean is
      function M (Pi, Ti : Integer) return Boolean is
         P : Integer := Pi;
         T : Integer := Ti;
      begin
         while P <= Pat'Last loop
            declare
               PC : constant Character := Pat (P);
            begin
               if PC = '?' then
                  if T > Text'Last or else Text (T) = '/' then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
               elsif PC = '*' then
                  --  Detect "**".
                  if P < Pat'Last and then Pat (P + 1) = '*' then
                     --  Consume runs of '*'.
                     while P <= Pat'Last and then Pat (P) = '*' loop
                        P := P + 1;
                     end loop;
                     --  '**' matches everything including '/'.
                     if P > Pat'Last then
                        return True;
                     end if;
                     for K in T .. Text'Last + 1 loop
                        if M (P, K) then
                           return True;
                        end if;
                     end loop;
                     return False;
                  else
                     P := P + 1;
                     --  Single '*' matches within a path segment.
                     for K in T .. Text'Last + 1 loop
                        if M (P, K) then
                           return True;
                        end if;
                        exit when K > Text'Last or else Text (K) = '/';
                     end loop;
                     return False;
                  end if;
               elsif PC = '[' then
                  if T > Text'Last or else Text (T) = '/' then
                     return False;
                  end if;
                  declare
                     Q       : Integer := P + 1;
                     Negate  : Boolean := False;
                     Matched : Boolean := False;
                  begin
                     if Q <= Pat'Last
                       and then (Pat (Q) = '!' or else Pat (Q) = '^')
                     then
                        Negate := True;
                        Q := Q + 1;
                     end if;
                     while Q <= Pat'Last and then Pat (Q) /= ']' loop
                        if Q + 2 <= Pat'Last and then Pat (Q + 1) = '-'
                          and then Pat (Q + 2) /= ']'
                        then
                           if Text (T) >= Pat (Q)
                             and then Text (T) <= Pat (Q + 2)
                           then
                              Matched := True;
                           end if;
                           Q := Q + 3;
                        else
                           if Text (T) = Pat (Q) then
                              Matched := True;
                           end if;
                           Q := Q + 1;
                        end if;
                     end loop;
                     if Q > Pat'Last then
                        return False;   --  unterminated class
                     end if;
                     if Matched = Negate then
                        return False;
                     end if;
                     P := Q + 1;
                     T := T + 1;
                  end;
               else
                  if T > Text'Last or else Text (T) /= PC then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
               end if;
            end;
         end loop;
         return T > Text'Last;
      end M;
   begin
      return M (Pat'First, Text'First);
   end Wildmatch;

   function Ref_Matches (Pattern, Ref : String) return Boolean is
   begin
      if Pattern'Length = 0 then
         return True;
      elsif Has_Glob (Pattern) then
         return Wildmatch (Pattern, Ref);
      else
         --  Literal: full match, or prefix ending at a slash boundary.
         if Ref = Pattern then
            return True;
         end if;
         declare
            --  A trailing slash in the pattern is optional.
            Effective_Last : constant Natural :=
              (if Pattern (Pattern'Last) = '/'
               then Pattern'Last - 1 else Pattern'Last);
            P : constant String :=
              Pattern (Pattern'First .. Effective_Last);
         begin
            return Ref'Length > P'Length
              and then Ref (Ref'First .. Ref'First + P'Length - 1) = P
              and then Ref (Ref'First + P'Length) = '/';
         end;
      end if;
   end Ref_Matches;

   function Matches_Any
     (Patterns : String_Vectors.Vector; Ref : String) return Boolean is
   begin
      if Patterns.Is_Empty then
         return True;
      end if;
      for P of Patterns loop
         if Ref_Matches (P, Ref) then
            return True;
         end if;
      end loop;
      return False;
   end Matches_Any;

   ----------------------------------------------------------------------
   --  Ref enumeration
   ----------------------------------------------------------------------

   type Ref_Row is record
      Name : Unbounded_String;
      Id   : Unbounded_String;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors (Positive, Ref_Row);

   function Contains_Name
     (Rows : Row_Vectors.Vector; Name : String) return Boolean is
   begin
      for R of Rows loop
         if To_String (R.Name) = Name then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Name;

   procedure Walk_Loose
     (Repo : Version.Repository.Repository_Handle;
      Base : String;
      Rel  : String;
      Rows : in out Row_Vectors.Vector)
   is
      use Ada.Directories;
      Dir : constant String :=
        (if Rel = "" then Base else Base & "/" & Rel);
      Search : Search_Type;
      Item   : Directory_Entry_Type;
   begin
      if not Exists (Dir) or else Kind (Dir) /= Directory then
         return;
      end if;
      Start_Search (Search, Dir, "",
                    [Directory | Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         declare
            Simple : constant String := Simple_Name (Item);
         begin
            if Simple /= "." and then Simple /= ".." then
               declare
                  Child_Rel : constant String :=
                    (if Rel = "" then Simple else Rel & "/" & Simple);
               begin
                  if Kind (Item) = Directory then
                     Walk_Loose (Repo, Base, Child_Rel, Rows);
                  else
                     declare
                        Full : constant String := "refs/" & Child_Rel;
                     begin
                        Rows.Append
                          (Ref_Row'
                             (Name => To_Unbounded_String (Full),
                              Id   => To_Unbounded_String
                                (Version.Objects.To_String
                                   (Version.Refs.Resolve_Ref (Repo, Full)))));
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      End_Search (Search);
   end Walk_Loose;

   function Enumerate
     (Repo : Version.Repository.Repository_Handle) return Row_Vectors.Vector
   is
      Rows : Row_Vectors.Vector;
      Base : constant String :=
        Version.Repository.Common_Git_Dir (Repo) & "/refs";
   begin
      if Version.Reftable.Is_Reftable (Repo) then
         for R of Version.Reftable.Live_Refs (Repo) loop
            declare
               Name : constant String := To_String (R.Name);
               use type Version.Reftable.Ref_Value_Kind;
            begin
               if Name'Length > 5
                 and then Name (Name'First .. Name'First + 4) = "refs/"
               then
                  Rows.Append
                    (Ref_Row'
                       (Name => R.Name,
                        Id   => To_Unbounded_String
                          ((if R.Kind = Version.Reftable.Ref_Symref
                            then Version.Objects.To_String
                                   (Version.Refs.Resolve_Ref (Repo, Name))
                            else Version.Objects.To_String (R.Id)))));
               end if;
            end;
         end loop;
         return Rows;
      end if;

      Walk_Loose (Repo, Base, "", Rows);
      --  Packed refs that are not shadowed by a loose ref.
      for PR of Version.Packed_Refs.Read_All (Repo) loop
         declare
            Name : constant String := To_String (PR.Name);
         begin
            if Name'Length > 5
              and then Name (Name'First .. Name'First + 4) = "refs/"
              and then not Contains_Name (Rows, Name)
            then
               Rows.Append
                 (Ref_Row'
                    (Name => PR.Name,
                     Id   => To_Unbounded_String
                       (Version.Objects.To_String (PR.Id))));
            end if;
         end;
      end loop;
      return Rows;
   end Enumerate;

   ----------------------------------------------------------------------
   --  Field access
   ----------------------------------------------------------------------

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   --  git's %(refname:lstrip=N)/:rstrip=N. A positive N removes that many
   --  components from the given end; a negative one keeps that many from the
   --  opposite end. Stripping more components than there are yields the empty
   --  string, as in git.
   function Strip_Components
     (Ref : String; Count_Text : String; From_Left : Boolean) return String
   is
      type Bound_Array is array (Positive range <>) of Natural;
      Slashes : Bound_Array (1 .. Ref'Length + 1);
      Parts   : Natural := 0;
      N       : Integer;
   begin
      begin
         N := Integer'Value (Count_Text);
      exception
         when others =>
            raise Ada.IO_Exceptions.Data_Error with
              "unrecognized %(refname) argument: " & Count_Text;
      end;

      --  Component boundaries: Slashes (I) is the index before component I.
      Parts := 1;
      Slashes (1) := Ref'First - 1;
      for I in Ref'Range loop
         if Ref (I) = '/' then
            Parts := Parts + 1;
            Slashes (Parts) := I;
         end if;
      end loop;

      declare
         --  Turn every form into "how many leading components to drop" and
         --  "how many to keep".
         Drop : Natural;
         Keep : Natural;
      begin
         if From_Left then
            Drop := (if N >= 0 then Natural'Min (N, Parts)
                     else Natural'Max (Parts + N, 0));
            Keep := Parts - Drop;
         else
            Keep := (if N >= 0 then Natural'Max (Parts - N, 0)
                     else Natural'Min (-N, Parts));
            Drop := 0;
         end if;

         if Keep = 0 then
            return "";
         end if;

         declare
            First : constant Natural := Slashes (Drop + 1) + 1;
            Last  : constant Natural :=
              (if Drop + Keep >= Parts then Ref'Last
               else Slashes (Drop + Keep + 1) - 1);
         begin
            return Ref (First .. Last);
         end;
      end;
   end Strip_Components;

   function Short_Name (Ref : String) return String is
      procedure Try (Prefix : String; Out_S : in out Unbounded_String) is
      begin
         if Out_S = Null_Unbounded_String
           and then Ref'Length > Prefix'Length
           and then Ref (Ref'First .. Ref'First + Prefix'Length - 1) = Prefix
         then
            Out_S := To_Unbounded_String
              (Ref (Ref'First + Prefix'Length .. Ref'Last));
         end if;
      end Try;
      Result : Unbounded_String;
   begin
      --  A remote's HEAD shortens to the remote itself: "origin", not
      --  "origin/HEAD". git does this because `origin` already names that
      --  ref, so the longer form is never the shortest unambiguous one.
      if Ref'Length > 13
        and then Ref (Ref'First .. Ref'First + 12) = "refs/remotes/"
        and then Ref'Length > 5
        and then Ref (Ref'Last - 4 .. Ref'Last) = "/HEAD"
      then
         return Ref (Ref'First + 13 .. Ref'Last - 5);
      end if;

      Try ("refs/heads/", Result);
      Try ("refs/tags/", Result);
      Try ("refs/remotes/", Result);
      if Result = Null_Unbounded_String then
         return Ref;
      end if;
      return To_String (Result);
   end Short_Name;

   function Line_Value (Text, Key : String) return String is
      --  First line beginning with Key, value = remainder of that line.
      Pos : Natural := Text'First;
   begin
      while Pos <= Text'Last loop
         declare
            Stop : Natural := Pos;
         begin
            while Stop <= Text'Last
              and then Text (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;
            if Stop - Pos >= Key'Length
              and then Text (Pos .. Pos + Key'Length - 1) = Key
            then
               return Text (Pos + Key'Length .. Stop - 1);
            end if;
            --  Stop at the blank line that precedes the message body.
            exit when Stop = Pos;
            Pos := Stop + 1;
         end;
      end loop;
      return "";
   end Line_Value;

   function Ident_Name (Ident : String) return String is
      LT : constant Natural := Ada.Strings.Fixed.Index (Ident, " <");
   begin
      if LT = 0 then
         return Ident;
      end if;
      return Ident (Ident'First .. LT - 1);
   end Ident_Name;

   function Ident_Email (Ident : String) return String is
      LT : constant Natural := Ada.Strings.Fixed.Index (Ident, "<");
      GT : constant Natural := Ada.Strings.Fixed.Index (Ident, ">");
   begin
      if LT = 0 or else GT = 0 or else GT < LT then
         return "";
      end if;
      return Ident (LT .. GT);   --  git's %(authoremail) includes < >
   end Ident_Email;

   function Ident_Date (Ident : String) return String is
      GT : Natural := 0;
   begin
      for I in reverse Ident'Range loop
         if Ident (I) = '>' then
            GT := I;
            exit;
         end if;
      end loop;
      if GT = 0 or else GT + 2 > Ident'Last then
         return "";
      end if;
      return Ident (GT + 2 .. Ident'Last);
   end Ident_Date;

   function Subject_Of (Text : String) return String is
      --  Message subject: first paragraph after the blank line, joined.
      Pos   : Natural := Text'First;
      Blank : Natural := 0;
   begin
      while Pos <= Text'Last loop
         if Text (Pos) = Character'Val (10)
           and then Pos < Text'Last
           and then Text (Pos + 1) = Character'Val (10)
         then
            Blank := Pos + 2;
            exit;
         end if;
         Pos := Pos + 1;
      end loop;
      if Blank = 0 then
         return "";
      end if;
      declare
         Stop : Natural := Blank;
      begin
         while Stop <= Text'Last
           and then Text (Stop) /= Character'Val (10)
         loop
            Stop := Stop + 1;
         end loop;
         return Text (Blank .. Stop - 1);
      end;
   end Subject_Of;

   ----------------------------------------------------------------------
   --  %(atom) expansion
   ----------------------------------------------------------------------

   function Expand
     (Repo   : Version.Repository.Repository_Handle;
      Format : String;
      Ref    : String;
      Id     : String;
      Head   : String;
      Quote  : String := "")
      return String
   is
      Result : Unbounded_String;
      I      : Natural := Format'First;

      --  for-each-ref's host-language modes quote each atom's VALUE (not the
      --  literal text between atoms): --shell/--perl/--python in single quotes,
      --  --tcl in double quotes, each with that language's escaping.
      function Quote_Value (S : String) return String is
         Out_Text : Unbounded_String;
      begin
         if Quote = "" then
            return S;
         elsif Quote = "tcl" then
            Append (Out_Text, '"');
            for C of S loop
               if C = '"' or else C = '\' or else C = '$'
                 or else C = '[' or else C = ']'
               then
                  Append (Out_Text, '\');
               end if;
               Append (Out_Text, C);
            end loop;
            Append (Out_Text, '"');
         elsif Quote = "shell" then
            Append (Out_Text, ''');
            for C of S loop
               if C = ''' then
                  Append (Out_Text, "'\''");
               else
                  Append (Out_Text, C);
               end if;
            end loop;
            Append (Out_Text, ''');
         else
            --  perl and python: single quotes, backslash-escaping ' and \.
            Append (Out_Text, ''');
            for C of S loop
               if C = ''' or else C = '\' then
                  Append (Out_Text, '\');
               end if;
               Append (Out_Text, C);
            end loop;
            Append (Out_Text, ''');
         end if;
         return To_String (Out_Text);
      end Quote_Value;

      Obj  : constant Version.Objects.Git_Object :=
        Version.Objects.Read_Object (Repo, Version.Objects.To_Object_Id (Id));
      Kind : constant Version.Objects.Object_Kind :=
        Version.Objects.Kind (Obj);

      function Type_Name return String is
        (case Kind is
            when Version.Objects.Commit_Object => "commit",
            when Version.Objects.Tag_Object    => "tag",
            when Version.Objects.Tree_Object   => "tree",
            when Version.Objects.Blob_Object   => "blob",
            when others                        => "unknown");

      function Content return String is (Version.Objects.Content (Obj));

      --  The message after the header block (git's %(contents)); "" if none.
      function Full_Message (Text : String) return String is
         Pos : Natural := Text'First;
      begin
         while Pos < Text'Last loop
            if Text (Pos) = Character'Val (10)
              and then Text (Pos + 1) = Character'Val (10)
            then
               return Text (Pos + 2 .. Text'Last);
            end if;
            Pos := Pos + 1;
         end loop;
         return "";
      end Full_Message;

      --  git's %(body): the message past the subject's first paragraph.
      function Body_Of (Text : String) return String is
         Msg : constant String := Full_Message (Text);
         Pos : Natural := Msg'First;
      begin
         while Pos < Msg'Last loop
            if Msg (Pos) = Character'Val (10)
              and then Msg (Pos + 1) = Character'Val (10)
            then
               return Msg (Pos + 2 .. Msg'Last);
            end if;
            Pos := Pos + 1;
         end loop;
         return "";
      end Body_Of;

      --  git's %(creator*): the tagger for a tag, else the committer.
      function Creator_Line (Text : String) return String is
         Tagger : constant String := Line_Value (Text, "tagger ");
      begin
         if Tagger'Length > 0 then
            return Tagger;
         end if;
         return Line_Value (Text, "committer ");
      end Creator_Line;

      --  An annotated tag's target: the "object <sha>" it names, peeled
      --  through any tag-of-tag chain to a non-tag. "" when Obj is not a tag.
      function Peeled_Id return String is
         Cur     : Version.Objects.Git_Object := Obj;
         Cur_Id  : Unbounded_String := To_Unbounded_String (Id);
      begin
         if not Version.Objects."=" (Kind, Version.Objects.Tag_Object) then
            return "";
         end if;
         loop
            declare
               Target : constant String :=
                 Line_Value (Version.Objects.Content (Cur), "object ");
            begin
               exit when Target'Length = 0;
               Cur_Id := To_Unbounded_String (Target);
               Cur :=
                 Version.Objects.Read_Object
                   (Repo, Version.Objects.To_Object_Id (Target));
               exit when not Version.Objects."="
                             (Version.Objects.Kind (Cur),
                              Version.Objects.Tag_Object);
            end;
         end loop;
         return To_String (Cur_Id);
      exception
         when others =>
            return "";
      end Peeled_Id;

      function Atom_Value (Atom : String) return String is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Atom, ":");
         Head_A : constant String :=
           (if Colon = 0 then Atom else Atom (Atom'First .. Colon - 1));
         Arg    : constant String :=
           (if Colon = 0 then "" else Atom (Colon + 1 .. Atom'Last));
      begin
         --  A leading '*' asks for the DEREFERENCED object: for an annotated
         --  tag, the thing it points to; empty for anything else. Re-run the
         --  same atom against the peeled object.
         if Head_A'Length >= 1 and then Head_A (Head_A'First) = '*' then
            declare
               Peeled : constant String := Peeled_Id;
            begin
               if Peeled'Length = 0 then
                  return "";
               end if;
               return Expand
                 (Repo,
                  "%(" & Atom (Atom'First + 1 .. Atom'Last) & ")",
                  Ref, Peeled, Head);
            end;
         end if;

         if Head_A = "refname" then
            if Arg = "" then
               return Ref;
            elsif Arg = "short" then
               return Short_Name (Ref);
            elsif Starts_With (Arg, "lstrip=")
              or else Starts_With (Arg, "rstrip=")
            then
               return Strip_Components
                 (Ref,
                  Arg (Arg'First + 7 .. Arg'Last),
                  From_Left => Arg (Arg'First) = 'l');
            else
               --  Silently handing back the whole refname for a modifier we
               --  do not know is worse than refusing: the caller gets a
               --  plausible answer to a question we did not understand.
               raise Ada.IO_Exceptions.Data_Error with
                 "unrecognized %(refname) argument: " & Arg;
            end if;
         elsif Head_A = "objectname" then
            if Arg = "short" then
               return Id (Id'First .. Id'First + 6);
            elsif Arg'Length > 6 and then Arg (Arg'First .. Arg'First + 5)
                    = "short="
            then
               declare
                  N : constant Natural :=
                    Natural'Value (Arg (Arg'First + 6 .. Arg'Last));
               begin
                  return Id (Id'First .. Id'First + N - 1);
               end;
            else
               return Id;
            end if;
         elsif Head_A = "objecttype" then
            return Type_Name;
         elsif Head_A = "object" then
            --  An annotated tag's "object" header (the target id); empty for a
            --  non-tag object, as git's %(object)/%(type)/%(tag) are.
            return Line_Value (Content, "object ");
         elsif Head_A = "type" then
            return Line_Value (Content, "type ");
         elsif Head_A = "tag" then
            return Line_Value (Content, "tag ");
         elsif Head_A = "objectsize" then
            return Ada.Strings.Fixed.Trim
              (Integer'Image (Version.Objects.Content (Obj)'Length),
               Ada.Strings.Left);
         elsif Head_A = "HEAD" then
            return (if Ref = Head then "*" else " ");
         elsif Head_A = "subject" or else Atom = "contents:subject" then
            return Subject_Of (Content);
         elsif Head_A = "authorname" then
            return Ident_Name (Line_Value (Content, "author "));
         elsif Head_A = "authoremail" then
            return Ident_Email (Line_Value (Content, "author "));
         elsif Head_A = "authordate" then
            return Git_Date (Ident_Date (Line_Value (Content, "author ")),
                             Arg);
         elsif Head_A = "committername" then
            return Ident_Name (Line_Value (Content, "committer "));
         elsif Head_A = "committeremail" then
            return Ident_Email (Line_Value (Content, "committer "));
         elsif Head_A = "committerdate" then
            return Git_Date (Ident_Date (Line_Value (Content, "committer ")),
                             Arg);
         elsif Head_A = "taggername" then
            return Ident_Name (Line_Value (Content, "tagger "));
         elsif Head_A = "taggeremail" then
            return Ident_Email (Line_Value (Content, "tagger "));
         elsif Head_A = "taggerdate" then
            return Git_Date (Ident_Date (Line_Value (Content, "tagger ")),
                             Arg);
         elsif Head_A = "upstream" then
            --  A branch's configured upstream, as a remote-tracking ref (empty
            --  when the ref is not a branch or has no upstream).
            if Ref'Length > 11
              and then Ref (Ref'First .. Ref'First + 10) = "refs/heads/"
              and then Version.Tracking.Has_Upstream (Repo, Short_Name (Ref))
            then
               declare
                  Full : constant String :=
                    Version.Tracking.Remote_Tracking_Ref
                      (Version.Tracking.Upstream (Repo, Short_Name (Ref)));
               begin
                  --  %(upstream:short) drops the "refs/remotes/" prefix.
                  if Arg = "short"
                    and then Full'Length > 13
                    and then Full (Full'First .. Full'First + 12)
                             = "refs/remotes/"
                  then
                     return Full (Full'First + 13 .. Full'Last);
                  elsif Arg = "track" or else Arg = "trackshort" then
                     --  How this branch stands against its upstream, not the
                     --  upstream's name. Substituting the name for it was a
                     --  silently wrong answer in a field scripts read to
                     --  decide whether to push.
                     declare
                        AB : constant Version.Tracking.Ahead_Behind :=
                          Version.Tracking.Count_Ahead_Behind
                            (Repo, Short_Name (Ref));
                        A : constant String :=
                          Ada.Strings.Fixed.Trim
                            (Natural'Image (AB.Ahead), Ada.Strings.Left);
                        B : constant String :=
                          Ada.Strings.Fixed.Trim
                            (Natural'Image (AB.Behind), Ada.Strings.Left);
                     begin
                        if Arg = "trackshort" then
                           if AB.Ahead > 0 and then AB.Behind > 0 then
                              return "<>";
                           elsif AB.Ahead > 0 then
                              return ">";
                           elsif AB.Behind > 0 then
                              return "<";
                           else
                              return "=";
                           end if;
                        elsif AB.Ahead > 0 and then AB.Behind > 0 then
                           return "[ahead " & A & ", behind " & B & "]";
                        elsif AB.Ahead > 0 then
                           return "[ahead " & A & "]";
                        elsif AB.Behind > 0 then
                           return "[behind " & B & "]";
                        else
                           return "";
                        end if;
                     end;
                  else
                     return Full;
                  end if;
               end;
            else
               return "";
            end if;
         elsif Head_A = "push" then
            --  Where the branch would be pushed, as a remote-tracking ref: the
            --  push remote (branch.<x>.pushRemote, else remote.pushDefault,
            --  else branch.<x>.remote) with the same branch name, which is
            --  git's default (push.default=simple) mapping.
            if Ref'Length > 11
              and then Ref (Ref'First .. Ref'First + 10) = "refs/heads/"
            then
               declare
                  Short : constant String := Short_Name (Ref);
                  function Cfg (Key : String) return String is
                    (if Version.Config.Has_Key (Repo, Key)
                     then Version.Config.Get_Value (Repo, Key) else "");
                  Remote : constant String :=
                    (if Cfg ("branch." & Short & ".pushRemote") /= ""
                     then Cfg ("branch." & Short & ".pushRemote")
                     elsif Cfg ("remote.pushDefault") /= ""
                     then Cfg ("remote.pushDefault")
                     else Cfg ("branch." & Short & ".remote"));
               begin
                  if Remote = "" then
                     return "";
                  elsif Arg = "short" then
                     return Remote & "/" & Short;
                  else
                     return "refs/remotes/" & Remote & "/" & Short;
                  end if;
               end;
            else
               return "";
            end if;
         elsif Head_A = "contents" then
            --  Bare %(contents) is the whole message; :subject is handled
            --  above, :body falls through to Body_Of.
            if Arg = "body" then
               return Body_Of (Content);
            elsif Arg = "" then
               return Full_Message (Content);
            else
               return Full_Message (Content);
            end if;
         elsif Head_A = "body" then
            return Body_Of (Content);
         elsif Head_A = "creator" then
            return Creator_Line (Content);
         elsif Head_A = "creatordate" then
            return Git_Date (Ident_Date (Creator_Line (Content)), Arg);
         elsif Head_A = "color" then
            --  Color is suppressed when the output is not a terminal, which
            --  is always the case here, so every %(color:...) is empty.
            return "";
         elsif Head_A = "symref" then
            --  A symbolic ref (e.g. refs/remotes/origin/HEAD) stores
            --  "ref: <target>"; a direct ref has no symref.
            declare
               Path : constant String :=
                 Version.Files.Join (Version.Repository.Git_Dir (Repo), Ref);
            begin
               if Version.Files.Is_Ordinary_File (Path) then
                  declare
                     Raw  : constant String :=
                       Version.Files.Read_Binary_File (Path);
                     Last : Natural := Raw'Last;
                  begin
                     while Last >= Raw'First
                       and then (Raw (Last) = Character'Val (10)
                                 or else Raw (Last) = Character'Val (13))
                     loop
                        Last := Last - 1;
                     end loop;
                     if Last - Raw'First + 1 > 5
                       and then Raw (Raw'First .. Raw'First + 4) = "ref: "
                     then
                        declare
                           Target : constant String :=
                             Raw (Raw'First + 5 .. Last);
                        begin
                           if Arg = "short" then
                              return Short_Name (Target);
                           end if;
                           return Target;
                        end;
                     end if;
                  end;
               end if;
               return "";
            exception
               when others =>
                  return "";
            end;
         else
            raise Constraint_Error
              with "unknown for-each-ref field: " & Atom;
         end if;
      end Atom_Value;


   --  Block constructs -- %(align:...)...%(end) and %(if)...%(then)...
   --  %(else)...%(end) -- wrap other atoms, so they are handled by scanning
   --  to the matching %(end) (counting nesting) and expanding the body.
   function Opener_At (Pos : Natural) return String is
   begin
      --  The atom name of a "%(...)" starting at Pos, or "" if not one.
      if Pos + 1 <= Format'Last
        and then Format (Pos) = '%' and then Format (Pos + 1) = '('
      then
         for K in Pos + 2 .. Format'Last loop
            exit when Format (K) = ')' or else Format (K) = ':';
            if Format (K) not in 'a' .. 'z' then
               return "";
            end if;
         end loop;
         declare
            Stop : Natural := Pos + 2;
         begin
            while Stop <= Format'Last
              and then Format (Stop) /= ')' and then Format (Stop) /= ':'
            loop
               Stop := Stop + 1;
            end loop;
            return Format (Pos + 2 .. Stop - 1);
         end;
      end if;
      return "";
   end Opener_At;

   --  The index of the '%' of the %(end) that closes the block opened at
   --  From (which is the '%' of the opener). Nested align/if are balanced.
   function Matching_End (From : Natural) return Natural is
      Depth : Natural := 0;
      K     : Natural := From;
   begin
      while K <= Format'Last loop
         if K + 1 <= Format'Last and then Format (K) = '%'
           and then Format (K + 1) = '('
         then
            declare
               Head : constant String := Opener_At (K);
            begin
               if Head = "align" or else Head = "if" then
                  Depth := Depth + 1;
               elsif Head = "end" then
                  Depth := Depth - 1;
                  if Depth = 0 then
                     return K;
                  end if;
               end if;
            end;
         end if;
         K := K + 1;
      end loop;
      return 0;
   end Matching_End;

   --  The index of the '%' of a top-level %(<Tok>) inside Body (nested blocks
   --  skipped), or 0.
   function Top_Level (Body_Str : String; Tok : String) return Natural is
      Depth : Natural := 0;
      K     : Natural := Body_Str'First;
   begin
      while K <= Body_Str'Last loop
         if K + 1 <= Body_Str'Last and then Body_Str (K) = '%'
           and then Body_Str (K + 1) = '('
         then
            declare
               Stop : Natural := K + 2;
            begin
               while Stop <= Body_Str'Last
                 and then Body_Str (Stop) /= ')'
                 and then Body_Str (Stop) /= ':'
               loop
                  Stop := Stop + 1;
               end loop;
               declare
                  Head : constant String := Body_Str (K + 2 .. Stop - 1);
               begin
                  if Head = "align" or else Head = "if" then
                     Depth := Depth + 1;
                  elsif Head = "end" then
                     Depth := Depth - 1;
                  elsif Depth = 0 and then Head = Tok then
                     return K;
                  end if;
               end;
            end;
         end if;
         K := K + 1;
      end loop;
      return 0;
   end Top_Level;

   --  Pad Text to Width in the given position, git's %(align).
   function Pad_Align (Text : String; Args : String) return String is
      Width : Natural := 0;
      Pos   : String (1 .. 6) := "left  ";
      Pos_Last : Natural := 4;

      procedure Take (Field : String) is
      begin
         if Starts_With (Field, "width=") then
            Width := Natural'Value (Field (Field'First + 6 .. Field'Last));
         elsif Starts_With (Field, "position=") then
            declare
               V : constant String := Field (Field'First + 9 .. Field'Last);
            begin
               Pos (1 .. V'Length) := V;
               Pos_Last := V'Length;
            end;
         elsif Field = "left" or else Field = "right"
           or else Field = "middle"
         then
            Pos (1 .. Field'Length) := Field;
            Pos_Last := Field'Length;
         else
            begin
               Width := Natural'Value (Field);
            exception
               when others => null;
            end;
         end if;
      end Take;

      First : Natural := Args'First;
   begin
      --  Args is "<width>,<pos>" or "width=..,position=..".
      while First <= Args'Last loop
         declare
            Comma : Natural := First;
         begin
            while Comma <= Args'Last and then Args (Comma) /= ',' loop
               Comma := Comma + 1;
            end loop;
            Take (Args (First .. Comma - 1));
            First := Comma + 1;
         end;
      end loop;

      if Text'Length >= Width then
         return Text;
      end if;

      declare
         Pad : constant Natural := Width - Text'Length;
         P   : constant String := Pos (1 .. Pos_Last);
      begin
         if P = "right" then
            return (1 .. Pad => ' ') & Text;
         elsif P = "middle" then
            return (1 .. Pad / 2 => ' ') & Text
              & (1 .. Pad - Pad / 2 => ' ');
         else
            return Text & (1 .. Pad => ' ');
         end if;
      end;
   end Pad_Align;

   begin
      while I <= Format'Last loop
         if Format (I) = '%' and then I < Format'Last then
            if Format (I + 1) = '%' then
               Append (Result, '%');
               I := I + 2;
            elsif Format (I + 1) = '(' then
               declare
                  Close : Natural := 0;
               begin
                  for K in I + 2 .. Format'Last loop
                     if Format (K) = ')' then
                        Close := K;
                        exit;
                     end if;
                  end loop;
                  if Close = 0 then
                     Append (Result, Format (I));
                     I := I + 1;
                  else
                     declare
                        Inner : constant String :=
                          Format (I + 2 .. Close - 1);
                        Colon : constant Natural :=
                          Ada.Strings.Fixed.Index (Inner, ":");
                        A_Head : constant String :=
                          (if Colon = 0 then Inner
                           else Inner (Inner'First .. Colon - 1));
                     begin
                        if A_Head = "align" or else A_Head = "if" then
                           declare
                              End_At : constant Natural := Matching_End (I);
                           begin
                              if End_At = 0 then
                                 --  No matching %(end); pass through.
                                 Append (Result, Atom_Value (Inner));
                                 I := Close + 1;
                              else
                                 declare
                                    --  Body between this opener and its %(end)
                                    Body_Str : constant String :=
                                      Format (Close + 1 .. End_At - 1);
                                    After : constant Natural :=
                                      Matching_End (I);   --  '%' of %(end)
                                    End_Close : Natural := After;
                                 begin
                                    while End_Close <= Format'Last
                                      and then Format (End_Close) /= ')'
                                    loop
                                       End_Close := End_Close + 1;
                                    end loop;

                                    if A_Head = "align" then
                                       Append
                                         (Result,
                                          Pad_Align
                                            (Expand
                                               (Repo, Body_Str, Ref, Id, Head),
                                             (if Colon = 0 then ""
                                              else Inner (Colon + 1
                                                          .. Inner'Last))));
                                    else
                                       --  %(if): condition up to %(then),
                                       --  then-branch to %(else) or %(end).
                                       declare
                                          Then_At : constant Natural :=
                                            Top_Level (Body_Str, "then");
                                       begin
                                          if Then_At = 0 then
                                             null;
                                          else
                                             declare
                                                Then_Close : Natural := Then_At;
                                                Cond : constant String :=
                                                  Body_Str
                                                    (Body_Str'First
                                                     .. Then_At - 1);
                                                Else_At : constant Natural :=
                                                  Top_Level (Body_Str, "else");
                                             begin
                                                while Then_Close
                                                  <= Body_Str'Last
                                                  and then Body_Str (Then_Close)
                                                           /= ')'
                                                loop
                                                   Then_Close :=
                                                     Then_Close + 1;
                                                end loop;

                                                declare
                                                   Then_Part : constant String
                                                     :=
                                                     (if Else_At = 0
                                                      then Body_Str
                                                        (Then_Close + 1
                                                         .. Body_Str'Last)
                                                      else Body_Str
                                                        (Then_Close + 1
                                                         .. Else_At - 1));
                                                   Else_Close : Natural :=
                                                     Else_At;
                                                   Cond_Val : constant String :=
                                                     Expand
                                                       (Repo, Cond, Ref, Id,
                                                        Head);

                                                   --  %(if:equals=X) /
                                                   --  notequals=X compare the
                                                   --  condition value to X.
                                                   Arg : constant String :=
                                                     (if Colon = 0 then ""
                                                      else Inner (Colon + 1
                                                                  .. Inner'Last));
                                                   Take : Boolean;
                                                begin
                                                   if Starts_With
                                                        (Arg, "equals=")
                                                   then
                                                      Take := Cond_Val =
                                                        Arg (Arg'First + 7
                                                             .. Arg'Last);
                                                   elsif Starts_With
                                                           (Arg, "notequals=")
                                                   then
                                                      Take := Cond_Val /=
                                                        Arg (Arg'First + 10
                                                             .. Arg'Last);
                                                   else
                                                      --  git treats an
                                                      --  all-whitespace
                                                      --  condition (e.g.
                                                      --  %(HEAD) for a
                                                      --  non-current branch,
                                                      --  which is a space) as
                                                      --  false.
                                                      Take :=
                                                        (for some C of Cond_Val
                                                         => C not in ' '
                                                            | Character'Val (9)
                                                            | Character'Val (10)
                                                            | Character'Val (13));
                                                   end if;

                                                   if Take then
                                                      Append
                                                        (Result,
                                                         Expand
                                                           (Repo, Then_Part,
                                                            Ref, Id, Head));
                                                   elsif Else_At /= 0 then
                                                      while Else_Close
                                                        <= Body_Str'Last
                                                        and then
                                                          Body_Str (Else_Close)
                                                          /= ')'
                                                      loop
                                                         Else_Close :=
                                                           Else_Close + 1;
                                                      end loop;
                                                      Append
                                                        (Result,
                                                         Expand
                                                           (Repo,
                                                            Body_Str
                                                              (Else_Close + 1
                                                               .. Body_Str'Last),
                                                            Ref, Id, Head));
                                                   end if;
                                                end;
                                             end;
                                          end if;
                                       end;
                                    end if;

                                    I := End_Close + 1;
                                 end;
                              end if;
                           end;
                        else
                           Append (Result, Quote_Value (Atom_Value (Inner)));
                           I := Close + 1;
                        end if;
                     end;
                  end if;
               end;
            elsif I + 2 <= Format'Last
              and then (for all C of Format (I + 1 .. I + 2) =>
                          C in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F')
            then
               --  %xx hex byte escape.
               declare
                  Hex : constant String := Format (I + 1 .. I + 2);
                  V   : constant Natural := Natural'Value ("16#" & Hex & "#");
               begin
                  Append (Result, Character'Val (V));
                  I := I + 3;
               end;
            else
               Append (Result, Format (I));
               I := I + 1;
            end if;
         else
            Append (Result, Format (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Expand;

   ----------------------------------------------------------------------
   --  Sorting
   ----------------------------------------------------------------------

   function Base_Key (Key : String) return String is
      Colon : constant Natural := Ada.Strings.Fixed.Index (Key, ":");
   begin
      return (if Colon = 0 then Key else Key (Key'First .. Colon - 1));
   end Base_Key;

   function Is_Date_Key (Key : String) return Boolean is
      B : constant String := Base_Key (Key);
   begin
      return B = "authordate" or else B = "committerdate"
        or else B = "taggerdate" or else B = "creatordate";
   end Is_Date_Key;

   function Sort_Field
     (Repo : Version.Repository.Repository_Handle;
      Key  : String;
      Row  : Ref_Row)
      return String
   is
      Ref : constant String := To_String (Row.Name);
      Id  : constant String := To_String (Row.Id);
   begin
      if Key = "refname" or else Key = "version:refname"
        or else Key = "v:refname"
      then
         return Ref;
      elsif Key = "objectname" then
         return Id;
      elsif Is_Date_Key (Key) then
         --  Sort dates chronologically via their unix timestamp. creatordate
         --  maps to committer for commits, tagger for annotated tags.
         declare
            use type Version.Objects.Object_Kind;
            B    : constant String := Base_Key (Key);
            Obj  : constant Version.Objects.Git_Object :=
              Version.Objects.Read_Object
                (Repo, Version.Objects.To_Object_Id (Id));
            --  creatordate is the tagger date of an annotated tag, else the
            --  committer date of the commit.
            Line : constant String :=
              (if B = "authordate" then "author "
               elsif B = "taggerdate" then "tagger "
               elsif B = "committerdate" then "committer "
               elsif Version.Objects.Kind (Obj)
                     = Version.Objects.Tag_Object
               then "tagger "
               else "committer ");
            Val  : constant String := Line_Value
              (Version.Objects.Content (Obj), Line);
         begin
            return Git_Date (Ident_Date (Val), "unix");
         end;
      else
         return Expand (Repo, "%(" & Key & ")", Ref, Id, "");
      end if;
   end Sort_Field;

   --  git's version:refname order: compare rune by rune, but a run of digits
   --  as a number (leading zeros dropped, then longer run wins, then lexical),
   --  so v1.2 sorts before v1.10.
   function Version_Less (A, B : String) return Boolean is
      IA : Natural := A'First;
      IB : Natural := B'First;

      function Is_Digit (C : Character) return Boolean is
        (C in '0' .. '9');
   begin
      while IA <= A'Last and then IB <= B'Last loop
         if Is_Digit (A (IA)) and then Is_Digit (B (IB)) then
            declare
               EA : Natural := IA;
               EB : Natural := IB;
            begin
               while EA <= A'Last and then Is_Digit (A (EA)) loop
                  EA := EA + 1;
               end loop;
               while EB <= B'Last and then Is_Digit (B (EB)) loop
                  EB := EB + 1;
               end loop;
               --  Digit runs A(IA .. EA-1) and B(IB .. EB-1); strip zeros.
               declare
                  SA : Natural := IA;
                  SB : Natural := IB;
               begin
                  while SA < EA - 1 and then A (SA) = '0' loop
                     SA := SA + 1;
                  end loop;
                  while SB < EB - 1 and then B (SB) = '0' loop
                     SB := SB + 1;
                  end loop;
                  if (EA - SA) /= (EB - SB) then
                     return (EA - SA) < (EB - SB);
                  end if;
                  if A (SA .. EA - 1) /= B (SB .. EB - 1) then
                     return A (SA .. EA - 1) < B (SB .. EB - 1);
                  end if;
               end;
               IA := EA;
               IB := EB;
            end;
         else
            if A (IA) /= B (IB) then
               return A (IA) < B (IB);
            end if;
            IA := IA + 1;
            IB := IB + 1;
         end if;
      end loop;
      --  A prefix sorts before the longer string.
      return (A'Last - IA) < (B'Last - IB);
   end Version_Less;

   ----------------------------------------------------------------------
   --  Entry point
   ----------------------------------------------------------------------

   function For_Each_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Patterns    : String_Vectors.Vector;
      Format      : String := "";
      Sort_Key    : String := "";
      Count       : Natural := 0;
      Ignore_Case : Boolean := False;
      Quote       : String := "")
      return String_Vectors.Vector
   is
      Rows     : Row_Vectors.Vector := Enumerate (Repo);
      Filtered : Row_Vectors.Vector;
      Head     : constant String :=
        (declare
           H : constant Version.Refs.Head_Info :=
             Version.Refs.Read_Head (Repo);
         begin
           (if Version.Refs.Is_Attached (H)
            then "refs/heads/" & Version.Refs.Branch_Name (H)
            else ""));
      Tmpl     : constant String :=
        (if Format = "" then "%(objectname) %(objecttype)" & HT & "%(refname)"
         else Format);
      Result   : String_Vectors.Vector;

      --  Sort key handling: an optional leading '-' means descending.
      Descending : constant Boolean :=
        Sort_Key'Length > 0 and then Sort_Key (Sort_Key'First) = '-';
      Key        : constant String :=
        (if Sort_Key = "" then "refname"
         elsif Descending then Sort_Key (Sort_Key'First + 1 .. Sort_Key'Last)
         else Sort_Key);
      Numeric    : constant Boolean :=
        Key = "objectsize" or else Is_Date_Key (Key);
      Version_Sort : constant Boolean :=
        Key = "version:refname" or else Key = "v:refname";

      function Less (L, R : Ref_Row) return Boolean is
         LS : constant String := Sort_Field (Repo, Key, L);
         RS : constant String := Sort_Field (Repo, Key, R);
      begin
         if Version_Sort then
            if LS /= RS then
               return (if Descending then Version_Less (RS, LS)
                       else Version_Less (LS, RS));
            end if;
         elsif Numeric then
            declare
               LN : constant Long_Long_Integer :=
                 (if LS = "" then 0 else Long_Long_Integer'Value (LS));
               RN : constant Long_Long_Integer :=
                 (if RS = "" then 0 else Long_Long_Integer'Value (RS));
            begin
               if LN /= RN then
                  return (if Descending then LN > RN else LN < RN);
               end if;
            end;
         else
            if LS /= RS then
               return (if Descending then LS > RS else LS < RS);
            end if;
         end if;
         --  Stable tie-break on refname (git's final tiebreak).
         return To_String (L.Name) < To_String (R.Name);
      end Less;

      package Row_Sorting is
        new Row_Vectors.Generic_Sorting ("<" => Less);
   begin
      for R of Rows loop
         declare
            Name : constant String := To_String (R.Name);
            Hit  : Boolean;
         begin
            if Ignore_Case and then not Patterns.Is_Empty then
               --  --ignore-case: compare a lowercased ref against lowercased
               --  patterns, so `refs/heads/MAIN` matches `refs/heads/main`.
               declare
                  Folded : String_Vectors.Vector;
               begin
                  for P of Patterns loop
                     Folded.Append (String'(Ada.Characters.Handling.To_Lower (P)));
                  end loop;
                  Hit := Matches_Any
                    (Folded, Ada.Characters.Handling.To_Lower (Name));
               end;
            else
               Hit := Matches_Any (Patterns, Name);
            end if;

            if Hit then
               Filtered.Append (R);
            end if;
         end;
      end loop;

      Rows := Filtered;
      Row_Sorting.Sort (Rows);

      declare
         Emitted : Natural := 0;
      begin
         for R of Rows loop
            exit when Count /= 0 and then Emitted >= Count;
            Result.Append
              (Expand (Repo, Tmpl, To_String (R.Name), To_String (R.Id),
                       Head, Quote));
            Emitted := Emitted + 1;
         end loop;
      end;

      return Result;
   end For_Each_Ref;

end Version.Ref_Format;
