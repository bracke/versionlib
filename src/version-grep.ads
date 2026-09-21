with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Regexp;

with Version.Objects;
with Version.Pathspec;
with Version.Repository;

--  `git grep`: search tracked files for a pattern. Supports fixed-string
--  (-F), basic (default), extended (-E) and perl-style (-P) regular
--  expressions, case-insensitive (-i), whole-word (-w) and inverted (-v)
--  matching, and pathspec filtering, over the working-tree content of
--  tracked files.
package Version.Grep is

   type Match is record
      Path    : Ada.Strings.Unbounded.Unbounded_String;
      Line_No : Positive;
      Text    : Ada.Strings.Unbounded.Unbounded_String;
      --  True when the matched file is binary (a NUL byte in its first 8000
      --  bytes). git suppresses the line text for such a file in its default
      --  output, printing "Binary file <path> matches" once, but still counts
      --  and lists it (-c/-l) using the individual line matches.
      Binary  : Boolean := False;
   end record;

   package Match_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Match);

   type Pattern_Kind is
     (Basic_Regex, Extended_Regex, Fixed_String, Perl_Regex);

   type Options is record
      Kind        : Pattern_Kind := Basic_Regex;   --  -G (default) / -E / -F / -P
      Ignore_Case : Boolean := False;              --  -i
      Word_Match  : Boolean := False;              --  -w
      Invert      : Boolean := False;              --  -v
   end record;

   --  A pattern compiled once and applied to many lines. `log --author=` and
   --  `--grep=` filter every commit in a walk, so compiling per line would
   --  redo the work for each; more importantly these are regular expressions
   --  in git, and matching them by substring would answer plausibly but
   --  wrongly the moment a pattern carried a metacharacter.
   type Line_Matcher is private;

   function Compile
     (Pattern : String;
      Opts    : Options := (others => <>))
      return Line_Matcher;
   --  Raises Ada.IO_Exceptions.Data_Error on a pattern the engine rejects.

   function Matches (M : Line_Matcher; Text : String) return Boolean;

   ------------------------------------------------------------------------
   --  git's grep.c: the pattern expression (-e, --and, --or, --not, ( )),
   --  matching with context, function context, counts, names, colours
   --  and NUL separators, over one source buffer at a time.
   ------------------------------------------------------------------------

   --  A --and/--or/--not/( ) expression token, or a pattern.
   type Pattern_Token is
     (Tok_Pattern, Tok_And, Tok_Open_Paren, Tok_Close_Paren, Tok_Not);

   type Pattern_Item is record
      Token   : Pattern_Token := Tok_Pattern;
      Pattern : Ada.Strings.Unbounded.Unbounded_String;
      --  Where it came from, for git's compile failure text: "-e option",
      --  "command line", or a -f file with its line number.
      Origin  : Ada.Strings.Unbounded.Unbounded_String;
      Line    : Natural := 0;
   end record;

   package Item_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Pattern_Item);

   type Binary_Mode is (Binary_Default, Binary_No_Match, Binary_Text);

   type Color_Slot is
     (Color_Context, Color_Filename, Color_Function, Color_Lineno,
      Color_Columnno, Color_Match_Context, Color_Match_Selected,
      Color_Selected, Color_Sep);
   type Color_Table is array (Color_Slot) of
     Ada.Strings.Unbounded.Unbounded_String;

   --  git's struct grep_opt.
   type Grep_Options is record
      Items          : Item_Vectors.Vector;
      Kind           : Pattern_Kind := Basic_Regex;
      Ignore_Case    : Boolean := False;   --  -i
      Word_Regexp    : Boolean := False;   --  -w
      Invert         : Boolean := False;   --  -v
      All_Match      : Boolean := False;   --  --all-match
      Line_Number    : Boolean := False;   --  -n
      Column         : Boolean := False;   --  --column
      Pathname       : Boolean := True;    --  -H / -h
      Name_Only      : Boolean := False;   --  -l
      Unmatch_Name_Only : Boolean := False;   --  -L
      Count          : Boolean := False;   --  -c
      Status_Only    : Boolean := False;   --  -q
      Only_Matching  : Boolean := False;   --  -o
      Null_Following : Boolean := False;   --  -z
      Binary         : Binary_Mode := Binary_Default;   --  -a / -I
      Pre_Context    : Natural := 0;       --  -B
      Post_Context   : Natural := 0;       --  -A
      Funcname       : Boolean := False;   --  -p
      Funcbody       : Boolean := False;   --  -W
      File_Break     : Boolean := False;   --  --break
      Heading        : Boolean := False;   --  --heading
      Max_Count      : Integer := -1;      --  -m
      Color          : Boolean := False;   --  colours on
      Colors         : Color_Table;
   end record;

   --  The default colour table (color.grep.* defaults).
   function Default_Colors return Color_Table;

   --  The compiled expression and the state git carries between files
   --  (last_shown, show_hunk_mark).
   type Grep_State is private;

   --  compile_grep_patterns: raises Ada.IO_Exceptions.Data_Error with
   --  git's fatal text ("unmatched ( for expression group", ...).
   function Prepare (Opts : Grep_Options) return Grep_State;

   --  grep_source over one buffer: appends what git would print for it to
   --  Output and returns whether it hit.  Name is the displayed name (with
   --  any "rev:" prefix and quoting applied by the caller); Is_Binary is
   --  the caller's binary verdict for Binary_Default/Binary_No_Match.
   function Grep_Buffer
     (State     : in out Grep_State;
      Opts      : Grep_Options;
      Name      : String;
      Content   : String;
      Is_Binary : Boolean;
      Output    : in out Ada.Strings.Unbounded.Unbounded_String)
      return Boolean;

   --  git's buffer_is_binary: a NUL within the first 8000 bytes.
   function Looks_Binary (Content : String) return Boolean;

   function Search
     (Repo      : Version.Repository.Repository_Handle;
      Pattern   : String;
      Opts      : Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Match_Vectors.Vector;
   --  Search the working-tree content of tracked files (stage 0), optionally
   --  limited to Pathspecs. Raises Ada.IO_Exceptions.Data_Error when Pattern
   --  is not a valid regular expression.

   function Search_Tree
     (Repo      : Version.Repository.Repository_Handle;
      Tree_Id   : Version.Objects.Hex_Object_Id;
      Pattern   : String;
      Opts      : Options := (others => <>);
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return Match_Vectors.Vector;
   --  Like Search, but over the blobs of a committed tree (git's
   --  `grep <tree-ish>`) rather than the working tree: every file in Tree_Id
   --  is read from the object store, optionally limited to Pathspecs. Paths are
   --  the tree-relative paths. Raises Ada.IO_Exceptions.Data_Error when Pattern
   --  is not a valid regular expression.

   --  Backward-compatible convenience: a simple case-toggled basic search.
   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean)
      return Match_Vectors.Vector;

private

   type Line_Matcher is record
      Expr  : Regexp.Regexp;
      M_Opt : Regexp.Match_Options;
   end record;

   --  A compiled pattern (git's struct grep_pat).
   type Compiled_Pattern is record
      Token    : Pattern_Token := Tok_Pattern;
      Pattern  : Ada.Strings.Unbounded.Unbounded_String;
      Expr     : Regexp.Regexp;
      M_Opt    : Regexp.Match_Options;
      Empty    : Boolean := False;   --  the empty pattern matches anywhere
   end record;
   package Pattern_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Compiled_Pattern);

   --  The expression tree (git's struct grep_expr), nodes by index.
   type Node_Kind is (Node_Atom, Node_Not, Node_And, Node_True, Node_Or);
   type Expr_Node is record
      Kind  : Node_Kind := Node_True;
      Atom  : Natural := 0;   --  Compiled_Pattern index
      Left  : Natural := 0;
      Right : Natural := 0;
      Hit   : Boolean := False;
   end record;
   package Node_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Expr_Node);

   type Grep_State is record
      Patterns   : Pattern_Vectors.Vector;
      Nodes      : Node_Vectors.Vector;
      Root       : Natural := 0;   --  0: plain pattern list
      Last_Shown : Natural := 0;
      Show_Hunk_Mark : Boolean := False;
   end record;

end Version.Grep;
