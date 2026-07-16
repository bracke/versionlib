with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Ada.Containers.Vectors;
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
      Head   : String)
      return String
   is
      Result : Unbounded_String;
      I      : Natural := Format'First;

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

      function Atom_Value (Atom : String) return String is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Atom, ":");
         Head_A : constant String :=
           (if Colon = 0 then Atom else Atom (Atom'First .. Colon - 1));
         Arg    : constant String :=
           (if Colon = 0 then "" else Atom (Colon + 1 .. Atom'Last));
      begin
         if Head_A = "refname" then
            return (if Arg = "short" then Short_Name (Ref) else Ref);
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
                  else
                     return Full;
                  end if;
               end;
            else
               return "";
            end if;
         else
            raise Constraint_Error
              with "unknown for-each-ref field: " & Atom;
         end if;
      end Atom_Value;

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
                     Append (Result, Atom_Value (Format (I + 2 .. Close - 1)));
                     I := Close + 1;
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
      if Key = "refname" then
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

   ----------------------------------------------------------------------
   --  Entry point
   ----------------------------------------------------------------------

   function For_Each_Ref
     (Repo     : Version.Repository.Repository_Handle;
      Patterns : String_Vectors.Vector;
      Format   : String := "";
      Sort_Key : String := "";
      Count    : Natural := 0)
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

      function Less (L, R : Ref_Row) return Boolean is
         LS : constant String := Sort_Field (Repo, Key, L);
         RS : constant String := Sort_Field (Repo, Key, R);
      begin
         if Numeric then
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
         if Matches_Any (Patterns, To_String (R.Name)) then
            Filtered.Append (R);
         end if;
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
                       Head));
            Emitted := Emitted + 1;
         end loop;
      end;

      return Result;
   end For_Each_Ref;

end Version.Ref_Format;
