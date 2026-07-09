with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;   use Ada.Strings.Unbounded;
with Version.Config;
with Version.Files;

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
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors (Positive, Rule);

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
      Pat : constant String := To_String (R.Pattern);
   begin
      if R.Pathname then
         return Glob (Pat, Path, Pathname => True);
      else
         return Glob (Pat, Base_Name (Path), Pathname => False);
      end if;
   end Matches;

   procedure Parse_Attr_Line (Line : String; Rules : in out Rule_Vectors.Vector)
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

      declare
         Text : constant String := Line (First .. Last);
         Sp   : Natural := 0;
         R    : Rule;
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

         --  Parse the attribute tokens.
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
                  declare
                     Tok : constant String := Lower (Text (I .. J - 1));
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
                     end if;
                  end;
                  I := J;
               end;
            end loop;
         end;

         if R.Has_Text or else R.Has_Eol then
            Rules.Append (R);
         end if;
      end;
   end Parse_Attr_Line;

   procedure Load_Attr_File
     (Path : String; Rules : in out Rule_Vectors.Vector) is
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
               Parse_Attr_Line (Content (Start .. I - 1), Rules);
               Start := I + 1;
            end if;
         end loop;
         if Start <= Content'Last then
            Parse_Attr_Line (Content (Start .. Content'Last), Rules);
         end if;
      end;
   end Load_Attr_File;

   procedure Path_Attributes
     (Repo : Version.Repository.Repository_Handle;
      Path : String;
      T    : out Text_Attr;
      E    : out Eol_Attr)
   is
      Rules : Rule_Vectors.Vector;
   begin
      T := Attr_Unspecified;
      E := Eol_Unspecified;
      --  Root .gitattributes, then repo-local info/attributes (later wins).
      Load_Attr_File
        (Version.Files.Join (Version.Repository.Root_Path (Repo),
                             ".gitattributes"),
         Rules);
      Load_Attr_File
        (Version.Files.Join
           (Version.Files.Join (Version.Repository.Git_Dir (Repo), "info"),
            "attributes"),
         Rules);
      --  Last matching rule wins per attribute.
      for R of Rules loop
         if Matches (R, Path) then
            if R.Has_Text then
               T := R.Text;
            end if;
            if R.Has_Eol then
               E := R.Eol;
            end if;
         end if;
      end loop;
   end Path_Attributes;

   ----------------------------------------------------------------------
   --  Decisions
   ----------------------------------------------------------------------

   --  Is the path text for check-in normalization purposes?
   function Checkin_Is_Text
     (Repo : Version.Repository.Repository_Handle;
      Path, Content : String) return Boolean
   is
      T : Text_Attr;
      E : Eol_Attr;
      AC : constant Autocrlf_Kind := Autocrlf (Repo);
   begin
      Path_Attributes (Repo, Path, T, E);
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
      return String is
   begin
      if Checkin_Is_Text (Repo, Relative_Path, Content) then
         return CRLF_To_LF (Content);
      end if;
      return Content;
   end Clean_Content;

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String
   is
      T  : Text_Attr;
      E  : Eol_Attr;
      AC : constant Autocrlf_Kind := Autocrlf (Repo);
      Is_Text : Boolean;
      Want_CRLF : Boolean;
   begin
      Path_Attributes (Repo, Relative_Path, T, E);

      Is_Text :=
        (E /= Eol_Unspecified)
        or else T = Attr_Text
        or else (T = Attr_Auto and then not Has_NUL (Content))
        or else (T = Attr_Unspecified
                 and then AC /= Autocrlf_False
                 and then not Has_NUL (Content));

      if not Is_Text then
         return Content;
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
         return LF_To_CRLF (Content);
      end if;
      return Content;
   end Smudge_Content;

end Version.Text_Filter;
