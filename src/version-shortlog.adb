with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Fixed;

with Ada.Characters.Handling;

with Version.Mailmap;
with Version.Pretty_Format;

package body Version.Shortlog is
   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = HT or else C = LF or else C = Character'Val (11)
      or else C = Character'Val (12) or else C = Character'Val (13));

   function Is_Alnum (C : Character) return Boolean is
     (C in '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z');

   --  git's format_subject with " ": the lines up to the first blank one,
   --  each stripped of trailing whitespace, joined by a space.
   function Format_Subject (Msg : String) return String is
      Result : Unbounded_String;
      First  : Boolean := True;
      Pos    : Natural := Msg'First;
   begin
      while Pos <= Msg'Last loop
         declare
            Stop : Natural := Pos;
            Last : Natural;
         begin
            while Stop <= Msg'Last and then Msg (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            Last := Stop - 1;
            while Last >= Pos and then Is_Space (Msg (Last)) loop
               Last := Last - 1;
            end loop;
            exit when Last < Pos;   --  blank line
            if not First then
               Append (Result, ' ');
            end if;
            Append (Result, Msg (Pos .. Last));
            First := False;
            Pos := Stop + 1;
         end;
      end loop;
      return To_String (Result);
   end Format_Subject;

   procedure Add_Record
     (Log     : in out Shortlog;
      Ident   : String;
      Oneline : String;
      Options : Shortlog_Options)
   is
      Cur  : constant Group_Maps.Cursor := Log.Map.Find (Ident);
      Data : Group_Data;
   begin
      if Group_Maps.Has_Element (Cur) then
         Data := Group_Maps.Element (Cur);
      end if;
      Data.Count := Data.Count + 1;
      if not Options.Summary then
         declare
            P   : Natural := Oneline'First;
            EOL : Natural;
         begin
            --  Skip any leading whitespace, including blank lines.
            while P <= Oneline'Last and then Is_Space (Oneline (P)) loop
               P := P + 1;
            end loop;
            EOL := P;
            while EOL <= Oneline'Last and then Oneline (EOL) /= LF loop
               EOL := EOL + 1;
            end loop;
            if Oneline'Last - P + 1 >= 6
              and then Oneline (P .. P + 5) = "[PATCH"
            then
               declare
                  EOB : Natural := 0;
               begin
                  for K in P .. Oneline'Last loop
                     if Oneline (K) = ']' then
                        EOB := K;
                        exit;
                     end if;
                  end loop;
                  if EOB /= 0 and then EOB < EOL then
                     P := EOB + 1;
                  end if;
               end;
            end if;
            while P <= Oneline'Last and then Is_Space (Oneline (P))
              and then Oneline (P) /= LF
            loop
               P := P + 1;
            end loop;
            Data.Subjects.Append
              (To_Unbounded_String (Format_Subject (Oneline (P .. Oneline'Last))));
         end;
      end if;
      if Group_Maps.Has_Element (Cur) then
         Log.Map.Replace_Element (Cur, Data);
      else
         Log.Map.Insert (Ident, Data);
      end if;
   end Add_Record;

   --  parse_ident + map_user: "Name <mail> ..." to the mapped "Name" or
   --  "Name <mail>"; False when Text is no ident.
   function Map_Ident
     (Map : Version.Mailmap.Entries; Text : String; Email : Boolean;
      Mapped : out Unbounded_String) return Boolean
   is
      Lt : constant Natural := Ada.Strings.Fixed.Index (Text, "<");
      Gt : Natural := 0;
   begin
      Mapped := Null_Unbounded_String;
      if Lt = 0 then
         return False;
      end if;
      for K in Lt + 1 .. Text'Last loop
         if Text (K) = '>' then
            Gt := K;
            exit;
         end if;
      end loop;
      if Gt = 0 then
         return False;
      end if;
      declare
         Name : constant String :=
           Ada.Strings.Fixed.Trim (Text (Text'First .. Lt - 1), Ada.Strings.Both);
         Mail : constant String := Text (Lt + 1 .. Gt - 1);
         MN, ME : Unbounded_String;
      begin
         Version.Mailmap.Apply (Map, Name, Mail, MN, ME);
         Mapped := MN;
         if Email then
            Append (Mapped, " <" & To_String (ME) & ">");
         end if;
      end;
      return True;
   end Map_Ident;

   procedure Add_Commit
     (Log     : in out Shortlog;
      Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Options : Shortlog_Options)
   is
      package Key_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
      Dups    : Key_Sets.Set;
      Formats : String_Vectors.Vector := Options.Formats;
      Date    : constant String := To_String (Options.Date_Mode);
      Any_Group : constant Boolean :=
        Options.By_Author or else Options.By_Committer
        or else not Options.Trailers.Is_Empty or else not Options.Formats.Is_Empty;

      function Oneline return String is
      begin
         if Options.Summary then
            return "";
         end if;
         declare
            Text : constant String :=
              Version.Pretty_Format.Expand
                (Repo, Commit,
                 (if Options.Has_User_Format then To_String (Options.User_Format)
                  else "%s"),
                 Date_Mode => Date);
         begin
            return (if Text'Length = 0 then "<none>" else Text);
         end;
      end Oneline;

      Line : constant String := Oneline;
   begin
      --  shortlog_finish_setup: author/committer become formats.
      if Options.By_Author or else not Any_Group then
         Formats.Append (if Options.Email then "%aN <%aE>" else "%aN");
      end if;
      if Options.By_Committer then
         Formats.Append (if Options.Email then "%cN <%cE>" else "%cN");
      end if;

      declare
         Needs_Dedup : constant Boolean :=
           Natural (Formats.Length) > 1 or else not Options.Trailers.Is_Empty;
      begin
         --  insert_records_from_trailers
         if not Options.Trailers.Is_Empty then
            declare
               Map : constant Version.Mailmap.Entries :=
                 Version.Mailmap.Load (Repo);
               Message : constant String :=
                 Version.Objects.Commit_Message
                   (Version.Objects.Read_Object (Repo, Commit));
            begin
               for T of Version.Pretty_Format.Parse_Trailers (Message) loop
                  declare
                     Key    : constant String := To_String (T.Key);
                     Wanted : Boolean := False;
                  begin
                     for W of Options.Trailers loop
                        if Ada.Characters.Handling.To_Lower (W)
                          = Ada.Characters.Handling.To_Lower (Key)
                        then
                           Wanted := True;
                           exit;
                        end if;
                     end loop;
                     if Wanted then
                        declare
                           Mapped : Unbounded_String;
                           Value  : constant String :=
                             (if Map_Ident (Map, To_String (T.Value), Options.Email,
                                            Mapped)
                              then To_String (Mapped) else To_String (T.Value));
                        begin
                           if not Dups.Contains (Value) then
                              Dups.Include (Value);
                              Add_Record (Log, Value, Line, Options);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end if;

         --  insert_records_from_format
         for F of Formats loop
            declare
               Key : constant String :=
                 Version.Pretty_Format.Expand (Repo, Commit, F, Date_Mode => Date);
            begin
               if not Needs_Dedup or else not Dups.Contains (Key) then
                  Dups.Include (Key);
                  Add_Record (Log, Key, Line, Options);
               end if;
            end;
         end loop;
      end;
   end Add_Commit;

   function Groups
     (Log : Shortlog; Numbered : Boolean := False) return Group_Vectors.Vector
   is
      Result : Group_Vectors.Vector;
   begin
      for Cur in Log.Map.Iterate loop
         declare
            D   : constant Group_Data := Group_Maps.Element (Cur);
            Rev : Subject_Vectors.Vector;
         begin
            for I in reverse D.Subjects.First_Index .. D.Subjects.Last_Index loop
               Rev.Append (D.Subjects (I));
            end loop;
            Result.Append
              (Author_Group'
                 (Name     => To_Unbounded_String (Group_Maps.Key (Cur)),
                  Subjects => Rev,
                  Count    => D.Count));
         end;
      end loop;
      if Numbered then
         --  A stable sort by descending count (insertion sort).
         for I in 2 .. Natural (Result.Length) loop
            declare
               V : constant Author_Group := Result (I);
               J : Natural := I;
            begin
               while J > 1 and then Result (J - 1).Count < V.Count loop
                  declare
                     Prev : constant Author_Group := Result (J - 1);
                  begin
                     Result.Replace_Element (J, Prev);
                  end;
                  J := J - 1;
               end loop;
               Result.Replace_Element (J, V);
            end;
         end loop;
      end if;
      return Result;
   end Groups;

   --  git's strbuf_add_wrapped_text: greedy fill at whitespace, a line may
   --  reach Width columns exactly, runs of spaces are kept, a tab rounds
   --  the column up to the next multiple of eight, a newline followed by a
   --  non-alphanumeric starts a new line.  Columns count code points.
   function Wrapped_Text
     (Text : String; Indent1, Indent2, Width : Natural) return String
   is
      Buf    : Unbounded_String;
      Indent : Natural := Indent1;
      W      : Natural := Indent1;
      Bol    : Natural := Text'First;
      Space  : Natural := 0;   --  0 = none
      P      : Natural := Text'First;

      procedure Add_Spaces (N : Natural) is
      begin
         Append (Buf, [1 .. N => ' ']);
      end Add_Spaces;
   begin
      if Width = 0 then
         --  strbuf_add_indented_text
         declare
            Start : Natural := Text'First;
            Ind   : Natural := Indent1;
         begin
            while Start <= Text'Last loop
               declare
                  EOL : Natural := Start;
               begin
                  while EOL <= Text'Last and then Text (EOL) /= LF loop
                     EOL := EOL + 1;
                  end loop;
                  if EOL <= Text'Last then
                     EOL := EOL + 1;
                  end if;
                  Add_Spaces (Ind);
                  Append (Buf, Text (Start .. EOL - 1));
                  Start := EOL;
                  Ind := Indent2;
               end;
            end loop;
         end;
         return To_String (Buf);
      end if;

      loop
         declare
            C : constant Character :=
              (if P > Text'Last then Character'Val (0) else Text (P));
            Break_Line : Boolean := False;
         begin
            if P > Text'Last or else Is_Space (C) then
               if W <= Width or else Space = 0 then
                  declare
                     Start : Natural := Bol;
                  begin
                     if P > Text'Last and then P = Start then
                        return To_String (Buf);
                     end if;
                     if Space /= 0 then
                        Start := Space;
                     else
                        Add_Spaces (Indent);
                     end if;
                     Append (Buf, Text (Start .. P - 1));
                     if P > Text'Last then
                        return To_String (Buf);
                     end if;
                     Space := P;
                     if C = HT then
                        W := (W / 8) * 8 + 7;
                     elsif C = LF then
                        Space := Space + 1;
                        if Space <= Text'Last and then Text (Space) = LF then
                           Append (Buf, LF);
                           Break_Line := True;
                        elsif Space > Text'Last
                          or else not Is_Alnum (Text (Space))
                        then
                           Break_Line := True;
                        else
                           Append (Buf, ' ');
                        end if;
                     end if;
                     if not Break_Line then
                        W := W + 1;
                        P := P + 1;
                     end if;
                  end;
               else
                  Break_Line := True;
               end if;
               if Break_Line then
                  Append (Buf, LF);
                  P := Space
                    + (if Space <= Text'Last and then Is_Space (Text (Space))
                       then 1 else 0);
                  Bol := P;
                  Space := 0;
                  Indent := Indent2;
                  W := Indent2;
               end if;
            else
               --  One code point.
               W := W + 1;
               P := P + 1;
               while P <= Text'Last
                 and then Character'Pos (Text (P)) in 16#80# .. 16#BF#
               loop
                  P := P + 1;
               end loop;
            end if;
         end;
      end loop;
   end Wrapped_Text;

   function Summarize
     (Repo       : Version.Repository.Repository_Handle;
      Commits    : Version.History.Commit_Id_Vectors.Vector;
      With_Email : Boolean := False)
      return Group_Vectors.Vector
   is
      Log     : Shortlog;
      Options : Shortlog_Options;
   begin
      Options.Email := With_Email;
      for C of Commits loop
         Add_Commit (Log, Repo, C, Options);
      end loop;
      return Groups (Log);
   end Summarize;

   function Summarize
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id)
      return Group_Vectors.Vector
   is
      --  git's default walk: newest first in committer-date order, which the
      --  per-group reversal turns into chronological order.
      Include : Version.History.Commit_Id_Vectors.Vector;
   begin
      Include.Append (Tip);
      return Summarize
        (Repo, Version.History.Rev_List (Repo => Repo, Include => Include));
   end Summarize;

end Version.Shortlog;
