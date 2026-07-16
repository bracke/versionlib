with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Version.Config;
with Version.Files;
with Version.Objects;

package body Version.Text_Filter is

   CR : constant Character := Character'Val (13);
   LF : constant Character := Character'Val (10);

   type Text_Attr is (Attr_Unspecified, Attr_Text, Attr_Binary, Attr_Auto);
   type Eol_Attr  is (Eol_Unspecified, Eol_LF, Eol_CRLF);
   type Autocrlf_Kind is (Autocrlf_False, Autocrlf_True, Autocrlf_Input);

   ----------------------------------------------------------------------
   --  Byte helpers
   ----------------------------------------------------------------------

   function Has_NUL (S : String) return Boolean is
      Limit : constant Natural :=
        Natural'Min (S'Last, S'First + 7_999);   --  git checks first 8000 bytes
   begin
      for I in S'First .. Limit loop
         if S (I) = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Has_NUL;

   function CRLF_To_LF (S : String) return String is
      Result : Unbounded_String;
      I      : Natural := S'First;
   begin
      while I <= S'Last loop
         if S (I) = CR and then I < S'Last and then S (I + 1) = LF then
            Append (Result, LF);
            I := I + 2;
         else
            Append (Result, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end CRLF_To_LF;

   function LF_To_CRLF (S : String) return String is
      --  Normalize any existing CRLF first so we never emit CR CR LF.
      Normal : constant String := CRLF_To_LF (S);
      Result : Unbounded_String;
   begin
      for C of Normal loop
         if C = LF then
            Append (Result, CR);
            Append (Result, LF);
         else
            Append (Result, C);
         end if;
      end loop;
      return To_String (Result);
   end LF_To_CRLF;

   --  Replace every "$Id$" / "$Id:...$" token with Replacement. Used by both
   --  the ident clean ($Id$) and smudge ($Id: <sha> $) filters.
   function Replace_Ident (S : String; Replacement : String) return String is
      Result : Unbounded_String;
      I      : Natural := S'First;
   begin
      while I <= S'Last loop
         if I + 2 <= S'Last and then S (I .. I + 2) = "$Id" then
            if I + 3 <= S'Last and then S (I + 3) = '$' then
               Append (Result, Replacement);
               I := I + 4;
            elsif I + 3 <= S'Last and then S (I + 3) = ':' then
               declare
                  J : Natural := I + 4;
               begin
                  while J <= S'Last and then S (J) /= '$' loop
                     J := J + 1;
                  end loop;
                  if J <= S'Last then
                     Append (Result, Replacement);
                     I := J + 1;
                  else
                     Append (Result, S (I));
                     I := I + 1;
                  end if;
               end;
            else
               Append (Result, S (I));
               I := I + 1;
            end if;
         else
            Append (Result, S (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Replace_Ident;

   --  Check-in: collapse "$Id:...$" back to "$Id$".
   function Ident_Clean (S : String) return String is
     (Replace_Ident (S, "$Id$"));

   --  Checkout: expand "$Id$" to "$Id: <blob-sha> $".
   function Ident_Smudge
     (Repo : Version.Repository.Repository_Handle; Content : String)
      return String
   is
      Sha : constant String :=
        Version.Objects.To_String
          (Version.Objects.Compute_Object_Id
             (Version.Repository.Algorithm (Repo), "blob", Content));
   begin
      return Replace_Ident (Content, "$Id: " & Sha & " $");
   end Ident_Smudge;

   ----------------------------------------------------------------------
   --  Config
   ----------------------------------------------------------------------

   function Lower (S : String) return String
     renames Ada.Characters.Handling.To_Lower;

   function Get (Repo : Version.Repository.Repository_Handle;
                 Key : String) return String is
   begin
      if Version.Config.Has_Key (Repo, Key) then
         return Lower (Version.Config.Get_Value (Repo, Key));
      end if;
      return "";
   end Get;

   function Autocrlf (Repo : Version.Repository.Repository_Handle)
     return Autocrlf_Kind
   is
      V : constant String := Get (Repo, "core.autocrlf");
   begin
      if V = "true" or else V = "yes" or else V = "on" or else V = "1" then
         return Autocrlf_True;
      elsif V = "input" then
         return Autocrlf_Input;
      else
         return Autocrlf_False;
      end if;
   end Autocrlf;

   --  core.eol default checkout ending for text files (native = LF here).
   function Core_Eol_Is_CRLF (Repo : Version.Repository.Repository_Handle)
     return Boolean is (Get (Repo, "core.eol") = "crlf");

   ----------------------------------------------------------------------
   --  .gitattributes
   ----------------------------------------------------------------------

   type Rule is record
      Pattern  : Unbounded_String;
      Pathname : Boolean := False;     --  pattern contains a slash
      Has_Text : Boolean := False;
      Text     : Text_Attr := Attr_Unspecified;
      Has_Eol  : Boolean := False;
      Eol      : Eol_Attr := Eol_Unspecified;
      Has_Ident : Boolean := False;
      Ident     : Boolean := False;   --  True = ident, False = -ident
      --  Repo-relative directory of the .gitattributes that defined this rule
      --  (empty for the root file and info/attributes); the pattern matches
      --  paths relative to this directory, per git's nested-attributes rules.
      Base_Dir : Unbounded_String := Null_Unbounded_String;
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors (Positive, Rule);

   --  A "[attr]<name> <tokens>" macro definition (top-level / info only).
   type Macro_Def is record
      Name   : Unbounded_String;
      Tokens : Unbounded_String;   --  raw attribute tokens the macro expands to
   end record;

   package Macro_Vectors is new Ada.Containers.Vectors (Positive, Macro_Def);

   --  Shell-style match; when Pathname, '*' does not cross '/'.
   function Glob (Pat, Text : String; Pathname : Boolean) return Boolean is
      function M (Pi, Ti : Integer) return Boolean is
         P : Integer := Pi;
         T : Integer := Ti;
      begin
         while P <= Pat'Last loop
            case Pat (P) is
               when '?' =>
                  if T > Text'Last
                    or else (Pathname and then Text (T) = '/')
                  then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
               when '*' =>
                  P := P + 1;
                  for K in T .. Text'Last + 1 loop
                     if M (P, K) then
                        return True;
                     end if;
                     exit when K > Text'Last
                       or else (Pathname and then Text (K) = '/');
                  end loop;
                  return False;
               when others =>
                  if T > Text'Last or else Text (T) /= Pat (P) then
                     return False;
                  end if;
                  P := P + 1;
                  T := T + 1;
            end case;
         end loop;
         return T > Text'Last;
      end M;
   begin
      return M (Pat'First, Text'First);
   end Glob;

   function Base_Name (Path : String) return String is
      Slash : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            Slash := I;
         end if;
      end loop;
      return (if Slash = 0 then Path else Path (Slash + 1 .. Path'Last));
   end Base_Name;

   function Matches (R : Rule; Path : String) return Boolean is
      Pat  : constant String := To_String (R.Pattern);
      Base : constant String := To_String (R.Base_Dir);

      function Match_Rel (Rel : String) return Boolean is
      begin
         if R.Pathname then
            return Glob (Pat, Rel, Pathname => True);
         else
            return Glob (Pat, Base_Name (Rel), Pathname => False);
         end if;
      end Match_Rel;
   begin
      if Base'Length = 0 then
         return Match_Rel (Path);
      end if;
      --  A nested .gitattributes only governs paths under its directory; the
      --  pattern is matched against the remainder below that directory.
      if Path'Length <= Base'Length + 1
        or else Path (Path'First .. Path'First + Base'Length - 1) /= Base
        or else Path (Path'First + Base'Length) /= '/'
      then
         return False;
      end if;
      return Match_Rel (Path (Path'First + Base'Length + 1 .. Path'Last));
   end Matches;

   procedure Parse_Attr_Line
     (Line   : String;
      Macros : Macro_Vectors.Vector;
      Rules  : in out Rule_Vectors.Vector)
   is
      First : Natural := Line'First;
      Last  : Natural := Line'Last;
   begin
      --  Trim surrounding whitespace / CR.
      while First <= Last
        and then (Line (First) = ' ' or else Line (First) = Character'Val (9))
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then (Line (Last) = ' ' or else Line (Last) = Character'Val (9)
                  or else Line (Last) = CR)
      loop
         Last := Last - 1;
      end loop;
      if First > Last or else Line (First) = '#' then
         return;
      end if;
      --  Macro definitions ("[attr]...") are collected separately, not rules.
      if Last - First + 1 >= 6
        and then Line (First .. First + 5) = "[attr]"
      then
         return;
      end if;

      declare
         Text : constant String := Line (First .. Last);
         Sp   : Natural := 0;
         R    : Rule;

         --  Apply one attribute token to R; expand a macro name one level
         --  (Allow_Macro guards against runaway recursion).
         procedure Apply_Token (Tok : String; Allow_Macro : Boolean) is
         begin
            if Tok = "text" or else Tok = "crlf" then
               R.Has_Text := True; R.Text := Attr_Text;
            elsif Tok = "-text" or else Tok = "-crlf"
              or else Tok = "binary"
            then
               R.Has_Text := True; R.Text := Attr_Binary;
            elsif Tok = "text=auto" then
               R.Has_Text := True; R.Text := Attr_Auto;
            elsif Tok = "eol=lf" then
               R.Has_Eol := True; R.Eol := Eol_LF;
            elsif Tok = "eol=crlf" then
               R.Has_Eol := True; R.Eol := Eol_CRLF;
            elsif Tok = "ident" then
               R.Has_Ident := True; R.Ident := True;
            elsif Tok = "-ident" then
               R.Has_Ident := True; R.Ident := False;
            elsif Allow_Macro then
               for M of Macros loop
                  if Lower (To_String (M.Name)) = Tok then
                     --  Expand the macro's tokens (no further macro nesting).
                     declare
                        MT : constant String := To_String (M.Tokens);
                        K  : Natural := MT'First;
                     begin
                        while K <= MT'Last loop
                           while K <= MT'Last
                             and then (MT (K) = ' '
                                       or else MT (K) = Character'Val (9))
                           loop
                              K := K + 1;
                           end loop;
                           exit when K > MT'Last;
                           declare
                              L : Natural := K;
                           begin
                              while L <= MT'Last
                                and then MT (L) /= ' '
                                and then MT (L) /= Character'Val (9)
                              loop
                                 L := L + 1;
                              end loop;
                              Apply_Token (Lower (MT (K .. L - 1)), False);
                              K := L;
                           end;
                        end loop;
                     end;
                  end if;
               end loop;
            end if;
         end Apply_Token;
      begin
         for I in Text'Range loop
            if Text (I) = ' ' or else Text (I) = Character'Val (9) then
               Sp := I;
               exit;
            end if;
         end loop;
         if Sp = 0 then
            return;   --  pattern with no attributes: nothing to do here
         end if;

         declare
            Raw_Pat : String := Text (Text'First .. Sp - 1);
            Anchored : Boolean := False;
         begin
            if Raw_Pat'Length > 0 and then Raw_Pat (Raw_Pat'First) = '/' then
               Anchored := True;
               Raw_Pat := Raw_Pat (Raw_Pat'First + 1 .. Raw_Pat'Last);
            end if;
            R.Pattern := To_Unbounded_String (Raw_Pat);
            R.Pathname :=
              Anchored
              or else (for some C of Raw_Pat => C = '/');
         end;

         declare
            I : Natural := Sp + 1;
         begin
            while I <= Text'Last loop
               while I <= Text'Last
                 and then (Text (I) = ' ' or else Text (I) = Character'Val (9))
               loop
                  I := I + 1;
               end loop;
               exit when I > Text'Last;
               declare
                  J : Natural := I;
               begin
                  while J <= Text'Last
                    and then Text (J) /= ' '
                    and then Text (J) /= Character'Val (9)
                  loop
                     J := J + 1;
                  end loop;
                  Apply_Token (Lower (Text (I .. J - 1)), True);
                  I := J;
               end;
            end loop;
         end;

         if R.Has_Text or else R.Has_Eol or else R.Has_Ident then
            Rules.Append (R);
         end if;
      end;
   end Parse_Attr_Line;

   --  Collect "[attr]<name> <tokens>" macro definitions from a file.
   procedure Collect_Macros
     (Path : String; Macros : in out Macro_Vectors.Vector)
   is
      procedure Parse (Line : String) is
         F : Natural := Line'First;
         L : Natural := Line'Last;
      begin
         while F <= L
           and then (Line (F) = ' ' or else Line (F) = Character'Val (9))
         loop
            F := F + 1;
         end loop;
         while L >= F
           and then (Line (L) = ' ' or else Line (L) = Character'Val (9)
                     or else Line (L) = CR)
         loop
            L := L - 1;
         end loop;
         if L - F + 1 < 7 or else Line (F .. F + 5) /= "[attr]" then
            return;
         end if;
         declare
            Rest : constant String := Line (F + 6 .. L);
            Sp   : Natural := 0;
         begin
            for I in Rest'Range loop
               if Rest (I) = ' ' or else Rest (I) = Character'Val (9) then
                  Sp := I;
                  exit;
               end if;
            end loop;
            if Sp = 0 then
               return;
            end if;
            Macros.Append
              (Macro_Def'
                 (Name   => To_Unbounded_String (Rest (Rest'First .. Sp - 1)),
                  Tokens => To_Unbounded_String (Rest (Sp + 1 .. Rest'Last))));
         end;
      end Parse;
   begin
      if not Version.Files.Is_Ordinary_File (Path) then
         return;
      end if;
      declare
         Content : constant String := Version.Files.Read_Binary_File (Path);
         Start   : Natural := Content'First;
      begin
         for I in Content'Range loop
            if Content (I) = LF then
               Parse (Content (Start .. I - 1));
               Start := I + 1;
            end if;
         end loop;
         if Start <= Content'Last then
            Parse (Content (Start .. Content'Last));
         end if;
      end;
   end Collect_Macros;

   procedure Load_Attr_File
     (Path     : String;
      Base_Dir : String;
      Macros   : Macro_Vectors.Vector;
      Rules    : in out Rule_Vectors.Vector)
   is
      First_New : constant Positive := Natural (Rules.Length) + 1;
   begin
      if not Version.Files.Is_Ordinary_File (Path) then
         return;
      end if;
      declare
         Content : constant String := Version.Files.Read_Binary_File (Path);
         Start   : Natural := Content'First;
      begin
         for I in Content'Range loop
            if Content (I) = LF then
               Parse_Attr_Line (Content (Start .. I - 1), Macros, Rules);
               Start := I + 1;
            end if;
         end loop;
         if Start <= Content'Last then
            Parse_Attr_Line (Content (Start .. Content'Last), Macros, Rules);
         end if;
      end;
      --  Tag the rules just loaded with the directory their file lives in.
      for I in First_New .. Natural (Rules.Length) loop
         declare
            R : Rule := Rules (I);
         begin
            R.Base_Dir := To_Unbounded_String (Base_Dir);
            Rules.Replace_Element (I, R);
         end;
      end loop;
   end Load_Attr_File;

   procedure Path_Attributes
     (Repo  : Version.Repository.Repository_Handle;
      Path  : String;
      T     : out Text_Attr;
      E     : out Eol_Attr;
      Ident : out Boolean)
   is
      Rules  : Rule_Vectors.Vector;
      Macros : Macro_Vectors.Vector;
      Info_Attrs : constant String :=
        Version.Files.Join
          (Version.Files.Join (Version.Repository.Git_Dir (Repo), "info"),
           "attributes");
   begin
      T := Attr_Unspecified;
      E := Eol_Unspecified;
      Ident := False;
      --  Macros ("[attr]...") are only honoured from the top-level file and
      --  info/attributes (git's rule); collect them before evaluating rules.
      declare
         Root : constant String := Version.Repository.Root_Path (Repo);
      begin
         Collect_Macros (Version.Files.Join (Root, ".gitattributes"), Macros);
      end;
      Collect_Macros (Info_Attrs, Macros);
      --  Nested .gitattributes: root first (lowest precedence), then each
      --  ancestor directory of Path shallow-to-deep (a deeper file overrides a
      --  shallower one via last-match-wins), then repo-local info/attributes
      --  (highest precedence of all).
      declare
         Root : constant String := Version.Repository.Root_Path (Repo);
         Pos  : Natural := Path'First;
      begin
         Load_Attr_File
           (Version.Files.Join (Root, ".gitattributes"), "", Macros, Rules);
         loop
            declare
               Slash : Natural := 0;
            begin
               for K in Pos .. Path'Last loop
                  if Path (K) = '/' then
                     Slash := K;
                     exit;
                  end if;
               end loop;
               exit when Slash = 0;
               declare
                  Dir : constant String := Path (Path'First .. Slash - 1);
               begin
                  Load_Attr_File
                    (Version.Files.Join (Root, Dir & "/.gitattributes"),
                     Dir, Macros, Rules);
               end;
               Pos := Slash + 1;
            end;
         end loop;
      end;
      Load_Attr_File (Info_Attrs, "", Macros, Rules);
      --  Last matching rule wins per attribute.
      for R of Rules loop
         if Matches (R, Path) then
            if R.Has_Text then
               T := R.Text;
            end if;
            if R.Has_Eol then
               E := R.Eol;
            end if;
            if R.Has_Ident then
               Ident := R.Ident;
            end if;
         end if;
      end loop;
   end Path_Attributes;

   ----------------------------------------------------------------------
   --  Decisions
   ----------------------------------------------------------------------

   --  Is the path text for check-in normalization purposes?
   function Path_Ident
     (Repo : Version.Repository.Repository_Handle; Path : String)
      return Boolean
   is
      T : Text_Attr;
      E : Eol_Attr;
      Ident : Boolean;
   begin
      Path_Attributes (Repo, Path, T, E, Ident);
      return Ident;
   end Path_Ident;

   function Checkin_Is_Text
     (Repo : Version.Repository.Repository_Handle;
      Path, Content : String) return Boolean
   is
      T : Text_Attr;
      E : Eol_Attr;
      Ident : Boolean;
      AC : constant Autocrlf_Kind := Autocrlf (Repo);
   begin
      Path_Attributes (Repo, Path, T, E, Ident);
      if E /= Eol_Unspecified then
         T := Attr_Text;
      end if;
      case T is
         when Attr_Binary => return False;
         when Attr_Text   => return True;
         when Attr_Auto   => return not Has_NUL (Content);
         when Attr_Unspecified =>
            return AC /= Autocrlf_False and then not Has_NUL (Content);
      end case;
   end Checkin_Is_Text;

   function Is_Active
     (Repo : Version.Repository.Repository_Handle)
      return Boolean is
   begin
      return Autocrlf (Repo) /= Autocrlf_False
        or else Core_Eol_Is_CRLF (Repo)
        or else Version.Files.Is_Ordinary_File
                  (Version.Files.Join (Version.Repository.Root_Path (Repo),
                                       ".gitattributes"))
        or else Version.Files.Is_Ordinary_File
                  (Version.Files.Join
                     (Version.Files.Join
                        (Version.Repository.Git_Dir (Repo), "info"),
                      "attributes"));
   end Is_Active;

   function Clean_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
      Result : Unbounded_String := To_Unbounded_String (Content);
   begin
      --  git check-in order: crlf_to_git, then ident_to_git.
      if Checkin_Is_Text (Repo, Relative_Path, Content) then
         Result := To_Unbounded_String (CRLF_To_LF (To_String (Result)));
      end if;
      if Path_Ident (Repo, Relative_Path) then
         Result := To_Unbounded_String (Ident_Clean (To_String (Result)));
      end if;
      return To_String (Result);
   end Clean_Content;

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
      T  : Text_Attr;
      E  : Eol_Attr;
      Ident : Boolean;
      AC : constant Autocrlf_Kind := Autocrlf (Repo);
      Is_Text : Boolean;
      Want_CRLF : Boolean;
      Work : Unbounded_String := To_Unbounded_String (Content);
   begin
      Path_Attributes (Repo, Relative_Path, T, E, Ident);

      --  git checkout order: ident_to_worktree (using the stored blob's sha),
      --  then crlf_to_worktree. ident applies regardless of the text attribute.
      if Ident then
         Work := To_Unbounded_String (Ident_Smudge (Repo, Content));
      end if;

      Is_Text :=
        (E /= Eol_Unspecified)
        or else T = Attr_Text
        or else (T = Attr_Auto and then not Has_NUL (Content))
        or else (T = Attr_Unspecified
                 and then AC /= Autocrlf_False
                 and then not Has_NUL (Content));

      if not Is_Text then
         return To_String (Work);
      end if;

      if E = Eol_CRLF then
         Want_CRLF := True;
      elsif E = Eol_LF then
         Want_CRLF := False;
      elsif AC = Autocrlf_True then
         Want_CRLF := True;
      elsif AC = Autocrlf_Input then
         Want_CRLF := False;
      else
         Want_CRLF := Core_Eol_Is_CRLF (Repo);
      end if;

      if Want_CRLF then
         return LF_To_CRLF (To_String (Work));
      end if;
      return To_String (Work);
   end Smudge_Content;

end Version.Text_Filter;
