with Ada.Directories;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Version.Files;
with Version.Path_Safety;
with Version.Repository;

package body Version.Pathspec is

   function Empty_Pathspec_Diagnostic return String is
   begin
      return "empty pathspec";
   end Empty_Pathspec_Diagnostic;

   function Empty_Pathspec_Diagnostic (Text : String) return String is
   begin
      return "empty pathspec: " & Text;
   end Empty_Pathspec_Diagnostic;

   function Empty_Component_Diagnostic (Text : String) return String is
   begin
      return "empty pathspec component: " & Text;
   end Empty_Component_Diagnostic;

   function Current_Directory_Component_Diagnostic (Text : String) return String is
   begin
      return "current-directory pathspec component is not allowed: " & Text;
   end Current_Directory_Component_Diagnostic;

   function Traversal_Component_Diagnostic (Text : String) return String is
   begin
      return "pathspec traversal is not allowed: " & Text;
   end Traversal_Component_Diagnostic;

   function Git_Dir_Component_Diagnostic (Text : String) return String is
   begin
      return "pathspecs inside .git are not allowed: " & Text;
   end Git_Dir_Component_Diagnostic;

   function Absolute_Pathspec_Diagnostic (Text : String) return String is
   begin
      return "absolute pathspecs are not allowed: " & Text;
   end Absolute_Pathspec_Diagnostic;

   function NUL_Diagnostic return String is
   begin
      return "pathspec contains NUL";
   end NUL_Diagnostic;

   function Control_Character_Diagnostic return String is
   begin
      return "pathspec contains control character";
   end Control_Character_Diagnostic;

   function Backslash_Separator_Diagnostic (Text : String) return String is
   begin
      return "backslash pathspec separators are not supported: " & Text;
   end Backslash_Separator_Diagnostic;

   function Empty_Directory_Diagnostic (Text : String) return String is
   begin
      return "empty directory pathspec: " & Text;
   end Empty_Directory_Diagnostic;

   function Unknown_Magic_Diagnostic (Text : String) return String is
   begin
      return "unknown pathspec magic: " & Text;
   end Unknown_Magic_Diagnostic;

   function Empty_Magic_Diagnostic return String is
   begin
      return "empty pathspec magic";
   end Empty_Magic_Diagnostic;

   function Malformed_Magic_Diagnostic (Text : String) return String is
   begin
      return "malformed pathspec magic: " & Text;
   end Malformed_Magic_Diagnostic;

   function Is_Control (C : Character) return Boolean is
   begin
      return Character'Pos (C) < 32 or else Character'Pos (C) = 127;
   end Is_Control;

   function Contains_Glob_Meta (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = '*' or else C = '?' or else C = '[' then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Glob_Meta;

   function Contains_Slash (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = '/' then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Slash;

   function Starts_With (Text, Prefix : String) return Boolean is
   begin
      return Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   procedure Validate_Component
     (Original  : String;
      Component : String)
   is
      Non_Glob : Boolean := True;
   begin
      if Component'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with
           Empty_Component_Diagnostic (Original);
      elsif Component = "." then
         raise Ada.IO_Exceptions.Data_Error with
           Current_Directory_Component_Diagnostic (Original);
      elsif Component = ".." then
         raise Ada.IO_Exceptions.Data_Error with
           Traversal_Component_Diagnostic (Original);
      elsif Component = ".git" then
         raise Ada.IO_Exceptions.Data_Error with
           Git_Dir_Component_Diagnostic (Original);
      end if;

      for C of Component loop
         if C = '*' or else C = '?' or else C = '[' then
            Non_Glob := False;
         end if;
      end loop;

      if Non_Glob then
         Version.Path_Safety.Require_Safe_Relative_Path
           (Component, "pathspec component");
      end if;
   end Validate_Component;

   procedure Validate_Pathspec_Pattern
     (Original : String;
      Pattern  : String)
   is
      Start : Natural := Pattern'First;
      Stop  : Natural;
      Last  : Natural := Pattern'Last;
   begin
      if Pattern'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Empty_Pathspec_Diagnostic;
      end if;

      if Pattern (Pattern'First) = '/'
        or else Pattern (Pattern'First) = '\'
        or else (Pattern'Length >= 2 and then Pattern (Pattern'First + 1) = ':')
      then
         raise Ada.IO_Exceptions.Data_Error with
           Absolute_Pathspec_Diagnostic (Original);
      end if;

      for C of Pattern loop
         if C = Character'Val (0) then
            raise Ada.IO_Exceptions.Data_Error with NUL_Diagnostic;
         elsif Is_Control (C) then
            raise Ada.IO_Exceptions.Data_Error with
              Control_Character_Diagnostic;
         elsif C = '\' then
            raise Ada.IO_Exceptions.Data_Error with
              Backslash_Separator_Diagnostic (Original);
         end if;
      end loop;

      if Pattern (Last) = '/' then
         Last := Last - 1;
         if Last < Pattern'First then
            raise Ada.IO_Exceptions.Data_Error with
              Empty_Directory_Diagnostic (Original);
         end if;
      end if;

      while Start <= Last loop
         Stop := Start;
         while Stop <= Last and then Pattern (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         Validate_Component (Original, Pattern (Start .. Stop - 1));
         Start := Stop + 1;
      end loop;
   end Validate_Pathspec_Pattern;

   function Trimmed (Text : String) return String is
   begin
      return Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   end Trimmed;

   procedure Parse_Attribute_Requirement
     (Text            : String;
      Attribute_Mode  : in out Attribute_Match_Mode;
      Attribute_Name  : in out Unbounded_String;
      Attribute_Value : in out Unbounded_String)
   is
      T : constant String := Trimmed (Text);
      Equal_Pos : Natural := 0;
   begin
      if T'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Unknown_Magic_Diagnostic ("attr:");
      end if;

      if T (T'First) = '-' then
         if T'Length = 1 then
            raise Ada.IO_Exceptions.Data_Error with Unknown_Magic_Diagnostic ("attr:" & T);
         end if;
         Attribute_Mode := Attribute_Unset;
         Attribute_Name := To_Unbounded_String (T (T'First + 1 .. T'Last));
         Attribute_Value := Null_Unbounded_String;
      elsif T (T'First) = '!' then
         if T'Length = 1 then
            raise Ada.IO_Exceptions.Data_Error with Unknown_Magic_Diagnostic ("attr:" & T);
         end if;
         Attribute_Mode := Attribute_Unspecified;
         Attribute_Name := To_Unbounded_String (T (T'First + 1 .. T'Last));
         Attribute_Value := Null_Unbounded_String;
      else
         for I in T'Range loop
            if T (I) = '=' then
               Equal_Pos := I;
               exit;
            end if;
         end loop;

         if Equal_Pos = T'First or else Equal_Pos = T'Last then
            raise Ada.IO_Exceptions.Data_Error with Unknown_Magic_Diagnostic ("attr:" & T);
         elsif Equal_Pos /= 0 then
            Attribute_Mode := Version.Pathspec.Attribute_Value;
            Attribute_Name := To_Unbounded_String (T (T'First .. Equal_Pos - 1));
            Attribute_Value := To_Unbounded_String (T (Equal_Pos + 1 .. T'Last));
         else
            Attribute_Mode := Attribute_Set;
            Attribute_Name := To_Unbounded_String (T);
            Attribute_Value := Null_Unbounded_String;
         end if;
      end if;
   end Parse_Attribute_Requirement;

   procedure Apply_Magic
     (Word            : String;
      Explicit_Mode   : in out Boolean;
      Mode            : in out Match_Mode;
      Excluded        : in out Boolean;
      Top_Anchored    : in out Boolean;
      Attribute_Mode  : in out Attribute_Match_Mode;
      Attribute_Name  : in out Unbounded_String;
      Attribute_Value : in out Unbounded_String)
   is
      W : constant String := Trimmed (Word);
   begin
      if W = "literal" then
         Explicit_Mode := True;
         Mode := Literal_Mode;
      elsif W = "glob" then
         Explicit_Mode := True;
         Mode := Glob_Mode;
      elsif W = "top" then
         Top_Anchored := True;
      elsif W = "exclude" then
         Excluded := True;
      elsif Starts_With (W, "attr:") then
         Parse_Attribute_Requirement
           (W (W'First + 5 .. W'Last), Attribute_Mode,
            Attribute_Name, Attribute_Value);
      else
         raise Ada.IO_Exceptions.Data_Error with Unknown_Magic_Diagnostic (W);
      end if;
   end Apply_Magic;

   procedure Parse_Magic_List
     (Text            : String;
      Explicit_Mode   : in out Boolean;
      Mode            : in out Match_Mode;
      Excluded        : in out Boolean;
      Top_Anchored    : in out Boolean;
      Attribute_Mode  : in out Attribute_Match_Mode;
      Attribute_Name  : in out Unbounded_String;
      Attribute_Value : in out Unbounded_String)
   is
      Start : Natural := Text'First;
      Stop  : Natural;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Empty_Magic_Diagnostic;
      end if;

      while Start <= Text'Last loop
         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= ',' loop
            Stop := Stop + 1;
         end loop;

         if Stop = Start then
            raise Ada.IO_Exceptions.Data_Error with Empty_Magic_Diagnostic;
         end if;

         Apply_Magic
           (Text (Start .. Stop - 1), Explicit_Mode, Mode,
            Excluded, Top_Anchored, Attribute_Mode,
            Attribute_Name, Attribute_Value);

         if Stop > Text'Last then
            Start := Stop + 1;
         elsif Stop = Text'Last then
            raise Ada.IO_Exceptions.Data_Error with Empty_Magic_Diagnostic;
         else
            Start := Stop + 1;
         end if;
      end loop;
   end Parse_Magic_List;

   function Parse
     (Text : String)
      return Pathspec_Item
   is
      Mode          : Match_Mode := Literal_Mode;
      Explicit_Mode : Boolean := False;
      Excluded      : Boolean := False;
      Top_Anchored    : Boolean := False;
      Attribute_Mode  : Attribute_Match_Mode := Attribute_Ignored;
      Attribute_Name  : Unbounded_String;
      Attribute_Value : Unbounded_String;
      Body_First      : Natural := Text'First;
      Body_Last     : constant Natural := Text'Last;
   begin
      if Text'Length = 0 then
         raise Ada.IO_Exceptions.Data_Error with Empty_Pathspec_Diagnostic;
      end if;

      if Text'Length >= 2
        and then Text (Text'First) = ':'
        and then (Text (Text'First + 1) = '!' or else Text (Text'First + 1) = '^')
      then
         Excluded := True;
         Body_First := Text'First + 2;
      elsif Text'Length >= 2
        and then Text (Text'First) = ':'
        and then Text (Text'First + 1) = '/'
      then
         Top_Anchored := True;
         Body_First := Text'First + 2;
      elsif Text'Length >= 3
        and then Text (Text'First) = ':'
        and then Text (Text'First + 1) = '('
      then
         declare
            Close : Natural := Text'First + 2;
         begin
            while Close <= Text'Last and then Text (Close) /= ')' loop
               Close := Close + 1;
            end loop;

            if Close > Text'Last then
               raise Ada.IO_Exceptions.Data_Error with
                 Malformed_Magic_Diagnostic (Text);
            end if;

            Parse_Magic_List
              (Text (Text'First + 2 .. Close - 1), Explicit_Mode, Mode,
               Excluded, Top_Anchored, Attribute_Mode,
               Attribute_Name, Attribute_Value);
            Body_First := Close + 1;
         end;
      end if;

      if Body_First > Body_Last then
         raise Ada.IO_Exceptions.Data_Error with Empty_Pathspec_Diagnostic (Text);
      end if;

      declare
         Payload             : constant String := Text (Body_First .. Body_Last);
         Directory_Prefix : constant Boolean := Payload (Payload'Last) = '/';
         Pattern          : constant String := Payload;
      begin
         Validate_Pathspec_Pattern (Text, Pattern);

         if (not Explicit_Mode) and then Contains_Glob_Meta (Pattern) then
            Mode := Glob_Mode;
         end if;

         return Pathspec_Item'
           (Pattern          => To_Unbounded_String (Pattern),
            Mode             => Mode,
            Excluded         => Excluded,
            Top_Anchored     => Top_Anchored,
            Directory_Prefix => Directory_Prefix,
            Has_Slash        => Contains_Slash (Pattern),
            Attribute_Mode   => Attribute_Mode,
            Attribute_Name   => Attribute_Name,
            Attribute_Value  => Attribute_Value);
      end;
   end Parse;

   procedure Append_Parse
     (Result : in out Pathspec_Vectors.Vector;
      Text   : String)
   is
   begin
      Result.Append (Parse (Text));
   end Append_Parse;

   function Parse_All
     (Items : Ada.Strings.Unbounded.Unbounded_String)
      return Pathspec_Vectors.Vector
   is
      Text   : constant String := To_String (Items);
      Result : Pathspec_Vectors.Vector;
      Start  : Natural := Text'First;
      Stop   : Natural;
   begin
      if Text'Length = 0 then
         return Result;
      end if;

      while Start <= Text'Last loop
         while Start <= Text'Last and then Text (Start) = ' ' loop
            Start := Start + 1;
         end loop;
         exit when Start > Text'Last;

         Stop := Start;
         while Stop <= Text'Last and then Text (Stop) /= ' ' loop
            Stop := Stop + 1;
         end loop;

         Append_Parse (Result, Text (Start .. Stop - 1));
         Start := Stop + 1;
      end loop;

      return Result;
   end Parse_All;

   function Strip_Trailing_Slash (Text : String) return String is
   begin
      if Text'Length > 0 and then Text (Text'Last) = '/' then
         return Text (Text'First .. Text'Last - 1);
      else
         return Text;
      end if;
   end Strip_Trailing_Slash;

   function Starts_With_Directory
     (Path   : String;
      Prefix : String)
      return Boolean
   is
   begin
      return Path = Prefix
        or else (Path'Length > Prefix'Length
                 and then Path (Path'First .. Path'First + Prefix'Length) = Prefix & "/");
   end Starts_With_Directory;

   function Basename (Path : String) return String is
      Last_Slash : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            Last_Slash := I;
         end if;
      end loop;

      if Last_Slash = 0 then
         return Path;
      elsif Last_Slash = Path'Last then
         return "";
      else
         return Path (Last_Slash + 1 .. Path'Last);
      end if;
   end Basename;

   function Glob_Match
     (Pattern : String;
      Text    : String)
      return Boolean;

   function Glob_Match_From
     (Pattern : String;
      P       : Natural;
      Text    : String;
      S       : Natural)
      return Boolean
   is
   begin
      if P > Pattern'Last then
         return S > Text'Last;
      end if;

      if Pattern (P) = '*' then
         if P < Pattern'Last and then Pattern (P + 1) = '*' then
            if P + 2 <= Pattern'Last and then Pattern (P + 2) = '/' then
               if Glob_Match_From (Pattern, P + 3, Text, S) then
                  return True;
               end if;
            end if;

            for K in S .. Text'Last + 1 loop
               if Glob_Match_From (Pattern, P + 2, Text, K) then
                  return True;
               end if;
            end loop;

            return False;
         else
            if Glob_Match_From (Pattern, P + 1, Text, S) then
               return True;
            end if;

            for K in S .. Text'Last loop
               exit when Text (K) = '/';
               if Glob_Match_From (Pattern, P + 1, Text, K + 1) then
                  return True;
               end if;
            end loop;

            return False;
         end if;
      elsif Pattern (P) = '?' then
         return S <= Text'Last
           and then Text (S) /= '/'
           and then Glob_Match_From (Pattern, P + 1, Text, S + 1);
      else
         return S <= Text'Last
           and then Pattern (P) = Text (S)
           and then Glob_Match_From (Pattern, P + 1, Text, S + 1);
      end if;
   end Glob_Match_From;

   function Glob_Match
     (Pattern : String;
      Text    : String)
      return Boolean
   is
   begin
      if Pattern'Length = 0 then
         return Text'Length = 0;
      end if;
      return Glob_Match_From (Pattern, Pattern'First, Text, Text'First);
   end Glob_Match;

   function Attribute_Pattern_Matches
     (Pattern : String;
      Path    : String) return Boolean
   is
      P : constant String :=
        (if Pattern'Length > 0 and then Pattern (Pattern'First) = '/'
         then Pattern (Pattern'First + 1 .. Pattern'Last)
         else Pattern);
   begin
      if P'Length = 0 then
         return False;
      elsif Contains_Slash (P) then
         return Glob_Match (P, Path);
      elsif Contains_Glob_Meta (P) then
         return Glob_Match (P, Basename (Path));
      else
         return Basename (Path) = P;
      end if;
   end Attribute_Pattern_Matches;

   procedure Apply_Attribute_Token
     (Token       : String;
      Name        : String;
      Found       : in out Boolean;
      Is_Set      : in out Boolean;
      Is_Unset    : in out Boolean;
      Value       : in out Unbounded_String)
   is
      Equal_Pos : Natural := 0;
   begin
      if Token'Length = 0 then
         return;
      elsif Token (Token'First) = '-' then
         if Token'Length > 1 and then Token (Token'First + 1 .. Token'Last) = Name then
            Found := True;
            Is_Set := False;
            Is_Unset := True;
            Value := Null_Unbounded_String;
         end if;
      elsif Token (Token'First) = '!' then
         if Token'Length > 1 and then Token (Token'First + 1 .. Token'Last) = Name then
            Found := False;
            Is_Set := False;
            Is_Unset := False;
            Value := Null_Unbounded_String;
         end if;
      else
         for I in Token'Range loop
            if Token (I) = '=' then
               Equal_Pos := I;
               exit;
            end if;
         end loop;

         if Equal_Pos /= 0 then
            if Equal_Pos > Token'First and then Token (Token'First .. Equal_Pos - 1) = Name then
               Found := True;
               Is_Set := True;
               Is_Unset := False;
               Value := To_Unbounded_String (Token (Equal_Pos + 1 .. Token'Last));
            end if;
         elsif Token = Name then
            Found := True;
            Is_Set := True;
            Is_Unset := False;
            Value := Null_Unbounded_String;
         end if;
      end if;
   end Apply_Attribute_Token;

   procedure Read_Attributes_File
     (File_Path : String;
      Path      : String;
      Name      : String;
      Found     : in out Boolean;
      Is_Set    : in out Boolean;
      Is_Unset  : in out Boolean;
      Value     : in out Unbounded_String)
   is
      File : Ada.Text_IO.File_Type;
   begin
      if not Ada.Directories.Exists (File_Path) then
         return;
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, File_Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Trimmed (Ada.Text_IO.Get_Line (File));
            First_Space : Natural := 0;
         begin
            if Line'Length > 0 and then Line (Line'First) /= '#' then
               for I in Line'Range loop
                  if Line (I) = ' ' or else Line (I) = Character'Val (9) then
                     First_Space := I;
                     exit;
                  end if;
               end loop;

               if First_Space /= 0
                 and then Attribute_Pattern_Matches
                   (Line (Line'First .. First_Space - 1), Path)
               then
                  declare
                     Start : Natural := First_Space + 1;
                     Stop  : Natural;
                  begin
                     while Start <= Line'Last loop
                        while Start <= Line'Last
                          and then (Line (Start) = ' ' or else Line (Start) = Character'Val (9))
                        loop
                           Start := Start + 1;
                        end loop;
                        exit when Start > Line'Last;

                        Stop := Start;
                        while Stop <= Line'Last
                          and then Line (Stop) /= ' '
                          and then Line (Stop) /= Character'Val (9)
                        loop
                           Stop := Stop + 1;
                        end loop;

                        Apply_Attribute_Token
                          (Line (Start .. Stop - 1), Name, Found, Is_Set, Is_Unset, Value);
                        Start := Stop + 1;
                     end loop;
                  end;
               end if;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_Attributes_File;

   function Attribute_Requirement_Matches
     (Item : Pathspec_Item;
      Path : String) return Boolean
   is
      Name : constant String := To_String (Item.Attribute_Name);
      Expected : constant String := To_String (Item.Attribute_Value);
      Found    : Boolean := False;
      Is_Set   : Boolean := False;
      Is_Unset : Boolean := False;
      Value    : Unbounded_String;
      Repo     : constant Version.Repository.Repository_Handle := Version.Repository.Open;
   begin
      if Item.Attribute_Mode = Attribute_Ignored then
         return True;
      end if;

      Read_Attributes_File
        (Version.Files.Join (Version.Repository.Root_Path (Repo), ".gitattributes"),
         Path, Name, Found, Is_Set, Is_Unset, Value);
      Read_Attributes_File
        (Version.Files.Join
           (Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "info"),
            "attributes"),
         Path, Name, Found, Is_Set, Is_Unset, Value);

      case Item.Attribute_Mode is
         when Attribute_Ignored =>
            return True;
         when Attribute_Set =>
            return Found and then Is_Set;
         when Attribute_Unset =>
            return Found and then Is_Unset;
         when Attribute_Unspecified =>
            return not Found;
         when Attribute_Value =>
            return Found and then Is_Set and then To_String (Value) = Expected;
      end case;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Data_Error =>
         return Item.Attribute_Mode = Attribute_Unspecified;
   end Attribute_Requirement_Matches;

   function Matches
     (Item         : Pathspec_Item;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean
   is
      Pattern_Text : constant String := To_String (Item.Pattern);
      Pattern      : constant String := Strip_Trailing_Slash (Pattern_Text);
   begin
      if Path'Length = 0 then
         return False;
      end if;

      declare
         Path_Matches : constant Boolean :=
           (if Item.Mode = Literal_Mode then
              (if Item.Directory_Prefix or else Is_Directory then
                  Starts_With_Directory (Path, Pattern)
               else
                  Path = Pattern or else Starts_With_Directory (Path, Pattern))
            else
              (if Item.Directory_Prefix then
                  Starts_With_Directory (Path, Pattern)
               elsif not Item.Has_Slash then
                  (if Item.Top_Anchored then
                      Glob_Match (Pattern, Path)
                   else
                      Glob_Match (Pattern, Basename (Path)))
               else
                  Glob_Match (Pattern, Path)));
      begin
         return Path_Matches and then Attribute_Requirement_Matches (Item, Path);
      end;
   end Matches;

   function Matches_Any
     (Items        : Pathspec_Vectors.Vector;
      Path         : String;
      Is_Directory : Boolean := False)
      return Boolean
   is
      Has_Positive : Boolean := False;
      Selected     : Boolean := False;
   begin
      if Items.Is_Empty then
         return True;
      end if;

      for I in Items.First_Index .. Items.Last_Index loop
         if not Items.Element (I).Excluded then
            Has_Positive := True;
            if Matches (Items.Element (I), Path, Is_Directory) then
               Selected := True;
            end if;
         end if;
      end loop;

      if not Has_Positive then
         Selected := True;
      end if;

      if Selected then
         for I in Items.First_Index .. Items.Last_Index loop
            if Items.Element (I).Excluded
              and then Matches (Items.Element (I), Path, Is_Directory)
            then
               return False;
            end if;
         end loop;
      end if;

      return Selected;
   end Matches_Any;

   function To_Text
     (Item : Pathspec_Item)
      return String
   is
      Pattern_Text : constant String := To_String (Item.Pattern);
      Need_Literal : constant Boolean :=
        Item.Mode = Literal_Mode and then Contains_Glob_Meta (Pattern_Text);
      Need_Glob : constant Boolean :=
        Item.Mode = Glob_Mode and then not Contains_Glob_Meta (Pattern_Text);
      Magic : Unbounded_String;
   begin
      if Item.Top_Anchored then
         Magic := To_Unbounded_String ("top");
      end if;

      if Item.Excluded then
         if Length (Magic) > 0 then
            Append (Magic, ",");
         end if;
         Append (Magic, "exclude");
      end if;

      if Need_Literal then
         if Length (Magic) > 0 then
            Append (Magic, ",");
         end if;
         Append (Magic, "literal");
      elsif Need_Glob then
         if Length (Magic) > 0 then
            Append (Magic, ",");
         end if;
         Append (Magic, "glob");
      end if;

      if Item.Attribute_Mode /= Attribute_Ignored then
         if Length (Magic) > 0 then
            Append (Magic, ",");
         end if;
         Append (Magic, "attr:");
         case Item.Attribute_Mode is
            when Attribute_Ignored =>
               null;
            when Attribute_Set =>
               Append (Magic, To_String (Item.Attribute_Name));
            when Attribute_Unset =>
               Append (Magic, "-" & To_String (Item.Attribute_Name));
            when Attribute_Unspecified =>
               Append (Magic, "!" & To_String (Item.Attribute_Name));
            when Attribute_Value =>
               Append
                 (Magic,
                  To_String (Item.Attribute_Name) & "="
                  & To_String (Item.Attribute_Value));
         end case;
      end if;

      if Length (Magic) = 0 then
         return Pattern_Text;
      else
         return ":(" & To_String (Magic) & ")" & Pattern_Text;
      end if;
   end To_Text;

   function Is_Excluded
     (Item : Pathspec_Item)
      return Boolean
   is
   begin
      return Item.Excluded;
   end Is_Excluded;

end Version.Pathspec;
