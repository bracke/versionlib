with Ada.Strings.Unbounded;

with Version.Ref_Format;

--  git's column.c: lay a list of strings out in columns, as `git column`
--  and the `--column` option of `tag`, `branch` and `status` do.
package Version.Column is

   type Layout_Kind is (Column_Layout, Row_Layout, Plain_Layout);
   --  COL_COLUMN fills columns before rows, COL_ROW rows before columns,
   --  COL_PLAIN prints one item per line.

   type Enable_Kind is (Disabled, Enabled, Auto);

   --  git's colopts word.
   type Options is record
      Enable     : Enable_Kind := Disabled;
      Layout     : Layout_Kind := Column_Layout;
      Dense      : Boolean := False;   --  shrink columns to fit more
      From_Command_Line : Boolean := False;   --  COL_PARSEOPT
   end record;

   procedure Parse
     (Text     : String;
      Into     : in out Options;
      Bad_Word : out Ada.Strings.Unbounded.Unbounded_String);
   --  git's parse_config: a comma/space-separated list of `always`,
   --  `never`, `auto`, `column`, `row`, `plain`, `dense`, `nodense`. A
   --  layout word without an enable word implies `always`. An unknown word
   --  stops the parse and comes back in Bad_Word (git: "unsupported option
   --  '<word>'"); Bad_Word is empty on success.

   procedure Apply_Command_Line
     (Into     : in out Options;
      Argument : String;
      Negated  : Boolean;
      Bad_Word : out Ada.Strings.Unbounded.Unbounded_String);
   --  git's parseopt_column_callback: `--no-column` is never; `--column`
   --  is always unless Argument says otherwise.

   procedure Finalize (Into : in out Options; Stdout_Is_Tty : Boolean);
   --  git's finalize_colopts: `auto` becomes always on a terminal, never
   --  otherwise.

   function Active (Opts : Options) return Boolean;
   --  Enabled -- what git's column_active reports.

   function Term_Columns return Positive;
   --  git's term_columns: $COLUMNS when positive, else 80.

   function Render
     (Items   : Version.Ref_Format.String_Vectors.Vector;
      Opts    : Options;
      Width   : Natural := 0;
      Padding : Natural := 1;
      Indent  : String := "")
      return String;
   --  git's print_columns: the table (or, when not Active or plain, one
   --  item per line) as one string, every row newline-terminated. Width 0
   --  means Term_Columns - 1.

end Version.Column;
