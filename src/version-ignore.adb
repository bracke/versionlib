with Ada.Directories; use Ada.Directories;
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Containers; use Ada.Containers;
with GNAT.OS_Lib;
with Version.Config;
with Version.Files;
with Version.Platform;
with Version.Refs;

package body Version.Ignore is

   use type Version.Platform.Platform_Kind;

   package String_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => Unbounded_String);

   use String_Vectors;

   function Ignore_Path_Text (Path : String) return String is
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return Version.Files.Normalize_Separators (Path);
      else
         return Path;
      end if;
   end Ignore_Path_Text;

   function Canonical_Root_Path (Root : String) return String is
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return Ignore_Path_Text
           (Ada.Directories.Full_Name (Version.Files.To_Native_Path (Root)));
      else
         return Ada.Directories.Full_Name (Root);
      end if;
   end Canonical_Root_Path;

   function Relative_Path (Root : String; Full : String) return String is
      Normal_Root : constant String := Ignore_Path_Text (Root);
      Normal_Full : constant String := Ignore_Path_Text (Full);
   begin
      if Normal_Full'Length <= Normal_Root'Length then
         return "";
      elsif Normal_Full (Normal_Full'First .. Normal_Full'First + Normal_Root'Length - 1) /= Normal_Root then
         return Normal_Full;
      elsif Normal_Full (Normal_Full'First + Normal_Root'Length) = '/' then
         return Normal_Full (Normal_Full'First + Normal_Root'Length + 1 .. Normal_Full'Last);
      else
         return Normal_Full (Normal_Full'First + Normal_Root'Length .. Normal_Full'Last);
      end if;
   end Relative_Path;

   function Source_Path_Text (Rules : Ignore_Rules; Path : String) return String is
      Root : constant String := To_String (Rules.Root_Path);
      Full : constant String :=
        Ignore_Path_Text
          (Ada.Directories.Full_Name (Version.Files.To_Native_Path (Path)));
   begin
      if Root'Length = 0 then
         return Full;
      else
         return Relative_Path (Root, Full);
      end if;
   exception
      when others =>
         return Ignore_Path_Text (Path);
   end Source_Path_Text;

   function Is_Escaped (Text : String; Pos : Positive) return Boolean is
      Count : Natural := 0;
      J     : Natural;
   begin
      if Pos = Text'First then
         return False;
      end if;

      J := Pos - 1;

      loop
         exit when J < Text'First;
         exit when Text (J) /= '\';

         Count := Count + 1;

         exit when J = Text'First;
         J := J - 1;
      end loop;

      return Count mod 2 = 1;
   end Is_Escaped;

   function Strip_Unescaped_Trailing_Spaces (Line : String) return String is
      Last : Natural := Line'Last;
   begin
      if Line'Length = 0 then
         return "";
      end if;

      while Last >= Line'First
        and then (Line (Last) = ' '
                  or else Line (Last) = Character'Val (13))
        and then not Is_Escaped (Line, Last)
      loop
         if Last = Line'First then
            return "";
         end if;

         Last := Last - 1;
      end loop;

      if Last < Line'First then
         return "";
      end if;

      return Line (Line'First .. Last);
   end Strip_Unescaped_Trailing_Spaces;

   function Has_Slash (Text : String) return Boolean is
   begin
      for C of Text loop
         if C = '/' then
            return True;
         end if;
      end loop;

      return False;
   end Has_Slash;

   function Is_Git_Internal_Path (Path : String) return Boolean is
   begin
      return
        Path = ".git"
        or else Path = ".git/"
        or else
          (Path'Length > 5
           and then Path (Path'First .. Path'First + 4) = ".git/");
   end Is_Git_Internal_Path;

   function Lower (Value : String) return String is
      Result : String := Value;
   begin
      for I in Result'Range loop
         if Result (I) in 'A' .. 'Z' then
            Result (I) :=
              Character'Val
                (Character'Pos (Result (I))
                 - Character'Pos ('A')
                 + Character'Pos ('a'));
         end if;
      end loop;

      return Result;
   end Lower;

   function Opposite_Case (Ch : Character) return Character is
   begin
      if Ch in 'A' .. 'Z' then
         return Character'Val
           (Character'Pos (Ch) - Character'Pos ('A') + Character'Pos ('a'));
      elsif Ch in 'a' .. 'z' then
         return Character'Val
           (Character'Pos (Ch) - Character'Pos ('a') + Character'Pos ('A'));
      else
         return Ch;
      end if;
   end Opposite_Case;

   function Characters_Equal
     (Left : Character; Right : Character; Case_Insensitive : Boolean)
      return Boolean is
   begin
      return
        Left = Right
        or else (Case_Insensitive and then Opposite_Case (Left) = Right);
   end Characters_Equal;

   function Strip_Config_Value_Comment (Value : String) return String is
      In_Quote : Boolean := False;
      Escaped  : Boolean := False;
   begin
      for I in Value'Range loop
         if Escaped then
            Escaped := False;
         elsif Value (I) = '\' then
            Escaped := True;
         elsif Value (I) = '"' then
            In_Quote := not In_Quote;
         elsif not In_Quote and then (Value (I) = '#' or else Value (I) = ';') then
            if I = Value'First
              or else Value (I - 1) = ' '
              or else Value (I - 1) = Character'Val (9)
            then
               if I = Value'First then
                  return "";
               else
                  return Version.Config.Trim (Value (Value'First .. I - 1));
               end if;
            end if;
         end if;
      end loop;

      return Version.Config.Trim (Value);
   end Strip_Config_Value_Comment;

   procedure Sort (Items : in out String_Vectors.Vector) is
      Swapped : Boolean := True;
   begin
      if Items.Length < 2 then
         return;
      end if;

      while Swapped loop
         Swapped := False;

         for I in Items.First_Index .. Items.Last_Index - 1 loop
            if To_String (Items.Element (I + 1))
              < To_String (Items.Element (I))
            then
               declare
                  Tmp : constant Unbounded_String := Items.Element (I);
               begin
                  Items.Replace_Element (I, Items.Element (I + 1));
                  Items.Replace_Element (I + 1, Tmp);
                  Swapped := True;
               end;
            end if;
         end loop;
      end loop;
   end Sort;

   function Class_Char
     (Pattern : String; Pos : Natural; Next : out Natural) return Character is
   begin
      if Pos <= Pattern'Last
        and then Pattern (Pos) = '\'
        and then Pos < Pattern'Last
      then
         Next := Pos + 2;
         return Pattern (Pos + 1);
      else
         Next := Pos + 1;
         return Pattern (Pos);
      end if;
   end Class_Char;

   function Posix_Class_Matches (Name : String; Ch : Character) return Boolean is
   begin
      if Name = "alnum" then
         return Ch in '0' .. '9' or else Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z';
      elsif Name = "alpha" then
         return Ch in 'A' .. 'Z' or else Ch in 'a' .. 'z';
      elsif Name = "blank" then
         return Ch = ' ' or else Ch = Character'Val (9);
      elsif Name = "cntrl" then
         return Character'Pos (Ch) < 32 or else Character'Pos (Ch) = 127;
      elsif Name = "digit" then
         return Ch in '0' .. '9';
      elsif Name = "graph" then
         return Character'Pos (Ch) in 33 .. 126;
      elsif Name = "lower" then
         return Ch in 'a' .. 'z';
      elsif Name = "print" then
         return Character'Pos (Ch) in 32 .. 126;
      elsif Name = "punct" then
         return
           Character'Pos (Ch) in 33 .. 47
           or else Character'Pos (Ch) in 58 .. 64
           or else Character'Pos (Ch) in 91 .. 96
           or else Character'Pos (Ch) in 123 .. 126;
      elsif Name = "space" then
         return
           Ch = ' '
           or else Ch = Character'Val (9)
           or else Ch = Character'Val (10)
           or else Ch = Character'Val (11)
           or else Ch = Character'Val (12)
           or else Ch = Character'Val (13);
      elsif Name = "upper" then
         return Ch in 'A' .. 'Z';
      elsif Name = "xdigit" then
         return
           Ch in '0' .. '9'
           or else Ch in 'A' .. 'F'
           or else Ch in 'a' .. 'f';
      else
         return False;
      end if;
   end Posix_Class_Matches;

   function Posix_Class_End (Pattern : String; Start : Positive) return Natural is
   begin
      if Start + 3 > Pattern'Last
        or else Pattern (Start) /= '['
        or else Pattern (Start + 1) /= ':'
      then
         return 0;
      end if;

      for I in Start + 2 .. Pattern'Last - 1 loop
         if Pattern (I) = ':' and then Pattern (I + 1) = ']' then
            return I + 1;
         end if;
      end loop;

      return 0;
   end Posix_Class_End;

   function Character_Class_Matches
     (Pattern : String;
      Start   : Positive;
      Ch      : Character;
      Closing : out Natural;
      Case_Insensitive : Boolean := False) return Boolean
   is
      I       : Natural := Start + 1;
      Negated : Boolean := False;
      Matched : Boolean := False;
   begin
      Closing := 0;

      if Ch = '/' then
         return False;
      end if;

      if I <= Pattern'Last
        and then (Pattern (I) = '!' or else Pattern (I) = '^')
      then
         Negated := True;
         I := I + 1;
      end if;

      while I <= Pattern'Last loop
         if Pattern (I) = ']'
           and then not Is_Escaped (Pattern, I)
           and then I > Start + 1
           and then not (Negated and then I = Start + 2)
         then
            Closing := I;
            return (if Negated then not Matched else Matched);
         end if;

         if Pattern (I) = '[' then
            declare
               Class_End : constant Natural := Posix_Class_End (Pattern, I);
            begin
               if Class_End /= 0 then
                  if Posix_Class_Matches
                       (Pattern (I + 2 .. Class_End - 2), Ch)
                    or else
                      (Case_Insensitive
                       and then Posix_Class_Matches
                         (Pattern (I + 2 .. Class_End - 2),
                          Opposite_Case (Ch)))
                  then
                     Matched := True;
                  end if;

                  I := Class_End + 1;
               end if;
            end;
         end if;

         if I <= Pattern'Last
           and then not
             (Pattern (I) = ']'
              and then not Is_Escaped (Pattern, I)
              and then I > Start + 1
              and then not (Negated and then I = Start + 2))
         then
            declare
               Low_Next : Natural;
               Low      : constant Character := Class_Char (Pattern, I, Low_Next);
            begin
               if Low_Next < Pattern'Last
                 and then Pattern (Low_Next) = '-'
                 and then Pattern (Low_Next + 1) /= ']'
               then
                  declare
                     High_Next : Natural;
                     High      : constant Character :=
                       Class_Char (Pattern, Low_Next + 1, High_Next);
                  begin
                     if (Low <= Ch and then Ch <= High)
                       or else
                         (Case_Insensitive
                          and then Low <= Opposite_Case (Ch)
                          and then Opposite_Case (Ch) <= High)
                     then
                        Matched := True;
                     end if;

                     I := High_Next;
                  end;
               else
                  if Characters_Equal (Low, Ch, Case_Insensitive) then
                     Matched := True;
                  end if;

                  I := Low_Next;
               end if;
            end;
         end if;
      end loop;

      Closing := 0;
      return False;
   end Character_Class_Matches;

   function Glob_Match
     (Pattern : String;
      Text : String;
      P : Positive;
      T : Positive;
      Case_Insensitive : Boolean := False)
      return Boolean is

      function Recursive_Double_Star return Boolean is
      begin
         return
           P < Pattern'Last
           and then Pattern (P + 1) = '*'
           and then
             (P + 1 = Pattern'Last
              or else (P + 2 <= Pattern'Last and then Pattern (P + 2) = '/'));
      end Recursive_Double_Star;
   begin
      if P > Pattern'Last then
         return T > Text'Last;
      end if;

      if Pattern (P) = '\'
        and then P < Pattern'Last
      then
         return
           T <= Text'Last
           and then Characters_Equal (Pattern (P + 1), Text (T), Case_Insensitive)
           and then Glob_Match (Pattern, Text, P + 2, T + 1, Case_Insensitive);
      elsif Pattern (P) = '*' and then Recursive_Double_Star then
         if Glob_Match (Pattern, Text, P + 2, T, Case_Insensitive) then
            return True;
         end if;

         if P + 2 <= Pattern'Last
           and then Pattern (P + 2) = '/'
           and then Glob_Match (Pattern, Text, P + 3, T, Case_Insensitive)
         then
            return True;
         end if;

         if T <= Text'Last then
            return Glob_Match (Pattern, Text, P, T + 1, Case_Insensitive);
         end if;

         return False;
      elsif Pattern (P) = '*' then
         if Glob_Match (Pattern, Text, P + 1, T, Case_Insensitive) then
            return True;
         end if;

         if T <= Text'Last and then Text (T) /= '/' then
            return Glob_Match (Pattern, Text, P, T + 1, Case_Insensitive);
         end if;

         return False;
      elsif Pattern (P) = '?' then
         return
           T <= Text'Last
           and then Text (T) /= '/'
           and then Glob_Match (Pattern, Text, P + 1, T + 1, Case_Insensitive);
      elsif Pattern (P) = '[' then
         declare
            Closing : Natural;
            Matched : Boolean := False;
         begin
            if T <= Text'Last then
               Matched :=
                 Character_Class_Matches
                   (Pattern => Pattern,
                    Start   => P,
                    Ch      => Text (T),
                    Closing => Closing,
                    Case_Insensitive => Case_Insensitive);

               if Closing /= 0 then
                  return
                    Matched
                    and then Glob_Match (Pattern, Text, Closing + 1, T + 1, Case_Insensitive);
               end if;
            end if;

            return False;
         end;
      else
         return
           T <= Text'Last
           and then Characters_Equal (Pattern (P), Text (T), Case_Insensitive)
           and then Glob_Match (Pattern, Text, P + 1, T + 1, Case_Insensitive);
      end if;
   end Glob_Match;

   function Glob_Match
     (Pattern : String; Text : String; Case_Insensitive : Boolean := False)
      return Boolean is
   begin
      if Pattern'Length = 0 then
         return Text'Length = 0;
      end if;

      return
        Glob_Match
          (Pattern => Pattern,
           Text    => Text,
           P       => Pattern'First,
           T       => Text'First,
           Case_Insensitive => Case_Insensitive);
   end Glob_Match;

   function Basename_Matches
     (Pattern : String; Path : String; Case_Insensitive : Boolean) return Boolean
   is
      Start : Positive := Path'First;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            if Glob_Match
                 (Pattern, Path (Start .. I - 1), Case_Insensitive)
            then
               return True;
            end if;

            if I < Path'Last then
               Start := I + 1;
            end if;
         end if;
      end loop;

      return Glob_Match
        (Pattern, Path (Start .. Path'Last), Case_Insensitive);
   end Basename_Matches;

   function Rule_Applies_To_Path
     (Item : Rule; Path : String; Local_Path : out Unbounded_String)
      return Boolean
   is
      Base : constant String := To_String (Item.Base_Dir);
   begin
      Local_Path := Null_Unbounded_String;

      if Base'Length = 0 then
         Local_Path := To_Unbounded_String (Path);
         return True;
      end if;

      if Path'Length < Base'Length then
         return False;
      end if;

      if Path (Path'First .. Path'First + Base'Length - 1) /= Base then
         return False;
      end if;

      if Path'Length = Base'Length then
         Local_Path := Null_Unbounded_String;
         return True;
      end if;

      if Path (Path'First + Base'Length) /= '/' then
         return False;
      end if;

      Local_Path :=
        To_Unbounded_String (Path (Path'First + Base'Length + 1 .. Path'Last));
      return True;
   end Rule_Applies_To_Path;

   function Single_Target_Matches
     (Item : Rule; Local : String; Case_Insensitive : Boolean) return Boolean
   is
      Pattern : constant String := To_String (Item.Pattern);
   begin
      if Local'Length = 0 then
         return False;
      end if;

      if Item.Anchored or else Item.Contains_Slash then
         return Glob_Match (Pattern, Local, Case_Insensitive);
      else
         return Basename_Matches (Pattern, Local, Case_Insensitive);
      end if;
   end Single_Target_Matches;

   function Trailing_Double_Star_Directory_Matches
     (Item : Rule; Local : String; Case_Insensitive : Boolean) return Boolean
   is
      Pattern : constant String := To_String (Item.Pattern);
   begin
      if not Item.Contains_Slash
        or else Pattern'Length < 3
        or else Pattern (Pattern'Last - 2 .. Pattern'Last) /= "/**"
      then
         return False;
      end if;

      declare
         Base : constant String := Pattern (Pattern'First .. Pattern'Last - 3);
      begin
         return
           Base'Length > 0
           and then
             (if Case_Insensitive then Lower (Local) = Lower (Base) else Local = Base);
      end;
   end Trailing_Double_Star_Directory_Matches;

   function Directory_Target_Matches
     (Item : Rule;
      Local : String;
      Target_Is_Directory : Boolean;
      Count_Trailing_Double_Star_Directory : Boolean;
      Case_Insensitive : Boolean)
      return Boolean is
   begin
      if Local'Length = 0 then
         return False;
      end if;

      if Target_Is_Directory
        and then (Single_Target_Matches (Item, Local, Case_Insensitive)
                  or else
                    (Count_Trailing_Double_Star_Directory
                     and then Trailing_Double_Star_Directory_Matches
                       (Item, Local, Case_Insensitive)))
      then
         return True;
      end if;

      for I in reverse Local'Range loop
         if Local (I) = '/' then
            if Single_Target_Matches
                 (Item, Local (Local'First .. I - 1), Case_Insensitive)
            then
               return True;
            end if;
         end if;
      end loop;

      return False;
   end Directory_Target_Matches;

   function Rule_Matches
     (Item                                : Rule;
      Relative_Path                       : String;
      Is_Directory                       : Boolean;
      Count_Trailing_Double_Star_Directory : Boolean := True;
      Case_Insensitive                   : Boolean := False)
      return Boolean
   is
      Local : Unbounded_String;
   begin
      if Relative_Path'Length = 0 then
         return False;
      end if;

      if Is_Git_Internal_Path (Relative_Path) then
         return False;
      end if;

      if not Rule_Applies_To_Path (Item, Relative_Path, Local) then
         return False;
      end if;

      declare
         Local_Text : constant String := To_String (Local);
      begin
         if Item.Directory_Only then
            return
              Directory_Target_Matches
                (Item                => Item,
                 Local               => Local_Text,
                 Target_Is_Directory => Is_Directory,
                 Count_Trailing_Double_Star_Directory =>
                   Count_Trailing_Double_Star_Directory,
                 Case_Insensitive    => Case_Insensitive);
         elsif Is_Directory then
            return
              Single_Target_Matches (Item, Local_Text, Case_Insensitive)
              or else Directory_Target_Matches
                (Item                => Item,
                 Local               => Local_Text,
                 Target_Is_Directory => True,
                 Count_Trailing_Double_Star_Directory =>
                   Count_Trailing_Double_Star_Directory,
                 Case_Insensitive    => Case_Insensitive)
              or else
                (Count_Trailing_Double_Star_Directory
                 and then Trailing_Double_Star_Directory_Matches
                            (Item, Local_Text, Case_Insensitive));
         else
            return
              Single_Target_Matches (Item, Local_Text, Case_Insensitive)
              or else Directory_Target_Matches
                (Item                => Item,
                 Local               => Local_Text,
                 Target_Is_Directory => False,
                 Count_Trailing_Double_Star_Directory =>
                   Count_Trailing_Double_Star_Directory,
                 Case_Insensitive    => Case_Insensitive);
         end if;
      end;
   end Rule_Matches;

   procedure Add_Rule
     (Rules       : in out Ignore_Rules;
      Base_Dir    : String;
      Line        : String;
      Source_Path : String;
      Source_Line : Natural)
   is
      Text           : constant String :=
        Strip_Unescaped_Trailing_Spaces (Line);
      First          : Positive := Text'First;
      Last           : Natural := Text'Last;
      Negated        : Boolean := False;
      Directory_Only : Boolean := False;
      Anchored       : Boolean := False;
   begin
      if Text'Length = 0 then
         return;
      end if;

      if Text (Text'First) = '#' then
         return;
      end if;

      if Text (First) = '!' then
         Negated := True;
         First := First + 1;
      end if;

      if First > Last then
         return;
      end if;

      if Text (First) = '/' and then not Is_Escaped (Text, First) then
         Anchored := True;
         First := First + 1;
      end if;

      if First > Last then
         return;
      end if;

      if Text (Last) = '/' and then not Is_Escaped (Text, Last) then
         Directory_Only := True;
         Last := Last - 1;
      end if;

      if First > Last then
         return;
      end if;

      declare
         Pattern : constant String := Text (First .. Last);
      begin
         Rules.Rules.Append
           (Rule'
              (Base_Dir       => To_Unbounded_String (Base_Dir),
               Pattern        => To_Unbounded_String (Pattern),
               Source_Path    => To_Unbounded_String (Source_Path),
               Source_Pattern => To_Unbounded_String (Text),
               Source_Line    => Source_Line,
               Negated        => Negated,
               Directory_Only => Directory_Only,
               Anchored       => Anchored,
               Contains_Slash => Has_Slash (Pattern)));
      end;
   end Add_Rule;

   function Strip_UTF8_BOM (Line : String) return String is
   begin
      if Line'Length >= 3
        and then Character'Pos (Line (Line'First)) = 16#EF#
        and then Character'Pos (Line (Line'First + 1)) = 16#BB#
        and then Character'Pos (Line (Line'First + 2)) = 16#BF#
      then
         if Line'Length = 3 then
            return "";
         else
            return Line (Line'First + 3 .. Line'Last);
         end if;
      else
         return Line;
      end if;
   end Strip_UTF8_BOM;

   function Is_Symbolic_Link (Path : String) return Boolean is
   begin
      return GNAT.OS_Lib.Is_Symbolic_Link (Version.Files.To_Native_Path (Path));
   exception
      when others =>
         return False;
   end Is_Symbolic_Link;

   procedure Load_File
     (Rules              : in out Ignore_Rules;
      Base_Dir           : String;
      Path               : String;
      Skip_Symbolic_Link : Boolean := False)
   is
      File       : Ada.Text_IO.File_Type;
      First_Line : Boolean := True;
      Line_No    : Natural := 0;
      Source     : constant String := Source_Path_Text (Rules, Path);
   begin
      if Skip_Symbolic_Link and then Is_Symbolic_Link (Path) then
         return;
      end if;

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            Line_No := Line_No + 1;
            Add_Rule
              (Rules       => Rules,
               Base_Dir    => Base_Dir,
               Line        =>
                 (if First_Line then Strip_UTF8_BOM (Line) else Line),
               Source_Path => Source,
               Source_Line => Line_No);
            First_Line := False;
         end;
      end loop;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Load_File;

   function Decode_Config_Path_Value (Text : String) return String is
      Value  : constant String := Version.Config.Trim (Text);
      Result : Unbounded_String;
      I      : Natural;
   begin
      if Value'Length >= 2
        and then Value (Value'First) = '"'
        and then Value (Value'Last) = '"'
      then
         I := Value'First + 1;

         while I < Value'Last loop
            if Value (I) = '\' and then I + 1 < Value'Last then
               case Value (I + 1) is
                  when '\' | '"' =>
                     Append (Result, Value (I + 1));
                  when 't' =>
                     Append (Result, Character'Val (9));
                  when 'n' =>
                     Append (Result, Character'Val (10));
                  when 'b' =>
                     Append (Result, Character'Val (8));
                  when others =>
                     raise Ada.IO_Exceptions.Data_Error
                       with "invalid quoted config path escape";
               end case;

               I := I + 2;
            else
               if Value (I) = '\' then
                  raise Ada.IO_Exceptions.Data_Error
                    with "unterminated quoted config path escape";
               end if;

               Append (Result, Value (I));
               I := I + 1;
            end if;
         end loop;

         return To_String (Result);
      end if;

      return Value;
   end Decode_Config_Path_Value;

   function Home_For_User (Name : String) return String is
      File : Ada.Text_IO.File_Type;
   begin
      if Version.Platform.Current /= Version.Platform.POSIX_Platform
        or else Name'Length = 0
      then
         return "";
      end if;

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "/etc/passwd");

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line        : constant String := Ada.Text_IO.Get_Line (File);
            First_Colon : Natural := 0;
         begin
            for I in Line'Range loop
               if Line (I) = ':' then
                  First_Colon := I;
                  exit;
               end if;
            end loop;

            if First_Colon > Line'First
              and then Line (Line'First .. First_Colon - 1) = Name
            then
               declare
                  Previous_Colon : Natural := First_Colon;
                  Colon_Index    : Natural := 1;
               begin
                  for I in First_Colon + 1 .. Line'Last loop
                     if Line (I) = ':' then
                        Colon_Index := Colon_Index + 1;

                        if Colon_Index = 6 then
                           Ada.Text_IO.Close (File);

                           if I > Previous_Colon + 1 then
                              return Line (Previous_Colon + 1 .. I - 1);
                           else
                              return "";
                           end if;
                        end if;

                        Previous_Colon := I;
                     end if;
                  end loop;

                  Ada.Text_IO.Close (File);
                  return "";
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
      return "";

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "";
   end Home_For_User;

   function Expand_Tilde_Path (Value : String) return String is
      Slash : Natural := 0;
   begin
      if Value'Length = 0 or else Value (Value'First) /= '~' then
         return "";
      elsif Value = "~" then
         if Ada.Environment_Variables.Exists ("HOME") then
            return Ada.Environment_Variables.Value ("HOME");
         else
            return "";
         end if;
      elsif Value'Length >= 2 and then Value (Value'First + 1) = '/' then
         if Ada.Environment_Variables.Exists ("HOME") then
            if Value'Length = 2 then
               return Ada.Environment_Variables.Value ("HOME") & "/";
            else
               return Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"),
                  Value (Value'First + 2 .. Value'Last));
            end if;
         else
            return "";
         end if;
      end if;

      for I in Value'First + 1 .. Value'Last loop
         if Value (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;

      declare
         User_Last : constant Natural :=
           (if Slash = 0 then Value'Last else Slash - 1);
         Home      : constant String :=
           Home_For_User (Value (Value'First + 1 .. User_Last));
      begin
         if Home'Length = 0 then
            return "";
         elsif Slash = 0 then
            return Home;
         elsif Slash = Value'Last then
            return Home & "/";
         else
            return Version.Files.Join (Home, Value (Slash + 1 .. Value'Last));
         end if;
      end;
   end Expand_Tilde_Path;

   function Interpolate_Config_Prefix
     (Base_Dir : String; Value : String) return String
   is
      Marker : constant String := "%(prefix)";
      Result : Unbounded_String;
      I      : Natural := Value'First;
   begin
      if Value'Length = 0 then
         return "";
      end if;

      while I <= Value'Last loop
         if Value'Last - I + 1 >= Marker'Length
           and then Value (I .. I + Marker'Length - 1) = Marker
         then
            if Base_Dir'Length = 0 then
               return "";
            end if;

            Append (Result, Base_Dir);
            I := I + Marker'Length;
         else
            Append (Result, Value (I));
            I := I + 1;
         end if;
      end loop;

      return To_String (Result);
   end Interpolate_Config_Prefix;

   function Resolve_Config_Path_Value
     (Base_Dir : String; Value : String) return String
   is
      Path_Value : constant String := Interpolate_Config_Prefix (Base_Dir, Value);
   begin
      if Path_Value'Length = 0 then
         return "";
      elsif Path_Value (Path_Value'First) = '~' then
         return Version.Files.Normalize_Separators (Expand_Tilde_Path (Path_Value));
      elsif Path_Value (Path_Value'First) = '/'
        or else Version.Platform.Is_Windows_Drive_Path (Path_Value)
      then
         return Version.Files.Normalize_Separators (Path_Value);
      elsif Base_Dir'Length = 0 then
         return "";
      else
         return Version.Files.Normalize_Separators
           (Version.Files.Join (Base_Dir, Path_Value));
      end if;
   end Resolve_Config_Path_Value;

   function Configured_Excludes_File_Path
     (Repo : Version.Repository.Repository_Handle; Text : String) return String
   is
   begin
      declare
         Value : constant String := Decode_Config_Path_Value (Text);
      begin
         return Resolve_Config_Path_Value
           (Version.Repository.Root_Path (Repo), Value);
      end;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return "";
   end Configured_Excludes_File_Path;

   function Default_Core_Excludes_File_Path return String is
   begin
      if Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME")
        and then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME")'Length > 0
      then
         return Version.Files.Normalize_Separators
           (Version.Files.Join
              (Ada.Environment_Variables.Value ("XDG_CONFIG_HOME"),
               "git/ignore"));
      elsif Ada.Environment_Variables.Exists ("HOME")
        and then Ada.Environment_Variables.Value ("HOME")'Length > 0
      then
         return Version.Files.Normalize_Separators
           (Version.Files.Join
              (Ada.Environment_Variables.Value ("HOME"),
               ".config/git/ignore"));
      else
         return "";
      end if;
   end Default_Core_Excludes_File_Path;

   function Gitdir_Condition_Pattern (Text : String) return String is
      Prefix   : constant String := "includeif ";
      Lowered  : constant String := Lower (Text);
      Gitdir   : constant String := "gitdir:";
      Gitdir_I : constant String := "gitdir/i:";
      First    : Natural;
      Last     : Natural;
   begin
      if Lowered'Length <= Prefix'Length
        or else Lowered (Lowered'First .. Lowered'First + Prefix'Length - 1)
                /= Prefix
      then
         return "";
      end if;

      First := Text'First + Prefix'Length;
      if First > Text'Last or else Text (First) /= Character'Val (34) then
         return "";
      end if;

      Last := First + 1;
      while Last <= Text'Last and then Text (Last) /= Character'Val (34) loop
         Last := Last + 1;
      end loop;

      if Last > Text'Last then
         return "";
      end if;

      declare
         Condition : constant String := Text (First + 1 .. Last - 1);
         Lower_Condition : constant String := Lower (Condition);
      begin
         if Lower_Condition'Length > Gitdir'Length
           and then Lower_Condition
             (Lower_Condition'First .. Lower_Condition'First + Gitdir'Length - 1)
             = Gitdir
         then
            return Condition (Condition'First + Gitdir'Length .. Condition'Last);
         elsif Lower_Condition'Length > Gitdir_I'Length
           and then Lower_Condition
             (Lower_Condition'First .. Lower_Condition'First + Gitdir_I'Length - 1)
             = Gitdir_I
         then
            return Condition (Condition'First + Gitdir_I'Length .. Condition'Last);
         else
            return "";
         end if;
      end;
   end Gitdir_Condition_Pattern;

   function Onbranch_Condition_Pattern (Text : String) return String is
      Prefix   : constant String := "includeif ";
      Lowered  : constant String := Lower (Text);
      Onbranch : constant String := "onbranch:";
      First    : Natural;
      Last     : Natural;
   begin
      if Lowered'Length <= Prefix'Length
        or else Lowered (Lowered'First .. Lowered'First + Prefix'Length - 1)
                /= Prefix
      then
         return "";
      end if;

      First := Text'First + Prefix'Length;
      if First > Text'Last or else Text (First) /= Character'Val (34) then
         return "";
      end if;

      Last := First + 1;
      while Last <= Text'Last and then Text (Last) /= Character'Val (34) loop
         Last := Last + 1;
      end loop;

      if Last > Text'Last then
         return "";
      end if;

      declare
         Condition       : constant String := Text (First + 1 .. Last - 1);
         Lower_Condition : constant String := Lower (Condition);
      begin
         if Lower_Condition'Length > Onbranch'Length
           and then Lower_Condition
             (Lower_Condition'First ..
              Lower_Condition'First + Onbranch'Length - 1) = Onbranch
         then
            return Condition (Condition'First + Onbranch'Length .. Condition'Last);
         else
            return "";
         end if;
      end;
   end Onbranch_Condition_Pattern;

   function Gitdir_Condition_Case_Insensitive (Text : String) return Boolean is
      Prefix   : constant String := "includeif ";
      Lowered  : constant String := Lower (Text);
      Gitdir_I : constant String := "gitdir/i:";
      First    : Natural;
      Last     : Natural;
   begin
      if Lowered'Length <= Prefix'Length
        or else Lowered (Lowered'First .. Lowered'First + Prefix'Length - 1)
                /= Prefix
      then
         return False;
      end if;

      First := Text'First + Prefix'Length;
      if First > Text'Last or else Text (First) /= Character'Val (34) then
         return False;
      end if;

      Last := First + 1;
      while Last <= Text'Last and then Text (Last) /= Character'Val (34) loop
         Last := Last + 1;
      end loop;

      if Last > Text'Last then
         return False;
      end if;

      declare
         Condition       : constant String := Text (First + 1 .. Last - 1);
         Lower_Condition : constant String := Lower (Condition);
      begin
         return
           Lower_Condition'Length > Gitdir_I'Length
           and then Lower_Condition
             (Lower_Condition'First ..
              Lower_Condition'First + Gitdir_I'Length - 1) = Gitdir_I;
      end;
   end Gitdir_Condition_Case_Insensitive;

   function Normalize_Gitdir_Condition_Pattern
     (Config_Path : String; Pattern : String) return String
   is
      Value : constant String := Decode_Config_Path_Value (Pattern);
      Result : Unbounded_String;
   begin
      if Value'Length = 0 then
         return "";
      elsif Value (Value'First) = '~' then
         declare
            Expanded : constant String := Expand_Tilde_Path (Value);
         begin
            if Expanded'Length = 0 then
               return "";
            end if;

            Result := To_Unbounded_String (Expanded);
         end;
      elsif Value'Length >= 2
        and then Value (Value'First) = '.'
        and then Value (Value'First + 1) = '/'
      then
         if Config_Path'Length = 0 then
            return "";
         end if;

         Result :=
           To_Unbounded_String
             (Version.Files.Join
                (Ada.Directories.Containing_Directory (Config_Path),
                 Value (Value'First + 2 .. Value'Last)));
      elsif Value (Value'First) = '/'
        or else Version.Platform.Is_Windows_Drive_Path (Value)
      then
         Result := To_Unbounded_String (Value);
      else
         Result := To_Unbounded_String ("**/" & Value);
      end if;

      declare
         Normal : constant String :=
           Version.Files.Normalize_Separators (To_String (Result));
      begin
         if Normal (Normal'Last) = '/' then
            return Normal & "**";
         else
            return Normal;
         end if;
      end;
   end Normalize_Gitdir_Condition_Pattern;

   function Normalize_Onbranch_Condition_Pattern (Pattern : String) return String is
      Value : constant String := Decode_Config_Path_Value (Pattern);
   begin
      if Value'Length = 0 then
         return "";
      elsif Value (Value'Last) = '/' then
         return Value & "**";
      else
         return Value;
      end if;
   end Normalize_Onbranch_Condition_Pattern;

   function Onbranch_Condition_Matches
     (Repo : Version.Repository.Repository_Handle; Pattern : String)
      return Boolean
   is
      Normal_Pattern : constant String :=
        Normalize_Onbranch_Condition_Pattern (Pattern);
   begin
      if Normal_Pattern'Length = 0 then
         return False;
      end if;

      return Glob_Match
        (Normal_Pattern,
         Version.Refs.Current_Branch_Name (Repo));
   exception
      when others =>
         return False;
   end Onbranch_Condition_Matches;

   function Hasconfig_Remote_Url_Pattern (Text : String) return String is
      Prefix    : constant String := "includeif ";
      Lowered   : constant String := Lower (Text);
      Condition : constant String := "hasconfig:remote.*.url:";
      First     : Natural;
      Last      : Natural;
   begin
      if Lowered'Length <= Prefix'Length
        or else Lowered (Lowered'First .. Lowered'First + Prefix'Length - 1)
                /= Prefix
      then
         return "";
      end if;

      First := Text'First + Prefix'Length;
      if First > Text'Last or else Text (First) /= Character'Val (34) then
         return "";
      end if;

      Last := First + 1;
      while Last <= Text'Last and then Text (Last) /= Character'Val (34) loop
         Last := Last + 1;
      end loop;

      if Last > Text'Last then
         return "";
      end if;

      declare
         Value       : constant String := Text (First + 1 .. Last - 1);
         Lower_Value : constant String := Lower (Value);
      begin
         if Lower_Value'Length > Condition'Length
           and then Lower_Value
             (Lower_Value'First .. Lower_Value'First + Condition'Length - 1)
             = Condition
         then
            return Value (Value'First + Condition'Length .. Value'Last);
         else
            return "";
         end if;
      end;
   end Hasconfig_Remote_Url_Pattern;

   function Remote_Config_Include_Path (Config_Path : String; Text : String) return String
   is
      Value : constant String := Decode_Config_Path_Value (Text);
   begin
      return Resolve_Config_Path_Value
        (Ada.Directories.Containing_Directory (Config_Path), Value);
   end Remote_Config_Include_Path;

   procedure Read_Remote_Urls_Config
     (Path  : String;
      Urls  : in out String_Vectors.Vector;
      Depth : Natural := 0)
   is
      File            : Ada.Text_IO.File_Type;
      Current_Section : Unbounded_String;
   begin
      if Depth > 10
        or else Path'Length = 0
        or else not Version.Files.Is_Ordinary_File (Path)
      then
         return;
      end if;

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Text : constant String :=
              Version.Config.Trim
                (Strip_Config_Value_Comment (Ada.Text_IO.Get_Line (File)));
         begin
            if Text'Length = 0
              or else Text (Text'First) = '#'
              or else Text (Text'First) = ';'
            then
               null;
            elsif Text (Text'First) = '[' and then Text (Text'Last) = ']' then
               Current_Section :=
                 To_Unbounded_String
                   (Version.Config.Trim
                      (Text (Text'First + 1 .. Text'Last - 1)));
            else
               declare
                  Section : constant String := Lower (To_String (Current_Section));
                  Eq_Pos  : Natural := 0;
               begin
                  for I in Text'Range loop
                     if Text (I) = '=' then
                        Eq_Pos := I;
                        exit;
                     end if;
                  end loop;

                  if Eq_Pos /= 0 then
                     declare
                        Key : constant String :=
                          Lower
                            (Version.Config.Trim
                               (Text (Text'First .. Eq_Pos - 1)));
                        Raw_Value : constant String :=
                          Strip_Config_Value_Comment
                            (Text (Eq_Pos + 1 .. Text'Last));
                     begin
                        if Section'Length >= 7
                          and then Section (Section'First .. Section'First + 6)
                            = "remote "
                          and then Key = "url"
                        then
                           Urls.Append
                             (To_Unbounded_String
                                (Decode_Config_Path_Value (Raw_Value)));
                        elsif Section = "include" and then Key = "path" then
                           Read_Remote_Urls_Config
                             (Remote_Config_Include_Path (Path, Raw_Value),
                              Urls,
                              Depth + 1);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Remote_Urls_Config;

   procedure Read_Remote_Urls_Env_Config (Urls : in out String_Vectors.Vector) is
      Name  : constant String := "GIT_CONFIG_COUNT";
      Count : Natural := 0;
   begin
      if not Ada.Environment_Variables.Exists (Name) then
         return;
      end if;

      declare
         Text : constant String := Ada.Environment_Variables.Value (Name);
      begin
         if Text'Length = 0 then
            return;
         end if;

         for C of Text loop
            if C not in '0' .. '9' then
               return;
            end if;

            Count := Count * 10 + Character'Pos (C) - Character'Pos ('0');
         end loop;
      end;

      if Count = 0 then
         return;
      end if;

      for Index in 0 .. Count - 1 loop
         declare
            Suffix     : constant String := Natural'Image (Index);
            Number     : constant String := Suffix (Suffix'First + 1 .. Suffix'Last);
            Key_Name   : constant String := "GIT_CONFIG_KEY_" & Number;
            Value_Name : constant String := "GIT_CONFIG_VALUE_" & Number;
         begin
            if Ada.Environment_Variables.Exists (Key_Name)
              and then Ada.Environment_Variables.Exists (Value_Name)
            then
               declare
                  Key : constant String :=
                    Lower (Ada.Environment_Variables.Value (Key_Name));
               begin
                  if Key'Length > 11
                    and then Key
                      (Key'First .. Key'First + 6) = "remote."
                    and then Key
                      (Key'Last - 3 .. Key'Last) = ".url"
                  then
                     Urls.Append
                       (To_Unbounded_String
                          (Ada.Environment_Variables.Value (Value_Name)));
                  end if;
               end;
            end if;
         end;
      end loop;
   end Read_Remote_Urls_Env_Config;

   function Remote_Urls_Match
     (Pattern : String; Urls : String_Vectors.Vector) return Boolean
   is
   begin
      if Pattern'Length = 0 or else Urls.Is_Empty then
         return False;
      end if;

      for I in Urls.First_Index .. Urls.Last_Index loop
         if Glob_Match (Pattern, To_String (Urls.Element (I))) then
            return True;
         end if;
      end loop;

      return False;
   end Remote_Urls_Match;

   function Has_Config_Remote_Url_Match
     (Repo : Version.Repository.Repository_Handle; Pattern : String) return Boolean
   is
      Urls         : String_Vectors.Vector;
      Local_Config : constant String :=
        Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "config");
   begin
      if Pattern'Length = 0 then
         return False;
      end if;

      if not (Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM")
              and then Ada.Environment_Variables.Value
                         ("GIT_CONFIG_NOSYSTEM")'Length > 0)
      then
         if Ada.Environment_Variables.Exists ("GIT_CONFIG_SYSTEM") then
            Read_Remote_Urls_Config
              (Ada.Environment_Variables.Value ("GIT_CONFIG_SYSTEM"), Urls);
         else
            Read_Remote_Urls_Config ("/etc/gitconfig", Urls);
         end if;
      end if;

      if Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL") then
         Read_Remote_Urls_Config
           (Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL"), Urls);
      else
         if Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME")
           and then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME")'Length > 0
         then
            Read_Remote_Urls_Config
              (Version.Files.Join
                 (Ada.Environment_Variables.Value ("XDG_CONFIG_HOME"),
                  "git/config"),
               Urls);
         elsif Ada.Environment_Variables.Exists ("HOME") then
            Read_Remote_Urls_Config
              (Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"),
                  ".config/git/config"),
               Urls);
         end if;

         if Ada.Environment_Variables.Exists ("HOME") then
            Read_Remote_Urls_Config
              (Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"), ".gitconfig"),
               Urls);
         end if;
      end if;

      Read_Remote_Urls_Config (Local_Config, Urls);
      Read_Remote_Urls_Env_Config (Urls);

      return Remote_Urls_Match (Pattern, Urls);
   end Has_Config_Remote_Url_Match;

   function Hasconfig_Section_Applies
     (Section : String; Urls : String_Vectors.Vector) return Boolean
   is
      Pattern : constant String := Hasconfig_Remote_Url_Pattern (Section);
   begin
      return Remote_Urls_Match (Pattern, Urls);
   end Hasconfig_Section_Applies;

   function Include_Section_Applies
     (Repo : Version.Repository.Repository_Handle;
      Config_Path : String;
      Section : String) return Boolean
   is
      Lowered          : constant String := Lower (Section);
      Gitdir_Pattern    : constant String := Gitdir_Condition_Pattern (Section);
      Onbranch_Pattern  : constant String := Onbranch_Condition_Pattern (Section);
      Hasconfig_Pattern : constant String := Hasconfig_Remote_Url_Pattern (Section);
   begin
      if Lowered = "include" then
         return True;
      elsif Gitdir_Pattern'Length > 0 then
         declare
            Normal_Pattern : constant String :=
              Normalize_Gitdir_Condition_Pattern (Config_Path, Gitdir_Pattern);
            Git_Dir        : constant String :=
              Version.Files.Normalize_Separators
                (Version.Repository.Git_Dir (Repo));
         begin
            if Gitdir_Condition_Case_Insensitive (Section) then
               return Glob_Match (Lower (Normal_Pattern), Lower (Git_Dir));
            else
               return Glob_Match (Normal_Pattern, Git_Dir);
            end if;
         end;
      elsif Onbranch_Pattern'Length > 0 then
         return Onbranch_Condition_Matches (Repo, Onbranch_Pattern);
      elsif Hasconfig_Pattern'Length > 0 then
         return Has_Config_Remote_Url_Match (Repo, Hasconfig_Pattern);
      else
         return False;
      end if;
   end Include_Section_Applies;

   function Config_Include_Path (Config_Path : String; Text : String) return String
   is
      Value : constant String := Decode_Config_Path_Value (Text);
   begin
      return Resolve_Config_Path_Value
        (Ada.Directories.Containing_Directory (Config_Path), Value);
   end Config_Include_Path;

   procedure Read_Core_Excludes_File_Config
     (Repo  : Version.Repository.Repository_Handle;
      Path  : String;
      Found : in out Boolean;
      Value : in out Unbounded_String;
      Depth : Natural := 0)
   is
      File               : Ada.Text_IO.File_Type;
      Current_Section    : Unbounded_String;
      Config_Remote_Urls : String_Vectors.Vector;
   begin
      if Depth > 10
        or else Path'Length = 0
        or else not Version.Files.Is_Ordinary_File (Path)
      then
         return;
      end if;

      Read_Remote_Urls_Config (Path, Config_Remote_Urls);

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Text : constant String :=
              Version.Config.Trim
                (Strip_Config_Value_Comment (Ada.Text_IO.Get_Line (File)));
         begin
            if Text'Length = 0
              or else Text (Text'First) = '#'
              or else Text (Text'First) = ';'
            then
               null;
            elsif Text (Text'First) = '[' and then Text (Text'Last) = ']' then
               Current_Section :=
                 To_Unbounded_String
                   (Version.Config.Trim
                      (Text (Text'First + 1 .. Text'Last - 1)));
            elsif Lower (To_String (Current_Section)) = "core"
              or else Include_Section_Applies
                (Repo, Path, To_String (Current_Section))
              or else Hasconfig_Section_Applies
                (To_String (Current_Section), Config_Remote_Urls)
            then
               declare
                  Eq_Pos : Natural := 0;
               begin
                  for I in Text'Range loop
                     if Text (I) = '=' then
                        Eq_Pos := I;
                        exit;
                     end if;
                  end loop;

                  if Eq_Pos /= 0 then
                     declare
                        Section : constant String :=
                          Lower (To_String (Current_Section));
                        Key     : constant String :=
                          Lower
                            (Version.Config.Trim
                               (Text (Text'First .. Eq_Pos - 1)));
                        Raw_Value : constant String :=
                          Strip_Config_Value_Comment
                            (Text (Eq_Pos + 1 .. Text'Last));
                     begin
                        if Section = "core" and then Key = "excludesfile" then
                           Found := True;
                           Value := To_Unbounded_String (Raw_Value);
                        elsif (Include_Section_Applies
                                (Repo, Path, To_String (Current_Section))
                               or else Hasconfig_Section_Applies
                                (To_String (Current_Section), Config_Remote_Urls))
                          and then Key = "path"
                        then
                           Read_Core_Excludes_File_Config
                             (Repo,
                              Config_Include_Path (Path, Raw_Value),
                              Found,
                              Value,
                              Depth + 1);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Core_Excludes_File_Config;

   function Env_Config_Include_Path (Text : String) return String is
   begin
      return Resolve_Config_Path_Value ("", Text);
   end Env_Config_Include_Path;

   function Env_Config_Count return Natural is
      Name  : constant String := "GIT_CONFIG_COUNT";
      Count : Natural := 0;
   begin
      if not Ada.Environment_Variables.Exists (Name) then
         return 0;
      end if;

      declare
         Text : constant String := Ada.Environment_Variables.Value (Name);
      begin
         if Text'Length = 0 then
            return 0;
         end if;

         for C of Text loop
            if C not in '0' .. '9' then
               return 0;
            end if;

            Count := Count * 10 + Character'Pos (C) - Character'Pos ('0');
         end loop;
      end;

      return Count;
   end Env_Config_Count;

   function Has_Suffix (Text : String; Suffix : String) return Boolean is
   begin
      return
        Text'Length >= Suffix'Length
        and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix;
   end Has_Suffix;

   function Starts_With (Text : String; Prefix : String) return Boolean is
   begin
      return
        Text'Length >= Prefix'Length
        and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix;
   end Starts_With;

   procedure Read_Core_Excludes_File_Env_Config
     (Repo  : Version.Repository.Repository_Handle;
      Found : in out Boolean;
      Value : in out Unbounded_String)
   is
      Count : constant Natural := Env_Config_Count;
   begin
      if Count = 0 then
         return;
      end if;

      for Index in 0 .. Count - 1 loop
         declare
            Includeif_Prefix : constant String := "includeif.";
            Path_Suffix      : constant String := ".path";
            Suffix           : constant String := Natural'Image (Index);
            Number           : constant String := Suffix (Suffix'First + 1 .. Suffix'Last);
            Key_Name         : constant String := "GIT_CONFIG_KEY_" & Number;
            Value_Name       : constant String := "GIT_CONFIG_VALUE_" & Number;
         begin
            if Ada.Environment_Variables.Exists (Key_Name)
              and then Ada.Environment_Variables.Exists (Value_Name)
            then
               declare
                  Raw_Key   : constant String :=
                    Ada.Environment_Variables.Value (Key_Name);
                  Key       : constant String := Lower (Raw_Key);
                  Raw_Value : constant String :=
                    Ada.Environment_Variables.Value (Value_Name);
               begin
                  if Key = "core.excludesfile" then
                     Found := True;
                     Value :=
                       To_Unbounded_String
                         (Resolve_Config_Path_Value
                            (Version.Repository.Root_Path (Repo), Raw_Value));
                  elsif Key = "include.path" then
                     Read_Core_Excludes_File_Config
                       (Repo,
                        Env_Config_Include_Path (Raw_Value),
                        Found,
                        Value);
                  elsif Starts_With (Key, Includeif_Prefix)
                    and then Has_Suffix (Key, Path_Suffix)
                    and then Key'Length > Includeif_Prefix'Length + Path_Suffix'Length
                  then
                     declare
                        Condition_First : constant Positive :=
                          Raw_Key'First + Includeif_Prefix'Length;
                        Condition_Last  : constant Natural :=
                          Raw_Key'Last - Path_Suffix'Length;
                        Section         : constant String :=
                          "includeIf " & Character'Val (34)
                          & Raw_Key (Condition_First .. Condition_Last)
                          & Character'Val (34);
                     begin
                        if Include_Section_Applies
                             (Repo, Env_Config_Include_Path ("."), Section)
                        then
                           Read_Core_Excludes_File_Config
                             (Repo,
                              Env_Config_Include_Path (Raw_Value),
                              Found,
                              Value);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Read_Core_Excludes_File_Env_Config;

   procedure Read_Core_Excludes_File_Config_Stack
     (Repo  : Version.Repository.Repository_Handle;
      Found : out Boolean;
      Value : out Unbounded_String)
   is
      Local_Config : constant String :=
        Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "config");
   begin
      Found := False;
      Value := Null_Unbounded_String;

      if not (Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM")
              and then Ada.Environment_Variables.Value
                         ("GIT_CONFIG_NOSYSTEM")'Length > 0)
      then
         if Ada.Environment_Variables.Exists ("GIT_CONFIG_SYSTEM") then
            Read_Core_Excludes_File_Config
              (Repo,
               Ada.Environment_Variables.Value ("GIT_CONFIG_SYSTEM"),
               Found,
               Value);
         else
            Read_Core_Excludes_File_Config (Repo, "/etc/gitconfig", Found, Value);
         end if;
      end if;

      if Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL") then
         Read_Core_Excludes_File_Config
           (Repo,
            Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL"),
            Found,
            Value);
      else
         if Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME")
           and then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME")'Length > 0
         then
            Read_Core_Excludes_File_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("XDG_CONFIG_HOME"),
                  "git/config"),
               Found,
               Value);
         elsif Ada.Environment_Variables.Exists ("HOME") then
            Read_Core_Excludes_File_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"),
                  ".config/git/config"),
               Found,
               Value);
         end if;

         if Ada.Environment_Variables.Exists ("HOME") then
            Read_Core_Excludes_File_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"), ".gitconfig"),
               Found,
               Value);
         end if;
      end if;

      Read_Core_Excludes_File_Config (Repo, Local_Config, Found, Value);
      Read_Core_Excludes_File_Env_Config (Repo, Found, Value);
   end Read_Core_Excludes_File_Config_Stack;

   function Config_Boolean_True (Text : String) return Boolean is
      Value : constant String := Lower (Version.Config.Trim (Text));
   begin
      return
        Value = "true"
        or else Value = "yes"
        or else Value = "on"
        or else Value = "1";
   end Config_Boolean_True;

   function Config_File_Boolean_True (Text : String) return Boolean is
   begin
      return Config_Boolean_True (Decode_Config_Path_Value (Text));
   end Config_File_Boolean_True;

   procedure Read_Core_Ignore_Case_Config
     (Repo  : Version.Repository.Repository_Handle;
      Path  : String;
      Found : in out Boolean;
      Value : in out Boolean;
      Depth : Natural := 0)
   is
      File               : Ada.Text_IO.File_Type;
      Current_Section    : Unbounded_String;
      Config_Remote_Urls : String_Vectors.Vector;
   begin
      if Depth > 10
        or else Path'Length = 0
        or else not Version.Files.Is_Ordinary_File (Path)
      then
         return;
      end if;

      Read_Remote_Urls_Config (Path, Config_Remote_Urls);

      Ada.Text_IO.Open
        (File, Ada.Text_IO.In_File, Version.Files.To_Native_Path (Path));

      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Text : constant String :=
              Version.Config.Trim
                (Strip_Config_Value_Comment (Ada.Text_IO.Get_Line (File)));
         begin
            if Text'Length = 0
              or else Text (Text'First) = '#'
              or else Text (Text'First) = ';'
            then
               null;
            elsif Text (Text'First) = '[' and then Text (Text'Last) = ']' then
               Current_Section :=
                 To_Unbounded_String
                   (Version.Config.Trim
                      (Text (Text'First + 1 .. Text'Last - 1)));
            elsif Lower (To_String (Current_Section)) = "core"
              or else Include_Section_Applies
                (Repo, Path, To_String (Current_Section))
              or else Hasconfig_Section_Applies
                (To_String (Current_Section), Config_Remote_Urls)
            then
               declare
                  Eq_Pos : Natural := 0;
               begin
                  for I in Text'Range loop
                     if Text (I) = '=' then
                        Eq_Pos := I;
                        exit;
                     end if;
                  end loop;

                  if Eq_Pos /= 0 then
                     declare
                        Section : constant String :=
                          Lower (To_String (Current_Section));
                        Key     : constant String :=
                          Lower
                            (Version.Config.Trim
                               (Text (Text'First .. Eq_Pos - 1)));
                        Raw_Value : constant String :=
                          Strip_Config_Value_Comment
                            (Text (Eq_Pos + 1 .. Text'Last));
                     begin
                        if Section = "core" and then Key = "ignorecase" then
                           Found := True;
                           Value := Config_File_Boolean_True (Raw_Value);
                        elsif (Include_Section_Applies
                                (Repo, Path, To_String (Current_Section))
                               or else Hasconfig_Section_Applies
                                (To_String (Current_Section), Config_Remote_Urls))
                          and then Key = "path"
                        then
                           Read_Core_Ignore_Case_Config
                             (Repo,
                              Config_Include_Path (Path, Raw_Value),
                              Found,
                              Value,
                              Depth + 1);
                        end if;
                     end;
                  elsif Lower (To_String (Current_Section)) = "core"
                    and then Lower (Version.Config.Trim (Text)) = "ignorecase"
                  then
                     Found := True;
                     Value := True;
                  end if;
               end;
            end if;
         end;
      end loop;

      Ada.Text_IO.Close (File);

   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Read_Core_Ignore_Case_Config;

   procedure Read_Core_Ignore_Case_Env_Config
     (Repo  : Version.Repository.Repository_Handle;
      Found : in out Boolean;
      Value : in out Boolean)
   is
      Count : constant Natural := Env_Config_Count;
   begin
      if Count = 0 then
         return;
      end if;

      for Index in 0 .. Count - 1 loop
         declare
            Includeif_Prefix : constant String := "includeif.";
            Path_Suffix      : constant String := ".path";
            Suffix           : constant String := Natural'Image (Index);
            Number           : constant String := Suffix (Suffix'First + 1 .. Suffix'Last);
            Key_Name         : constant String := "GIT_CONFIG_KEY_" & Number;
            Value_Name       : constant String := "GIT_CONFIG_VALUE_" & Number;
         begin
            if Ada.Environment_Variables.Exists (Key_Name)
              and then Ada.Environment_Variables.Exists (Value_Name)
            then
               declare
                  Raw_Key   : constant String :=
                    Ada.Environment_Variables.Value (Key_Name);
                  Key       : constant String := Lower (Raw_Key);
                  Raw_Value : constant String :=
                    Ada.Environment_Variables.Value (Value_Name);
               begin
                  if Key = "core.ignorecase" then
                     Found := True;
                     Value := Config_Boolean_True (Raw_Value);
                  elsif Key = "include.path" then
                     Read_Core_Ignore_Case_Config
                       (Repo,
                        Env_Config_Include_Path (Raw_Value),
                        Found,
                        Value);
                  elsif Starts_With (Key, Includeif_Prefix)
                    and then Has_Suffix (Key, Path_Suffix)
                    and then Key'Length > Includeif_Prefix'Length + Path_Suffix'Length
                  then
                     declare
                        Condition_First : constant Positive :=
                          Raw_Key'First + Includeif_Prefix'Length;
                        Condition_Last  : constant Natural :=
                          Raw_Key'Last - Path_Suffix'Length;
                        Section         : constant String :=
                          "includeIf " & Character'Val (34)
                          & Raw_Key (Condition_First .. Condition_Last)
                          & Character'Val (34);
                     begin
                        if Include_Section_Applies
                             (Repo, Env_Config_Include_Path ("."), Section)
                        then
                           Read_Core_Ignore_Case_Config
                             (Repo,
                              Env_Config_Include_Path (Raw_Value),
                              Found,
                              Value);
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Read_Core_Ignore_Case_Env_Config;

   function Core_Ignore_Case
     (Repo : Version.Repository.Repository_Handle) return Boolean
   is
      Local_Config : constant String :=
        Version.Files.Join (Version.Repository.Common_Git_Dir (Repo), "config");
      Found : Boolean := False;
      Value : Boolean := False;
   begin
      if not (Ada.Environment_Variables.Exists ("GIT_CONFIG_NOSYSTEM")
              and then Ada.Environment_Variables.Value
                         ("GIT_CONFIG_NOSYSTEM")'Length > 0)
      then
         if Ada.Environment_Variables.Exists ("GIT_CONFIG_SYSTEM") then
            Read_Core_Ignore_Case_Config
              (Repo, Ada.Environment_Variables.Value ("GIT_CONFIG_SYSTEM"),
               Found, Value);
         else
            Read_Core_Ignore_Case_Config
              (Repo, "/etc/gitconfig", Found, Value);
         end if;
      end if;

      if Ada.Environment_Variables.Exists ("GIT_CONFIG_GLOBAL") then
         Read_Core_Ignore_Case_Config
           (Repo, Ada.Environment_Variables.Value ("GIT_CONFIG_GLOBAL"),
            Found, Value);
      else
         if Ada.Environment_Variables.Exists ("XDG_CONFIG_HOME")
           and then Ada.Environment_Variables.Value ("XDG_CONFIG_HOME")'Length > 0
         then
            Read_Core_Ignore_Case_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("XDG_CONFIG_HOME"),
                  "git/config"),
               Found,
               Value);
         elsif Ada.Environment_Variables.Exists ("HOME") then
            Read_Core_Ignore_Case_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"),
                  ".config/git/config"),
               Found,
               Value);
         end if;

         if Ada.Environment_Variables.Exists ("HOME") then
            Read_Core_Ignore_Case_Config
              (Repo,
               Version.Files.Join
                 (Ada.Environment_Variables.Value ("HOME"), ".gitconfig"),
               Found,
               Value);
         end if;
      end if;

      Read_Core_Ignore_Case_Config (Repo, Local_Config, Found, Value);
      Read_Core_Ignore_Case_Env_Config (Repo, Found, Value);

      return (if Found then Value else False);
   end Core_Ignore_Case;

   procedure Load_Core_Excludes_File
     (Rules : in out Ignore_Rules; Repo : Version.Repository.Repository_Handle)
   is
      Found : Boolean;
      Value : Unbounded_String;
   begin
      Read_Core_Excludes_File_Config_Stack
        (Repo  => Repo,
         Found => Found,
         Value => Value);

      declare
         Path : constant String :=
           (if Found
            then Configured_Excludes_File_Path (Repo, To_String (Value))
            else Default_Core_Excludes_File_Path);
      begin
         if Path'Length > 0 and then Version.Files.Is_Ordinary_File (Path) then
            Load_File (Rules => Rules, Base_Dir => "", Path => Path);
         end if;
      end;
   end Load_Core_Excludes_File;

   procedure Load_Info_Exclude
     (Rules : in out Ignore_Rules; Git_Dir : String)
   is
      Path : constant String := Version.Files.Join (Git_Dir, "info/exclude");
   begin
      if Version.Files.Is_Ordinary_File (Path) then
         Load_File (Rules => Rules, Base_Dir => "", Path => Path);
      end if;
   end Load_Info_Exclude;

   procedure Scan_Directory
     (Rules : in out Ignore_Rules; Root : String; Dir : String)
   is
      Search : Ada.Directories.Search_Type;
      E      : Ada.Directories.Directory_Entry_Type;
      Opened : Boolean := False;
      Dirs   : String_Vectors.Vector;
      Files  : String_Vectors.Vector;
   begin
      Ada.Directories.Start_Search
        (Search    => Search,
         Directory => Dir,
         Pattern   => "",
         Filter    =>
           [Ada.Directories.Ordinary_File => True,
            Ada.Directories.Directory     => True,
            Ada.Directories.Special_File  => False]);

      Opened := True;

      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, E);

         declare
            Name : constant String := Ada.Directories.Simple_Name (E);
            Full : constant String := Ada.Directories.Full_Name (E);
         begin
            if Name /= "." and then Name /= ".." then
               if Ada.Directories.Kind (E) = Ada.Directories.Directory then
                  if Name /= ".git" then
                     Dirs.Append (To_Unbounded_String (Full));
                  end if;
               elsif Ada.Directories.Kind (E) = Ada.Directories.Ordinary_File
               then
                  Files.Append (To_Unbounded_String (Full));
               end if;
            end if;
         end;
      end loop;

      Ada.Directories.End_Search (Search);
      Opened := False;

      Sort (Files);
      Sort (Dirs);

      if not Files.Is_Empty then
         for I in Files.First_Index .. Files.Last_Index loop
            declare
               Full : constant String := To_String (Files.Element (I));
            begin
               if Ada.Directories.Simple_Name (Full) = ".gitignore" then
                  Load_File
                    (Rules              => Rules,
                     Base_Dir           => Relative_Path (Root, Dir),
                     Path               => Full,
                     Skip_Symbolic_Link => True);
               end if;
            end;
         end loop;
      end if;

      if not Dirs.Is_Empty then
         for I in Dirs.First_Index .. Dirs.Last_Index loop
            Scan_Directory
              (Rules => Rules,
               Root  => Root,
               Dir   => To_String (Dirs.Element (I)));
         end loop;
      end if;

   exception
      when others =>
         if Opened then
            Ada.Directories.End_Search (Search);
         end if;
   end Scan_Directory;

   function Load (Root : String) return Ignore_Rules is
      Result : Ignore_Rules;
      Git    : constant String := Version.Repository.Resolve_Git_Dir (Root);
   begin
      declare
         Scan_Root : constant String := Canonical_Root_Path (Root);
      begin
         Result.Root_Path := To_Unbounded_String (Scan_Root);

         if Git'Length > 0 then
            declare
               Repo : constant Version.Repository.Repository_Handle :=
                 Version.Repository.Open_Git_Dir (Git);
            begin
               Result.Case_Insensitive := Core_Ignore_Case (Repo);
               Load_Core_Excludes_File (Rules => Result, Repo => Repo);
               Load_Info_Exclude
                 (Rules   => Result,
                  Git_Dir => Version.Repository.Common_Git_Dir (Repo));
            end;
         end if;

         Scan_Directory (Rules => Result, Root => Scan_Root, Dir => Scan_Root);
      end;

      return Result;
   end Load;

   function Load
     (Repo : Version.Repository.Repository_Handle) return Ignore_Rules
   is
      Result : Ignore_Rules;
   begin
      Result.Root_Path :=
        To_Unbounded_String
          (Version.Files.Normalize_Separators
             (Version.Repository.Root_Path (Repo)));
      Result.Case_Insensitive := Core_Ignore_Case (Repo);
      Load_Core_Excludes_File (Rules => Result, Repo => Repo);
      Load_Info_Exclude
        (Rules   => Result,
         Git_Dir => Version.Repository.Common_Git_Dir (Repo));
      Scan_Directory
        (Rules => Result,
         Root  => Version.Repository.Root_Path (Repo),
         Dir   => Version.Repository.Root_Path (Repo));
      return Result;
   end Load;

   function Normalize_Query_Path_Text (Path : String) return String is
   begin
      if Version.Platform.Current = Version.Platform.Windows_Platform then
         return Version.Files.Normalize_Separators (Path);
      else
         return Path;
      end if;
   end Normalize_Query_Path_Text;

   function Normalize_Query_Path (Root : String; Path : String) return String is
      Normal_Root : constant String := Normalize_Query_Path_Text (Root);
      Normal_Path : constant String := Normalize_Query_Path_Text (Path);
      Components  : String_Vectors.Vector;
      Result      : Unbounded_String;
      First       : Positive := Normal_Path'First;
      Last        : constant Natural := Normal_Path'Last;
      I           : Natural;
   begin
      if Normal_Path'Length = 0 then
         return "";
      end if;

      if Normal_Path (Normal_Path'First) = '/'
        or else Version.Platform.Is_Windows_Drive_Path (Normal_Path)
      then
         if Normal_Root'Length = 0
           or else Normal_Path'Length < Normal_Root'Length
           or else Normal_Path
             (Normal_Path'First .. Normal_Path'First + Normal_Root'Length - 1)
             /= Normal_Root
         then
            return "";
         elsif Normal_Path'Length = Normal_Root'Length then
            return "";
         elsif Normal_Path (Normal_Path'First + Normal_Root'Length) /= '/' then
            return "";
         else
            First := Normal_Path'First + Normal_Root'Length + 1;
         end if;
      end if;

      I := First;

      while I <= Last loop
         declare
            J : Natural := I;
         begin
            while J <= Last and then Normal_Path (J) /= '/' loop
               J := J + 1;
            end loop;

            declare
               Component_Last : constant Natural := J - 1;
               Component      : constant String :=
                 (if Component_Last >= I then Normal_Path (I .. Component_Last) else "");
            begin
               if Component'Length = 0 or else Component = "." then
                  null;
               elsif Component = ".." then
                  if Components.Is_Empty then
                     return "";
                  end if;

                  Components.Delete_Last;
               else
                  Components.Append (To_Unbounded_String (Component));
               end if;
            end;

            I := J + 1;
         end;
      end loop;

      if not Components.Is_Empty then
         for Index in Components.First_Index .. Components.Last_Index loop
            if Length (Result) > 0 then
               Append (Result, '/');
            end if;

            Append (Result, Components.Element (Index));
         end loop;
      end if;

      return To_String (Result);
   end Normalize_Query_Path;

   function Match_Direct
     (Rules                               : Ignore_Rules;
      Relative_Path                       : String;
      Is_Directory                       : Boolean;
      Count_Trailing_Double_Star_Directory : Boolean := True)
      return Match_Result
   is
      Result : Match_Result;
   begin
      if Relative_Path'Length = 0 then
         return Result;
      end if;

      if Is_Git_Internal_Path (Relative_Path) then
         return Result;
      end if;

      if not Rules.Rules.Is_Empty then
         for I in Rules.Rules.First_Index .. Rules.Rules.Last_Index loop
            declare
               Item : constant Rule := Rules.Rules.Element (I);
            begin
               if Rule_Matches
                    (Item                                => Item,
                     Relative_Path                       => Relative_Path,
                     Is_Directory                       => Is_Directory,
                     Count_Trailing_Double_Star_Directory =>
                       Count_Trailing_Double_Star_Directory,
                     Case_Insensitive => Rules.Case_Insensitive)
               then
                  Result :=
                    (Has_Match   => True,
                     Is_Ignored  => not Item.Negated,
                     Source_Path => Item.Source_Path,
                     Source_Line => Item.Source_Line,
                     Pattern     => Item.Source_Pattern);
               end if;
            end;
         end loop;
      end if;

      return Result;
   end Match_Direct;

   function Is_Ignored_Direct
     (Rules                               : Ignore_Rules;
      Relative_Path                       : String;
      Is_Directory                       : Boolean;
      Count_Trailing_Double_Star_Directory : Boolean := True)
      return Boolean
   is
   begin
      return
        Match_Direct
          (Rules                               => Rules,
           Relative_Path                       => Relative_Path,
           Is_Directory                       => Is_Directory,
           Count_Trailing_Double_Star_Directory =>
             Count_Trailing_Double_Star_Directory).Is_Ignored;
   end Is_Ignored_Direct;

   function Ignored_Parent_Match
     (Rules : Ignore_Rules; Relative_Path : String) return Match_Result
   is
      Result : Match_Result;
   begin
      if Relative_Path'Length = 0 then
         return Result;
      end if;

      for I in Relative_Path'Range loop
         if Relative_Path (I) = '/' and then I > Relative_Path'First then
            declare
               Parent : constant Match_Result :=
                 Match_Direct
                   (Rules                               => Rules,
                    Relative_Path                       =>
                      Relative_Path (Relative_Path'First .. I - 1),
                    Is_Directory                       => True,
                    Count_Trailing_Double_Star_Directory => False);
            begin
               if Parent.Is_Ignored then
                  return Parent;
               end if;
            end;
         end if;
      end loop;

      return Result;
   end Ignored_Parent_Match;

   function Has_Ignored_Parent
     (Rules : Ignore_Rules; Relative_Path : String) return Boolean is
   begin
      return Ignored_Parent_Match (Rules, Relative_Path).Is_Ignored;
   end Has_Ignored_Parent;

   function Match
     (Rules : Ignore_Rules; Relative_Path : String; Is_Directory : Boolean)
      return Match_Result
   is
      Normal_Path : constant String :=
        Normalize_Query_Path (To_String (Rules.Root_Path), Relative_Path);
      Result      : Match_Result;
   begin
      if Normal_Path'Length = 0 then
         return Result;
      end if;

      if Is_Git_Internal_Path (Normal_Path) then
         return Result;
      end if;

      declare
         Parent : constant Match_Result :=
           Ignored_Parent_Match (Rules => Rules, Relative_Path => Normal_Path);
      begin
         if Parent.Is_Ignored then
            return Parent;
         end if;
      end;

      return
        Match_Direct
          (Rules         => Rules,
           Relative_Path => Normal_Path,
           Is_Directory  => Is_Directory);
   end Match;

   function Is_Ignored
     (Rules : Ignore_Rules; Relative_Path : String; Is_Directory : Boolean)
      return Boolean
   is
   begin
      return Match (Rules, Relative_Path, Is_Directory).Is_Ignored;
   end Is_Ignored;

end Version.Ignore;
