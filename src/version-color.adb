with Ada.Characters.Handling; use Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Version.Color is

   --  git's attribute table, in the order git emits set attributes.
   type Attr is record
      Name : access constant String;
      Code : Natural;   --  the "set" code; the "no-" form uses Neg
      Neg  : Natural;
   end record;

   N_Bold    : aliased constant String := "bold";
   N_Dim     : aliased constant String := "dim";
   N_Italic  : aliased constant String := "italic";
   N_Ul      : aliased constant String := "ul";
   N_Blink   : aliased constant String := "blink";
   N_Reverse : aliased constant String := "reverse";
   N_Strike  : aliased constant String := "strike";

   Attrs : constant array (Positive range <>) of Attr :=
     ((N_Bold'Access,    1, 22),
      (N_Dim'Access,     2, 22),
      (N_Italic'Access,  3, 23),
      (N_Ul'Access,      4, 24),
      (N_Blink'Access,   5, 25),
      (N_Reverse'Access, 7, 27),
      (N_Strike'Access,  9, 29));

   type Color_Names is array (0 .. 7) of access constant String;
   C_Black   : aliased constant String := "black";
   C_Red     : aliased constant String := "red";
   C_Green   : aliased constant String := "green";
   C_Yellow  : aliased constant String := "yellow";
   C_Blue    : aliased constant String := "blue";
   C_Magenta : aliased constant String := "magenta";
   C_Cyan    : aliased constant String := "cyan";
   C_White   : aliased constant String := "white";
   Names : constant Color_Names :=
     (C_Black'Access, C_Red'Access, C_Green'Access, C_Yellow'Access,
      C_Blue'Access, C_Magenta'Access, C_Cyan'Access, C_White'Access);

   function To_Ansi (Spec : String) return String is
      use Ada.Strings.Unbounded;

      Out_Codes : Unbounded_String;   --  the emitted numeric codes, ";"-joined
      Saw_Reset : Boolean := False;
      Fg, Bg    : Integer := -1;   --  colour slot state: -1 = "normal", unset
      Fg_Set    : Boolean := False;
      Bg_Set    : Boolean := False;
      Fg_Rgb    : Unbounded_String;   --  non-empty ⇒ a "#rrggbb" foreground
      Bg_Rgb    : Unbounded_String;

      procedure Add (Code : String) is
      begin
         if Length (Out_Codes) > 0 then
            Append (Out_Codes, ";");
         end if;
         Append (Out_Codes, Code);
      end Add;

      --  Attributes recorded as they are parsed, then emitted in table order.
      Have_Attr : array (Attrs'Range) of Boolean := (others => False);
      Neg_Attr  : array (Attrs'Range) of Boolean := (others => False);

      function Slot_Value (Word : String) return Integer;
      --  A colour slot value: -1 for "normal", 0..255 for a name or number, or
      --  raises Constraint_Error via a sentinel we never hit here. Returns
      --  -2 when Word is a "#rrggbb" literal (handled by the caller).

      function Slot_Value (Word : String) return Integer is
         Low : constant String := To_Lower (Word);
      begin
         if Low = "normal" then
            return -1;
         end if;
         for I in Names'Range loop
            if Low = Names (I).all then
               return I;
            end if;
         end loop;
         if Low'Length > 6 and then Low (Low'First .. Low'First + 5) = "bright"
         then
            declare
               Rest : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Low (Low'First + 6 .. Low'Last), Ada.Strings.Both);
            begin
               for I in Names'Range loop
                  if Rest = Names (I).all then
                     return I + 8;
                  end if;
               end loop;
            end;
         end if;
         --  A bare number 0..255.
         return Integer'Value (Word);
      end Slot_Value;

      function Rgb_Codes (Word : String) return String is
         --  "#rrggbb" → "r;g;b" in decimal.
         R : constant Natural := Natural'Value ("16#" & Word (Word'First + 1 ..
                                                Word'First + 2) & "#");
         G : constant Natural := Natural'Value ("16#" & Word (Word'First + 3 ..
                                                Word'First + 4) & "#");
         B : constant Natural := Natural'Value ("16#" & Word (Word'First + 5 ..
                                                Word'First + 6) & "#");
         function Img (N : Natural) return String is
           (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));
      begin
         return Img (R) & ";" & Img (G) & ";" & Img (B);
      end Rgb_Codes;

      procedure Take_Slot (Word : String) is
      begin
         if Word (Word'First) = '#' then
            if not Fg_Set then
               Fg_Set := True;
               Fg := -2;
               Fg_Rgb := To_Unbounded_String (Rgb_Codes (Word));
            elsif not Bg_Set then
               Bg_Set := True;
               Bg := -2;
               Bg_Rgb := To_Unbounded_String (Rgb_Codes (Word));
            end if;
            return;
         end if;
         declare
            V : constant Integer := Slot_Value (Word);
         begin
            if not Fg_Set then
               Fg_Set := True;
               Fg := V;
            elsif not Bg_Set then
               Bg_Set := True;
               Bg := V;
            end if;
         end;
      end Take_Slot;

      procedure Emit_Slot (V : Integer; Rgb : String;
                           Base, Bright, Ext : Natural) is
         function Img (N : Natural) return String is
           (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));
      begin
         if V = -1 then
            null;   --  "normal": emit nothing for this slot
         elsif V = -2 then
            Add (Img (Ext) & ";2;" & Rgb);
         elsif V < 8 then
            Add (Img (Base + V));
         elsif V < 16 then
            Add (Img (Bright + (V - 8)));
         else
            Add (Img (Ext) & ";5;" & Img (V));
         end if;
      end Emit_Slot;

      First : Natural := Spec'First;
   begin
      --  Split Spec on blanks, classifying each word.
      while First <= Spec'Last loop
         --  Skip leading blanks.
         while First <= Spec'Last and then Spec (First) = ' ' loop
            First := First + 1;
         end loop;
         exit when First > Spec'Last;
         declare
            Last : Natural := First;
         begin
            while Last <= Spec'Last and then Spec (Last) /= ' ' loop
               Last := Last + 1;
            end loop;
            declare
               Word : constant String := Spec (First .. Last - 1);
               Low  : constant String := To_Lower (Word);
               Neg  : Boolean := False;
               Base : Ada.Strings.Unbounded.Unbounded_String :=
                 Ada.Strings.Unbounded.To_Unbounded_String (Low);
               Done : Boolean := False;
            begin
               if Low = "reset" then
                  Saw_Reset := True;
                  Done := True;
               elsif Low = "nobold" or else Low = "no-bold" then
                  Neg := True;
                  Base := Ada.Strings.Unbounded.To_Unbounded_String ("bold");
               elsif Low'Length > 3 and then Low (Low'First .. Low'First + 2)
                       = "no-"
               then
                  Neg := True;
                  Base := Ada.Strings.Unbounded.To_Unbounded_String
                            (Low (Low'First + 3 .. Low'Last));
               elsif Low'Length > 2 and then Low (Low'First .. Low'First + 1)
                       = "no"
                 and then (for some A of Attrs =>
                             A.Name.all = Low (Low'First + 2 .. Low'Last))
               then
                  Neg := True;
                  Base := Ada.Strings.Unbounded.To_Unbounded_String
                            (Low (Low'First + 2 .. Low'Last));
               end if;

               if not Done then
                  for I in Attrs'Range loop
                     if Ada.Strings.Unbounded.To_String (Base)
                          = Attrs (I).Name.all
                     then
                        Have_Attr (I) := True;
                        Neg_Attr (I) := Neg;
                        Done := True;
                        exit;
                     end if;
                  end loop;
               end if;

               if not Done then
                  Take_Slot (Word);
               end if;
            end;
            First := Last;
         end;
      end loop;

      --  Emit: attributes in table order, then foreground, then background.
      for I in Attrs'Range loop
         if Have_Attr (I) then
            declare
               function Img (N : Natural) return String is
                 (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));
            begin
               Add (Img (if Neg_Attr (I) then Attrs (I).Neg else Attrs (I).Code));
            end;
         end if;
      end loop;
      Emit_Slot (Fg, To_String (Fg_Rgb), 30, 90, 38);
      Emit_Slot (Bg, To_String (Bg_Rgb), 40, 100, 48);

      if Length (Out_Codes) = 0 and then not Saw_Reset then
         return "";
      end if;
      return ASCII.ESC & "[" & To_String (Out_Codes) & "m";
   end To_Ansi;

end Version.Color;
