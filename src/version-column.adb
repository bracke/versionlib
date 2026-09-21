with Ada.Environment_Variables;

package body Version.Column is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   --  git's parse_option: one word of a column option list. Layout and
   --  enable words replace their group; `dense`/`nodense` toggle.
   procedure Parse_Word
     (Word       : String;
      Into       : in out Options;
      Enable_Set : in out Boolean;
      Layout_Set : in out Boolean;
      OK         : out Boolean) is
   begin
      OK := True;
      if Word = "always" then
         Into.Enable := Enabled;
         Enable_Set := True;
      elsif Word = "never" then
         Into.Enable := Disabled;
         Enable_Set := True;
      elsif Word = "auto" then
         Into.Enable := Auto;
         Enable_Set := True;
      elsif Word = "plain" then
         Into.Layout := Plain_Layout;
         Layout_Set := True;
      elsif Word = "column" then
         Into.Layout := Column_Layout;
         Layout_Set := True;
      elsif Word = "row" then
         Into.Layout := Row_Layout;
         Layout_Set := True;
      elsif Word = "dense" then
         Into.Dense := True;
      elsif Word = "nodense" then
         Into.Dense := False;
      else
         OK := False;
      end if;
   end Parse_Word;

   procedure Parse
     (Text     : String;
      Into     : in out Options;
      Bad_Word : out Ada.Strings.Unbounded.Unbounded_String)
   is
      Enable_Set : Boolean := False;
      Layout_Set : Boolean := False;
      First      : Natural := 0;
      OK         : Boolean;

      procedure Take (Word : String) is
      begin
         if Length (Bad_Word) > 0 then
            return;
         end if;
         Parse_Word (Word, Into, Enable_Set, Layout_Set, OK);
         if not OK then
            Bad_Word := To_Unbounded_String (Word);
         end if;
      end Take;
   begin
      Bad_Word := Null_Unbounded_String;
      for K in Text'Range loop
         if Text (K) = ',' or else Text (K) = ' ' then
            if First > 0 then
               Take (Text (First .. K - 1));
               First := 0;
            end if;
         elsif First = 0 then
            First := K;
         end if;
      end loop;
      if First > 0 then
         Take (Text (First .. Text'Last));
      end if;
      --  A layout without an enable word means "always".
      if Length (Bad_Word) = 0 and then Layout_Set and then not Enable_Set then
         Into.Enable := Enabled;
      end if;
   end Parse;

   procedure Apply_Command_Line
     (Into     : in out Options;
      Argument : String;
      Negated  : Boolean;
      Bad_Word : out Ada.Strings.Unbounded.Unbounded_String) is
   begin
      Bad_Word := Null_Unbounded_String;
      Into.From_Command_Line := True;
      Into.Enable := Disabled;
      if Negated then
         return;
      end if;
      Into.Enable := Enabled;
      if Argument'Length > 0 then
         Parse (Argument, Into, Bad_Word);
      end if;
   end Apply_Command_Line;

   procedure Finalize (Into : in out Options; Stdout_Is_Tty : Boolean) is
   begin
      if Into.Enable = Auto then
         Into.Enable := (if Stdout_Is_Tty then Enabled else Disabled);
      end if;
   end Finalize;

   function Active (Opts : Options) return Boolean is (Opts.Enable = Enabled);

   function Term_Columns return Positive is
      Text : constant String :=
        (if Ada.Environment_Variables.Exists ("COLUMNS")
         then Ada.Environment_Variables.Value ("COLUMNS") else "");
   begin
      if Text'Length > 0 then
         declare
            N : constant Integer := Integer'Value (Text);
         begin
            if N > 0 then
               return N;
            end if;
         end;
      end if;
      return 80;
   exception
      when Constraint_Error =>
         return 80;
   end Term_Columns;

   --  git's item_length: the display width -- UTF-8 continuation bytes do
   --  not count (a fair stand-in for utf8_strnwidth on ref names).
   function Item_Length (S : String) return Natural is
      N : Natural := 0;
   begin
      for C of S loop
         if Character'Pos (C) not in 16#80# .. 16#BF# then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Item_Length;

   function Render
     (Items   : Version.Ref_Format.String_Vectors.Vector;
      Opts    : Options;
      Width   : Natural := 0;
      Padding : Natural := 1;
      Indent  : String := "")
      return String
   is
      Result : Unbounded_String;
      N      : constant Natural := Natural (Items.Length);
      Total_Width : constant Natural :=
        (if Width > 0 then Width else Term_Columns - 1);
   begin
      if N = 0 then
         return "";
      end if;

      if not Active (Opts) or else Opts.Layout = Plain_Layout then
         for Item of Items loop
            Append (Result, (if Active (Opts) then Indent else "") & Item & LF);
         end loop;
         return To_String (Result);
      end if;

      declare
         Len   : array (0 .. N - 1) of Natural;
         Rows  : Positive;
         Cols  : Positive;
         Initial_Width : Natural := 0;
         --  Per column, the index of its widest cell (git's data->width).
         Widest : array (0 .. N - 1) of Natural := [others => 0];

         --  git's XY2LINEAR.
         function Linear (X, Y : Natural) return Natural is
           (if Opts.Layout = Column_Layout then X * Rows + Y else Y * Cols + X);

         procedure Compute_Column_Width is
         begin
            for X in 0 .. Cols - 1 loop
               Widest (X) := Linear (X, 0);
               for Y in 0 .. Rows - 1 loop
                  declare
                     I : constant Natural := Linear (X, Y);
                  begin
                     if I < N and then Len (Widest (X)) < Len (I) then
                        Widest (X) := I;
                     end if;
                  end;
               end loop;
            end loop;
         end Compute_Column_Width;
      begin
         for I in 0 .. N - 1 loop
            Len (I) := Item_Length (Items (I + 1));
            Initial_Width := Natural'Max (Initial_Width, Len (I));
         end loop;

         --  git's layout: equal cells of the widest item plus padding.
         Initial_Width := Initial_Width + Padding;
         --  (More columns than items lays out exactly like one row of N.)
         Cols := Natural'Min
           (N, Natural'Max (1, (Total_Width - Indent'Length) / Initial_Width));
         Rows := (N + Cols - 1) / Cols;

         if Opts.Dense then
            --  git's shrink_columns: take rows away (adding columns) while
            --  the real column widths still fit.
            while Rows > 1 loop
               declare
                  Old_Rows : constant Positive := Rows;
                  Old_Cols : constant Positive := Cols;
                  Total    : Natural := Indent'Length;
               begin
                  Rows := Rows - 1;
                  Cols := (N + Rows - 1) / Rows;
                  Compute_Column_Width;
                  for X in 0 .. Cols - 1 loop
                     Total := Total + Len (Widest (X)) + Padding;
                  end loop;
                  if Total > Total_Width then
                     Rows := Old_Rows;
                     Cols := Old_Cols;
                     exit;
                  end if;
               end;
            end loop;
         end if;
         Compute_Column_Width;

         for Y in 0 .. Rows - 1 loop
            for X in 0 .. Cols - 1 loop
               declare
                  I : constant Natural := Linear (X, Y);
               begin
                  exit when I >= N;
                  declare
                     Cell_Len : Natural := Len (I);
                     Newline  : constant Boolean :=
                       (if Opts.Layout = Column_Layout
                        then I + Rows >= N
                        else X = Cols - 1 or else I = N - 1);
                  begin
                     --  A narrower real column fills less than the
                     --  initial cell width (dense layout).
                     if Opts.Dense and then Len (Widest (X)) < Initial_Width
                     then
                        Cell_Len := Cell_Len + Initial_Width - Len (Widest (X))
                          - Padding;
                     end if;
                     if X = 0 then
                        Append (Result, Indent);
                     end if;
                     Append (Result, Items (I + 1));
                     if Newline then
                        Append (Result, LF);
                     elsif Cell_Len < Initial_Width then
                        Append (Result, String'(1 .. Initial_Width - Cell_Len => ' '));
                     end if;
                  end;
               end;
            end loop;
         end loop;
      end;
      return To_String (Result);
   end Render;

end Version.Column;
