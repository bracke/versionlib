with Ada.IO_Exceptions;
with Ada.Strings.Fixed;


with Version.Files;
with Version.Staging;

package body Version.Grep is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  Translate a POSIX basic regular expression (git grep's default) into the
   --  extended syntax the Regexp engine accepts: in a BRE the operators
   --  ( ) { } + ? | are literal unless backslash-escaped -- the reverse of an
   --  ERE -- so swap their escaped/unescaped meaning. Characters inside a
   --  bracket expression are copied verbatim.
   function BRE_To_ERE (Pattern : String) return String is
      Result   : Unbounded_String;
      In_Class : Boolean := False;
      I        : Natural := Pattern'First;
   begin
      while I <= Pattern'Last loop
         declare
            C : constant Character := Pattern (I);
         begin
            if In_Class then
               Append (Result, C);
               if C = ']' then
                  In_Class := False;
               end if;
               I := I + 1;
            elsif C = '[' then
               Append (Result, C);
               In_Class := True;
               I := I + 1;
            elsif C = '\' and then I < Pattern'Last then
               declare
                  N : constant Character := Pattern (I + 1);
               begin
                  case N is
                     when '(' | ')' | '{' | '}' | '+' | '?' | '|' =>
                        Append (Result, N);        --  BRE special -> ERE special
                     when others =>
                        Append (Result, '\');      --  keep escape (\. \* \\ \1)
                        Append (Result, N);
                  end case;
                  I := I + 2;
               end;
            elsif C in '(' | ')' | '{' | '}' | '+' | '?' | '|' then
               Append (Result, '\');               --  BRE literal -> ERE literal
               Append (Result, C);
               I := I + 1;
            else
               Append (Result, C);
               I := I + 1;
            end if;
         end;
      end loop;
      return To_String (Result);
   end BRE_To_ERE;

   function Compile_Pattern
     (Pattern : String; Kind : Pattern_Kind) return Regexp.Regexp
   is
      use type Regexp.Compile_Status;
      Result : constant Regexp.Compile_Result :=
        (case Kind is
            when Fixed_String  => Regexp.Compile_Literal (Pattern),
            when Basic_Regex   => Regexp.Compile (BRE_To_ERE (Pattern)),
            when Extended_Regex | Perl_Regex => Regexp.Compile (Pattern));
   begin
      if Result.Status /= Regexp.Compile_Ok then
         raise Ada.IO_Exceptions.Data_Error
           with "invalid grep pattern: " & Pattern;
      end if;
      return Result.Expression;
   end Compile_Pattern;

   function Compile
     (Pattern : String;
      Opts    : Options := (others => <>))
      return Line_Matcher is
   begin
      return
        (Expr  => Compile_Pattern (Pattern, Opts.Kind),
         M_Opt =>
           (Case_Sensitive => not Opts.Ignore_Case,
            Whole_Word     => Opts.Word_Match,
            others         => <>));
   end Compile;

   function Matches (M : Line_Matcher; Text : String) return Boolean is
      use type Regexp.Match_Status;
      Found : constant Regexp.Match_Result :=
        Regexp.Find_First (M.Expr, Text, M.M_Opt);
   begin
      return Found.Status = Regexp.Match_Ok;
   end Matches;

   --  Split Content into lines and append every matching line, the shared
   --  core of the working-tree and tree searches. Line numbers are 1-based;
   --  a file is flagged binary when a NUL appears in its first 8000 bytes
   --  (git's buffer_is_binary).
   procedure Scan_Content
     (Path    : String;
      Content : String;
      Expr    : Regexp.Regexp;
      M_Opts  : Regexp.Match_Options;
      Invert  : Boolean;
      Result  : in out Match_Vectors.Vector)
   is
      use type Regexp.Match_Status;
      Start   : Positive := Content'First;
      Line_No : Positive := 1;
      Is_Bin  : constant Boolean :=
        (for some K in Content'First ..
           Integer'Min (Content'Last, Content'First + 7999)
         => Content (K) = Character'Val (0));

      function Hit (Line : String) return Boolean is
         Found : constant Regexp.Match_Result :=
           Regexp.Find_First (Expr, Line, M_Opts);
      begin
         return (Found.Status = Regexp.Match_Ok) xor Invert;
      end Hit;

      procedure Emit (Line : String) is
      begin
         if Hit (Line) then
            Result.Append
              (Match'
                 (Path    => To_Unbounded_String (Path),
                  Line_No => Line_No,
                  Text    => To_Unbounded_String (Line),
                  Binary  => Is_Bin));
         end if;
         Line_No := Line_No + 1;
      end Emit;
   begin
      for I in Content'Range loop
         if Content (I) = LF then
            Emit (Content (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Content'Last then
         Emit (Content (Start .. Content'Last));
      end if;
   end Scan_Content;

   function Match_Options_Of (Opts : Options) return Regexp.Match_Options is
     (Case_Sensitive => not Opts.Ignore_Case,
      Whole_Word     => Opts.Word_Match,
      others         => <>);

   function Search
     (Repo      : Version.Repository.Repository_Handle;
      Pattern   : String;
      Opts      : Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Match_Vectors.Vector
   is
      Entries : constant Version.Staging.Index_Entry_Vectors.Vector :=
        Version.Staging.Load (Repo);
      Root    : constant String := Version.Repository.Root_Path (Repo);
      Result  : Match_Vectors.Vector;
      Expr    : constant Regexp.Regexp := Compile_Pattern (Pattern, Opts.Kind);
      M_Opts  : constant Regexp.Match_Options := Match_Options_Of (Opts);
   begin
      for E of Entries loop
         if E.Stage = 0 then
            declare
               Path : constant String := To_String (E.Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  declare
                     Full : constant String := Version.Files.Join (Root, Path);
                  begin
                     if Version.Files.Is_Ordinary_File (Full) then
                        Scan_Content
                          (Path, Version.Files.Read_Binary_File (Full),
                           Expr, M_Opts, Opts.Invert, Result);
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Search;

   function Search_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Pattern   : String;
      Opts      : Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Match_Vectors.Vector
   is
      use type Version.Objects.Tree_Entry_Kind;
      Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
        Version.Objects.Flatten_Tree (Repo, Tree_Id);
      Result  : Match_Vectors.Vector;
      Expr    : constant Regexp.Regexp := Compile_Pattern (Pattern, Opts.Kind);
      M_Opts  : constant Regexp.Match_Options := Match_Options_Of (Opts);
   begin
      for E of Entries loop
         if E.Kind = Version.Objects.Tree_Blob then
            declare
               Path : constant String := To_String (E.Path);
            begin
               if Pathspecs.Is_Empty
                 or else Version.Pathspec.Matches_Any (Pathspecs, Path)
               then
                  Scan_Content
                    (Path,
                     Version.Objects.Content
                       (Version.Objects.Read_Object (Repo, E.Id)),
                     Expr, M_Opts, Opts.Invert, Result);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Search_Tree;

   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean)
      return Match_Vectors.Vector is
   begin
      return Search
        (Repo, Pattern,
         Opts => (Kind => Basic_Regex, Ignore_Case => Ignore_Case,
                  others => <>));
   end Search;

   ------------------------------------------------------------------------
   --  grep.c
   ------------------------------------------------------------------------

   ESC   : constant Character := Character'Val (27);
   Reset : constant String := ESC & "[m";

   function Default_Colors return Color_Table is
      T : Color_Table;
   begin
      T (Color_Filename) := To_Unbounded_String (ESC & "[35m");
      T (Color_Lineno) := To_Unbounded_String (ESC & "[32m");
      T (Color_Columnno) := To_Unbounded_String (ESC & "[32m");
      T (Color_Match_Context) := To_Unbounded_String (ESC & "[1;31m");
      T (Color_Match_Selected) := To_Unbounded_String (ESC & "[1;31m");
      T (Color_Sep) := To_Unbounded_String (ESC & "[36m");
      return T;
   end Default_Colors;

   function Looks_Binary (Content : String) return Boolean is
   begin
      for I in Content'First .. Natural'Min (Content'Last, Content'First + 7999) loop
         if Content (I) = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Looks_Binary;

   function Word_Char (C : Character) return Boolean is
     (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_');

   function Is_Space (C : Character) return Boolean is
     (C = ' ' or else C = Character'Val (9) or else C = LF
      or else C = Character'Val (11) or else C = Character'Val (12)
      or else C = Character'Val (13));

   --  What glibc's regerror says about a pattern the engine rejected, for
   --  the common mistakes; git prints it after the pattern's origin.
   function Regex_Error_Text (Pattern : String; Kind : Pattern_Kind) return String
   is
      ERE     : constant Boolean := Kind /= Basic_Regex;
      Depth   : Integer := 0;
      Brace   : Boolean := False;
      I       : Natural := Pattern'First;
      Prev_Atom : Boolean := False;
   begin
      if Pattern'Length = 1 and then Pattern (Pattern'First) = '[' then
         return "Invalid regular expression";
      end if;
      while I <= Pattern'Last loop
         declare
            C : constant Character := Pattern (I);
         begin
            if C = '\' then
               if I = Pattern'Last then
                  return "Trailing backslash";
               end if;
               declare
                  N : constant Character := Pattern (I + 1);
               begin
                  if not ERE and then N = '(' then
                     Depth := Depth + 1;
                     Prev_Atom := False;
                  elsif not ERE and then N = ')' then
                     Depth := Depth - 1;
                     if Depth < 0 then
                        return "Unmatched ) or \)";
                     end if;
                     Prev_Atom := True;
                  elsif not ERE and then N = '{' then
                     if not Prev_Atom then
                        return "Invalid preceding regular expression";
                     end if;
                     Brace := True;
                  elsif not ERE and then N = '}' then
                     Brace := False;
                  else
                     Prev_Atom := True;
                  end if;
                  I := I + 2;
               end;
            elsif C = '[' then
               declare
                  J : Natural := I + 1;
               begin
                  if J <= Pattern'Last and then Pattern (J) = '^' then
                     J := J + 1;
                  end if;
                  if J <= Pattern'Last and then Pattern (J) = ']' then
                     J := J + 1;
                  end if;
                  while J <= Pattern'Last and then Pattern (J) /= ']' loop
                     if Pattern (J) = '[' and then J < Pattern'Last
                       and then Pattern (J + 1) = ':'
                     then
                        declare
                           K : Natural := J + 2;
                        begin
                           while K < Pattern'Last
                             and then not (Pattern (K) = ':' and then Pattern (K + 1) = ']')
                           loop
                              K := K + 1;
                           end loop;
                           if K >= Pattern'Last then
                              return "Unmatched [, [^, [:, [., or [=";
                           end if;
                           declare
                              Name : constant String := Pattern (J + 2 .. K - 1);
                           begin
                              if Name /= "alpha" and then Name /= "digit"
                                and then Name /= "alnum" and then Name /= "upper"
                                and then Name /= "lower" and then Name /= "space"
                                and then Name /= "punct" and then Name /= "print"
                                and then Name /= "graph" and then Name /= "cntrl"
                                and then Name /= "xdigit" and then Name /= "blank"
                              then
                                 return "Invalid character class name";
                              end if;
                           end;
                           J := K + 2;
                        end;
                     else
                        J := J + 1;
                     end if;
                  end loop;
                  if J > Pattern'Last then
                     return "Unmatched [, [^, [:, [., or [=";
                  end if;
                  I := J + 1;
                  Prev_Atom := True;
               end;
            elsif ERE and then C = '(' then
               Depth := Depth + 1;
               Prev_Atom := False;
               I := I + 1;
            elsif ERE and then C = ')' then
               Depth := Depth - 1;
               if Depth < 0 then
                  return "Unmatched ) or \)";
               end if;
               Prev_Atom := True;
               I := I + 1;
            elsif ERE and then C = '{' then
               if not Prev_Atom then
                  return "Invalid preceding regular expression";
               end if;
               Brace := True;
               I := I + 1;
            elsif ERE and then C = '}' then
               Brace := False;
               I := I + 1;
            elsif C = '*' or else (ERE and then (C = '+' or else C = '?')) then
               if not Prev_Atom and then (ERE or else C /= '*' or else I > Pattern'First)
               then
                  if ERE or else (I > Pattern'First and then Pattern (I - 1) = '*') then
                     return "Invalid preceding regular expression";
                  end if;
               end if;
               if ERE and then I > Pattern'First
                 and then Pattern (I - 1) in '*' | '+' | '?' | '|' | '('
               then
                  return "Invalid preceding regular expression";
               end if;
               Prev_Atom := False;
               I := I + 1;
            elsif ERE and then C = '|' then
               Prev_Atom := False;
               I := I + 1;
            else
               Prev_Atom := True;
               I := I + 1;
            end if;
         end;
      end loop;
      if Brace then
         return "Unmatched \{";
      end if;
      if Depth > 0 then
         return "Unmatched ( or \(";
      end if;
      return "Invalid regular expression";
   end Regex_Error_Text;

   function Prepare (Opts : Grep_Options) return Grep_State is
      St       : Grep_State;
      Extended : Boolean := False;
      Cur      : Natural := 1;   --  parse cursor into St.Patterns

      function Add_Node (N : Expr_Node) return Natural is
      begin
         St.Nodes.Append (N);
         return St.Nodes.Last_Index;
      end Add_Node;

      function Token_At (I : Natural) return Pattern_Token is
        (St.Patterns (I).Token);

      function Has_Cur return Boolean is (Cur <= Natural (St.Patterns.Length));

      function Parse_Or return Natural;

      function Parse_Atom return Natural is
      begin
         if not Has_Cur then
            return 0;
         end if;
         case Token_At (Cur) is
            when Tok_Pattern =>
               declare
                  X : constant Natural :=
                    Add_Node ((Kind => Node_Atom, Atom => Cur, others => <>));
               begin
                  Cur := Cur + 1;
                  return X;
               end;
            when Tok_Open_Paren =>
               Cur := Cur + 1;
               declare
                  X : constant Natural := Parse_Or;
               begin
                  if not Has_Cur or else Token_At (Cur) /= Tok_Close_Paren then
                     raise Ada.IO_Exceptions.Data_Error
                       with "unmatched ( for expression group";
                  end if;
                  Cur := Cur + 1;
                  return X;
               end;
            when others =>
               return 0;
         end case;
      end Parse_Atom;

      function Parse_Not return Natural is
      begin
         if not Has_Cur then
            return 0;
         end if;
         if Token_At (Cur) = Tok_Not then
            if Cur = Natural (St.Patterns.Length) then
               raise Ada.IO_Exceptions.Data_Error
                 with "--not not followed by pattern expression";
            end if;
            Cur := Cur + 1;
            declare
               X : constant Natural := Parse_Not;
            begin
               if X = 0 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "--not followed by non pattern expression";
               end if;
               return Add_Node ((Kind => Node_Not, Left => X, others => <>));
            end;
         end if;
         return Parse_Atom;
      end Parse_Not;

      function Parse_And return Natural is
         X : constant Natural := Parse_Not;
      begin
         if Has_Cur and then Token_At (Cur) = Tok_And then
            if X = 0 then
               raise Ada.IO_Exceptions.Data_Error
                 with "--and not preceded by pattern expression";
            end if;
            if Cur = Natural (St.Patterns.Length) then
               raise Ada.IO_Exceptions.Data_Error
                 with "--and not followed by pattern expression";
            end if;
            Cur := Cur + 1;
            declare
               Y : constant Natural := Parse_And;
            begin
               if Y = 0 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "--and not followed by pattern expression";
               end if;
               return Add_Node ((Kind => Node_And, Left => X, Right => Y,
                                 others => <>));
            end;
         end if;
         return X;
      end Parse_And;

      function Parse_Or return Natural is
         X : constant Natural := Parse_And;
      begin
         if X /= 0 and then Has_Cur and then Token_At (Cur) /= Tok_Close_Paren
         then
            declare
               P : constant Natural := Cur;
               Y : constant Natural := Parse_Or;
            begin
               if Y = 0 then
                  raise Ada.IO_Exceptions.Data_Error
                    with "not a pattern expression "
                         & To_String (St.Patterns (P).Pattern);
               end if;
               return Add_Node ((Kind => Node_Or, Left => X, Right => Y,
                                 others => <>));
            end;
         end if;
         return X;
      end Parse_Or;
   begin
      for Item of Opts.Items loop
         declare
            CP : Compiled_Pattern;
         begin
            CP.Token := Item.Token;
            CP.Pattern := Item.Pattern;
            if Item.Token = Tok_Pattern then
               declare
                  Pat : constant String := To_String (Item.Pattern);
               begin
                  CP.Empty := Pat'Length = 0;
                  if not CP.Empty then
                     begin
                        CP.Expr := Compile_Pattern (Pat, Opts.Kind);
                     exception
                        when Ada.IO_Exceptions.Data_Error =>
                           --  compile_regexp_failed
                           raise Ada.IO_Exceptions.Data_Error with
                             (if Item.Line > 0
                              then "In '" & To_String (Item.Origin) & "' at "
                                   & Ada.Strings.Fixed.Trim
                                       (Natural'Image (Item.Line), Ada.Strings.Left)
                                   & ", "
                              elsif Length (Item.Origin) > 0
                              then To_String (Item.Origin) & ", "
                              else "")
                             & "'" & Pat & "': " & Regex_Error_Text (Pat, Opts.Kind);
                     end;
                  end if;
                  --  A line never holds its newline, so `.` may take a CR
                  --  (POSIX regexec sees one too).
                  CP.M_Opt :=
                    (Case_Sensitive      => not Opts.Ignore_Case,
                     Dot_Matches_Newline => True,
                     --  A binary file's "line" can be megabytes long; the
                     --  engine's default step budget would call that a
                     --  non-match.
                     Max_Steps           => Natural'Last,
                     others              => <>);
               end;
            else
               Extended := True;
            end if;
            St.Patterns.Append (CP);
         end;
      end loop;

      if Opts.All_Match then
         Extended := True;
      end if;
      if Extended and then not St.Patterns.Is_Empty then
         St.Root := Parse_Or;
         if Has_Cur then
            raise Ada.IO_Exceptions.Data_Error
              with "incomplete pattern expression group: "
                   & To_String (St.Patterns (Cur).Pattern);
         end if;
      end if;
      return St;
   end Prepare;

   --  patmatch: the first match of P in Line at or after From (a 0-based
   --  offset); So/Eo are 0-based half-open offsets in Line.  A match that
   --  starts after Line's first character does not see it as a line start.
   procedure Pat_Match
     (P    : Compiled_Pattern;
      Line : String;
      From : Natural;
      Hit  : out Boolean;
      So   : out Natural;
      Eo   : out Natural)
   is
      use type Regexp.Match_Status;
   begin
      So := 0;
      Eo := 0;
      if P.Empty then
         Hit := From <= Line'Length;
         So := From;
         Eo := From;
         return;
      end if;
      if From > Line'Length then
         Hit := False;
         return;
      end if;
      declare
         R : constant Regexp.Match_Result :=
           Regexp.Find_From (P.Expr, Line, From + 1, P.M_Opt);
      begin
         Hit := R.Status = Regexp.Match_Ok;
         if Hit then
            So := R.First - 1;
            Eo := (if R.Last < R.First then So else R.Last);
         end if;
      end;
   end Pat_Match;

   --  headerless_match_one_pattern: the match, honouring -w by walking to
   --  the next word boundary when the first match is not a whole word.
   procedure Match_One
     (P    : Compiled_Pattern;
      Opts : Grep_Options;
      Line : String;
      From : Natural;
      Hit  : out Boolean;
      So   : out Natural;
      Eo   : out Natural)
   is
      Len : constant Natural := Line'Length;
      Bol : Natural := From;
   begin
      loop
         Pat_Match (P, Line, Bol, Hit, So, Eo);
         exit when not Hit or else not Opts.Word_Regexp;
         --  The match must start at a word boundary and end at one.
         if not ((So = 0 or else not Word_Char (Line (Line'First + So - 1)))
                 and then (Eo = Len or else not Word_Char (Line (Line'First + Eo))))
         then
            Hit := False;
         end if;
         --  Words consist of at least one character.
         if So = Eo then
            Hit := False;
         end if;
         exit when Hit;
         --  Forward to the next start after a non-word character.
         exit when So + 1 >= Len;
         Bol := So + 1;
         while Bol < Len and then Word_Char (Line (Line'First + Bol - 1)) loop
            Bol := Bol + 1;
         end loop;
         exit when Bol >= Len;
      end loop;
   end Match_One;

   function Grep_Buffer
     (State     : in out Grep_State;
      Opts      : Grep_Options;
      Name      : String;
      Content   : String;
      Is_Binary : Boolean;
      Output    : in out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean
   is
      --  Line L (1-based) is Content (Starts (L) .. Starts (L + 1) - 2) --
      --  Starts (L + 1) is one past its newline (or Content'Last + 2).
      package Nat_Vectors is new Ada.Containers.Vectors
        (Index_Type => Positive, Element_Type => Natural);
      Starts : Nat_Vectors.Vector;
      N      : Natural := 0;

      function Line_Of (L : Positive) return String is
         First : constant Natural := Starts (L);
         Next  : constant Natural := Starts (L + 1);
      begin
         if Next - 2 >= First and then Next - 2 <= Content'Last
           and then Content (Next - 2) = LF
         then
            return Content (First .. Next - 2 - 1);
         end if;
         return Content (First .. Natural'Min (Next - 2, Content'Last));
      end Line_Of;

      procedure Emit (S : String) is
      begin
         Append (Output, S);
      end Emit;

      procedure Out_Color (S : String; Slot : Color_Slot) is
      begin
         if Opts.Color and then Length (Opts.Colors (Slot)) > 0 then
            Emit (To_String (Opts.Colors (Slot)) & S & Reset);
         else
            Emit (S);
         end if;
      end Out_Color;

      procedure Out_Sep (Sign : Character) is
      begin
         if Opts.Null_Following then
            Emit ("" & Character'Val (0));
         else
            Out_Color ("" & Sign, Color_Sep);
         end if;
      end Out_Sep;

      procedure Show_Name is
      begin
         Out_Color (Name, Color_Filename);
         Emit ("" & (if Opts.Null_Following then Character'Val (0) else LF));
      end Show_Name;

      --  match_expr_eval; Col/Icol are -1 for "no match yet".
      function Eval
        (X : Natural; Line : String; Col, Icol : in out Integer;
         Collect : Boolean) return Boolean
      is
         Node : Expr_Node := State.Nodes (X);
         H    : Boolean := False;
      begin
         case Node.Kind is
            when Node_True =>
               H := True;
            when Node_Atom =>
               declare
                  Hit    : Boolean;
                  So, Eo : Natural;
               begin
                  Match_One (State.Patterns (Node.Atom), Opts, Line, 0, Hit, So, Eo);
                  H := Hit;
                  if H and then (Col < 0 or else Integer (So) < Col) then
                     Col := Integer (So);
                  end if;
               end;
            when Node_Not =>
               H := not Eval (Node.Left, Line, Icol, Col, False);
            when Node_And =>
               H := Eval (Node.Left, Line, Col, Icol, False);
               if H or else Opts.Column then
                  H := Eval (Node.Right, Line, Col, Icol, False) and then H;
               end if;
            when Node_Or =>
               if not (Collect or else Opts.Column) then
                  return Eval (Node.Left, Line, Col, Icol, False)
                    or else Eval (Node.Right, Line, Col, Icol, False);
               end if;
               H := Eval (Node.Left, Line, Col, Icol, False);
               if Collect then
                  State.Nodes.Reference (Node.Left).Hit :=
                    State.Nodes (Node.Left).Hit or H;
               end if;
               H := Eval (Node.Right, Line, Col, Icol, Collect) or else H;
         end case;
         if Collect then
            Node := State.Nodes (X);
            Node.Hit := Node.Hit or H;
            State.Nodes.Replace_Element (X, Node);
         end if;
         return H;
      end Eval;

      function Match_Line
        (Line : String; Col, Icol : in out Integer; Collect : Boolean)
         return Boolean
      is
         Hit : Boolean := False;
      begin
         if State.Root /= 0 then
            return Eval (State.Root, Line, Col, Icol, Collect);
         end if;
         for P of State.Patterns loop
            declare
               H      : Boolean;
               So, Eo : Natural;
            begin
               Match_One (P, Opts, Line, 0, H, So, Eo);
               if H then
                  Hit := True;
                  exit when not Opts.Column;
                  if Col < 0 or else Integer (So) < Col then
                     Col := Integer (So);
                  end if;
               end if;
            end;
         end loop;
         return Hit;
      end Match_Line;

      --  grep_next_match: the earliest (then shortest) match of any
      --  pattern at or after From.
      procedure Next_Match
        (Line : String; From : Natural; Hit : out Boolean; So, Eo : out Natural)
      is
      begin
         Hit := False;
         So := 0;
         Eo := 0;
         if From >= Line'Length then
            return;
         end if;
         for P of State.Patterns loop
            if P.Token = Tok_Pattern then
               declare
                  H      : Boolean;
                  S1, E1 : Natural;
               begin
                  Match_One (P, Opts, Line, From, H, S1, E1);
                  --  The earliest start wins, then the longest match.
                  if H then
                     if not Hit or else S1 < So
                       or else (S1 = So and then E1 > Eo)
                     then
                        So := S1;
                        Eo := E1;
                     end if;
                     Hit := True;
                  end if;
               end;
            end if;
         end loop;
      end Next_Match;

      function Img (V : Natural) return String is
        (Ada.Strings.Fixed.Trim (Natural'Image (V), Ada.Strings.Left));

      procedure Show_Line_Header (Lno : Positive; Cno : Natural; Sign : Character)
      is
      begin
         if Opts.Heading and then State.Last_Shown = 0 then
            Out_Color (Name, Color_Filename);
            Emit ("" & LF);
         end if;
         State.Last_Shown := Lno;
         if not Opts.Heading and then Opts.Pathname then
            Out_Color (Name, Color_Filename);
            Out_Sep (Sign);
         end if;
         if Opts.Line_Number then
            Out_Color (Img (Lno), Color_Lineno);
            Out_Sep (Sign);
         end if;
         if Opts.Column and then Cno > 0 then
            Out_Color (Img (Cno), Color_Columnno);
            Out_Sep (Sign);
         end if;
      end Show_Line_Header;

      procedure Show_Line (Lno : Positive; Cno_In : Natural; Sign : Character) is
         Line       : constant String := Line_Of (Lno);
         Line_Color : Color_Slot := Color_Selected;
         Match_Col  : Color_Slot := Color_Match_Selected;
         Has_Line_Color : Boolean := False;
         Pos        : Natural := 0;   --  0-based offset into Line
         Cno        : Natural := Cno_In;
      begin
         if Opts.File_Break and then State.Last_Shown = 0 then
            if State.Show_Hunk_Mark then
               Emit ("" & LF);
            end if;
         elsif Opts.Pre_Context > 0 or else Opts.Post_Context > 0
           or else Opts.Funcbody
         then
            if State.Last_Shown = 0 then
               if State.Show_Hunk_Mark then
                  Out_Color ("--", Color_Sep);
                  Emit ("" & LF);
               end if;
            elsif Lno > State.Last_Shown + 1 then
               Out_Color ("--", Color_Sep);
               Emit ("" & LF);
            end if;
         end if;
         if not Opts.Only_Matching then
            Show_Line_Header (Lno, Cno, Sign);
         end if;
         if Opts.Color or else Opts.Only_Matching then
            if Opts.Color then
               Match_Col :=
                 (if Sign = ':' then Color_Match_Selected else Color_Match_Context);
               Has_Line_Color := True;
               Line_Color :=
                 (if Sign = ':' then Color_Selected
                  elsif Sign = '-' then Color_Context
                  else Color_Function);
            end if;
            loop
               declare
                  Hit    : Boolean;
                  So, Eo : Natural;
               begin
                  Next_Match (Line, Pos, Hit, So, Eo);
                  exit when not Hit or else So = Eo;
                  Cno := So + 1;
                  if Opts.Only_Matching then
                     Show_Line_Header (Lno, Cno, Sign);
                  elsif Has_Line_Color then
                     Out_Color (Line (Line'First + Pos .. Line'First + So - 1),
                                Line_Color);
                  else
                     Emit (Line (Line'First + Pos .. Line'First + So - 1));
                  end if;
                  Out_Color (Line (Line'First + So .. Line'First + Eo - 1), Match_Col);
                  if Opts.Only_Matching then
                     Emit ("" & LF);
                  end if;
                  Pos := Eo;
               end;
            end loop;
         end if;
         if not Opts.Only_Matching then
            if Has_Line_Color then
               Out_Color (Line (Line'First + Pos .. Line'Last), Line_Color);
            else
               Emit (Line (Line'First + Pos .. Line'Last));
            end if;
            Emit ("" & LF);
         end if;
      end Show_Line;

      --  match_funcname with xdiff's default rule.
      function Is_Funcname (L : Positive) return Boolean is
         Line : constant String := Line_Of (L);
      begin
         return Line'Length > 0
           and then Line (Line'First) in 'a' .. 'z' | 'A' .. 'Z' | '_' | '$';
      end Is_Funcname;

      function Is_Empty (L : Positive) return Boolean is
        (for all C of Line_Of (L) => Is_Space (C));

      procedure Show_Funcname_Line (From : Positive) is
         L : Natural := From;
      begin
         while L > 1 loop
            L := L - 1;
            exit when L <= State.Last_Shown;
            if Is_Funcname (L) then
               Show_Line (L, 0, '=');
               exit;
            end if;
         end loop;
      end Show_Funcname_Line;

      procedure Show_Pre_Context (Lno : Positive) is
         Cur  : Positive := Lno;
         From : Natural := 1;
         Funcname_Lno : Natural := 0;
         Orig_From    : Natural;
         Funcname_Needed : Boolean := Opts.Funcname;
         Comment_Needed  : Boolean := False;
      begin
         if Opts.Pre_Context < Lno then
            From := Lno - Opts.Pre_Context;
         end if;
         if From <= State.Last_Shown then
            From := State.Last_Shown + 1;
         end if;
         Orig_From := From;
         if Opts.Funcbody then
            if Is_Funcname (Lno) then
               Comment_Needed := True;
            else
               Funcname_Needed := True;
            end if;
            From := State.Last_Shown + 1;
         end if;

         --  Rewind.
         while Cur > 1 and then Cur > From loop
            Cur := Cur - 1;
            if Comment_Needed and then (Is_Empty (Cur) or else Is_Funcname (Cur))
            then
               Comment_Needed := False;
               From := Orig_From;
               if Cur < From then
                  Cur := Cur + 1;
                  exit;
               end if;
            end if;
            if Funcname_Needed and then Is_Funcname (Cur) then
               Funcname_Lno := Cur;
               Funcname_Needed := False;
               if Opts.Funcbody then
                  Comment_Needed := True;
               else
                  From := Orig_From;
               end if;
            end if;
         end loop;

         --  We need to look even further back to find a function signature.
         if Opts.Funcname and then Funcname_Needed then
            Show_Funcname_Line (Cur);
         end if;

         --  Back forward.
         while Cur < Lno loop
            Show_Line (Cur, 0, (if Cur = Funcname_Lno then '=' else '-'));
            Cur := Cur + 1;
         end loop;
      end Show_Pre_Context;

      --  grep_source_1
      function Source_1 (Collect : Boolean) return Boolean is
         Last_Hit      : Natural := 0;
         Count         : Natural := 0;
         Show_Function : Boolean := False;
         Peek_L        : Natural := 0;
         Binary_Only   : Boolean := False;
      begin
         if Opts.Pre_Context > 0 or else Opts.Post_Context > 0
           or else Opts.File_Break or else Opts.Funcbody
         then
            if State.Last_Shown > 0 then
               State.Show_Hunk_Mark := True;
            end if;
         end if;
         State.Last_Shown := 0;

         case Opts.Binary is
            when Binary_Default =>
               Binary_Only := Is_Binary;
            when Binary_No_Match =>
               if Is_Binary then
                  return False;
               end if;
            when Binary_Text =>
               null;
         end case;

         for L in 1 .. N loop
            declare
               Line : constant String := Line_Of (L);
               Col  : Integer := -1;
               Icol : Integer := -1;
               Hit  : Boolean := Match_Line (Line, Col, Icol, Collect);
               Handled : Boolean := False;
            begin
               if not Collect then
                  if Opts.Invert then
                     Hit := not Hit;
                  end if;
                  if Opts.Unmatch_Name_Only then
                     if Hit then
                        return False;
                     end if;
                     Handled := True;
                  end if;
                  if not Handled and then Hit
                    and then (Opts.Max_Count < 0 or else Count < Opts.Max_Count)
                  then
                     Count := Count + 1;
                     if Opts.Status_Only then
                        return True;
                     end if;
                     if Opts.Name_Only then
                        Show_Name;
                        return True;
                     end if;
                     if Opts.Count then
                        Handled := True;
                     elsif Binary_Only then
                        Emit ("Binary file ");
                        Out_Color (Name, Color_Filename);
                        Emit (" matches" & LF);
                        return True;
                     else
                        if Opts.Pre_Context > 0 or else Opts.Funcbody then
                           Show_Pre_Context (L);
                        elsif Opts.Funcname then
                           Show_Funcname_Line (L);
                        end if;
                        declare
                           Cno : Integer := (if Opts.Invert then Icol else Col);
                        begin
                           if Cno < 0 then
                              Cno := 0;
                           end if;
                           Show_Line (L, Natural (Cno) + 1, ':');
                        end;
                        Last_Hit := L;
                        if Opts.Funcbody then
                           Show_Function := True;
                        end if;
                        Handled := True;
                     end if;
                  end if;
                  if not Handled then
                     if Show_Function and then (Peek_L = 0 or else Peek_L < L) then
                        Peek_L := L;
                        while Peek_L <= N and then Is_Empty (Peek_L) loop
                           Peek_L := Peek_L + 1;
                        end loop;
                        if Peek_L > N or else Is_Funcname (Peek_L) then
                           Show_Function := False;
                        end if;
                     end if;
                     if Show_Function
                       or else (Last_Hit > 0 and then L <= Last_Hit + Opts.Post_Context)
                     then
                        Show_Line (L, Natural (Col + 1), '-');
                     end if;
                  end if;
               end if;
            end;
         end loop;

         if Collect then
            return False;
         end if;
         if Opts.Status_Only then
            return Opts.Unmatch_Name_Only;
         end if;
         if Opts.Unmatch_Name_Only then
            Show_Name;
            return True;
         end if;
         if Opts.Count and then Count > 0 then
            if Opts.Pathname then
               Out_Color (Name, Color_Filename);
               Out_Sep (':');
            end if;
            Emit (Img (Count) & LF);
            return True;
         end if;
         return Last_Hit > 0;
      end Source_1;
   begin
      --  Line starts.
      declare
         P : Natural := Content'First;
      begin
         while P <= Content'Last loop
            Starts.Append (P);
            N := N + 1;
            declare
               Q : Natural := P;
            begin
               while Q <= Content'Last and then Content (Q) /= LF loop
                  Q := Q + 1;
               end loop;
               P := Q + 1;
            end;
         end loop;
         Starts.Append (Content'Last + 2);
      end;

      if not Opts.All_Match then
         return Source_1 (False);
      end if;

      --  clr_hit_marker / chk_hit_marker over the top-level OR chain.
      declare
         X : Natural := State.Root;
      begin
         while X /= 0 loop
            State.Nodes.Reference (X).Hit := False;
            exit when State.Nodes (X).Kind /= Node_Or;
            State.Nodes.Reference (State.Nodes (X).Left).Hit := False;
            X := State.Nodes (X).Right;
         end loop;
      end;
      declare
         Ignored : constant Boolean := Source_1 (True);
         pragma Unreferenced (Ignored);
         X : Natural := State.Root;
      begin
         while X /= 0 loop
            if State.Nodes (X).Kind /= Node_Or then
               if not State.Nodes (X).Hit then
                  return False;
               end if;
               exit;
            end if;
            if not State.Nodes (State.Nodes (X).Left).Hit then
               return False;
            end if;
            X := State.Nodes (X).Right;
         end loop;
      end;
      return Source_1 (False);
   end Grep_Buffer;

end Version.Grep;
