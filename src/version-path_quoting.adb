with Ada.Strings.Unbounded;

package body Version.Path_Quoting is

   use Ada.Strings.Unbounded;

   --  git's cq_lookup: the bytes that get a short escape.
   function Short_Escape (C : Character) return Character is
   begin
      case Character'Pos (C) is
         when 7      => return 'a';
         when 8      => return 'b';
         when 9      => return 't';
         when 10     => return 'n';
         when 11     => return 'v';
         when 12     => return 'f';
         when 13     => return 'r';
         when 34     => return '"';
         when 92     => return '\';
         when others => return ' ';   --  no short form
      end case;
   end Short_Escape;

   function Needs_Escape (C : Character) return Boolean is
     (Character'Pos (C) < 16#20#           --  control characters
      or else Character'Pos (C) = 16#7F#   --  DEL
      or else Character'Pos (C) >= 16#80#  --  high bit (core.quotePath)
      or else C = '"'
      or else C = '\');

   function Needs_Quoting (Path : String) return Boolean is
   begin
      for C of Path loop
         if Needs_Escape (C) then
            return True;
         end if;
      end loop;

      return False;
   end Needs_Quoting;

   function Quote_C_Style (Path : String) return String is
      Result : Unbounded_String;

      --  Three octal digits, as git emits for a byte with no short escape.
      function Octal (C : Character) return String is
         Value  : constant Natural := Character'Pos (C);
         Digits_Set : constant String := "01234567";
      begin
         return [1 => Digits_Set (Digits_Set'First + (Value / 64) mod 8),
                 2 => Digits_Set (Digits_Set'First + (Value / 8) mod 8),
                 3 => Digits_Set (Digits_Set'First + Value mod 8)];
      end Octal;
   begin
      if not Needs_Quoting (Path) then
         return Path;
      end if;

      Append (Result, '"');
      for C of Path loop
         if Needs_Escape (C) then
            declare
               Short : constant Character := Short_Escape (C);
            begin
               if Short /= ' ' then
                  Append (Result, '\');
                  Append (Result, Short);
               else
                  Append (Result, '\');
                  Append (Result, Octal (C));
               end if;
            end;
         else
            Append (Result, C);
         end if;
      end loop;
      Append (Result, '"');

      return To_String (Result);
   end Quote_C_Style;

end Version.Path_Quoting;
