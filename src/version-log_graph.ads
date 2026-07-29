with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;

--  An ASCII commit-graph renderer for `log --graph`, ported from git's
--  graph.c lane state machine. It tracks a set of "columns" (branch lines)
--  and, per shown commit, emits the graph prefix that precedes the commit's
--  content plus any purely-graphical connector lines (`|\`, `|/`, `_`) around
--  it. Colour and the `--graph-max-lanes` truncation of upstream git are not
--  modelled: neither affects the default `--graph` output this drives.
--
--  The caller walks the already-selected commit list (the same list `log`
--  shows), and for each commit passes its *interesting* parents -- those that
--  will themselves be shown -- in order. That mirrors git's
--  graph_is_interesting()/first_interesting_parent() filtering, which for a
--  plain walk is exactly "the parent is one of the shown commits".
package Version.Log_Graph is

   package Line_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type   => Positive,
      Element_Type => String);

   type Graph is private;

   procedure Init (G : out Graph);

   type Step is record
      --  Whole graph-only lines to print above the commit's own line (git's
      --  pre-commit expansion rows for octopus merges; empty for the common
      --  case).
      Pre_Lines : Line_Vectors.Vector;
      --  The graph prefix for the commit's line, already padded to the graph
      --  width; the caller appends the commit content (abbrev id, subject,
      --  ...) immediately after it.
      Commit_Prefix : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Advance
     (G       : in out Graph;
      Commit  : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector) return Step;
   --  Advance the graph to Commit (with the given interesting Parents, in
   --  order) and return the lines around its commit line. Equivalent to
   --  Update followed by Begin_Commit; used by the single-line renderer.

   function Remainder (G : in out Graph) return Line_Vectors.Vector;
   --  The graph-only connector lines that follow the commit's content line
   --  (post-merge `|\` and collapsing `|/`/`_` rows), in order. Empty when the
   --  commit needs no trailing graph output.

   --  Lower-level primitives mirroring git's show_log, for the multi-line
   --  (full-format) renderer where each commit spans several content lines.

   procedure Update
     (G       : in out Graph;
      Commit  : Version.Objects.Hex_Object_Id;
      Parents : Version.Objects.Object_Id_Vectors.Vector);
   --  git's graph_update: fold the previous commit's parents into the columns
   --  and set up this commit's state. Call before Separator_Line/Begin_Commit.

   function Separator_Line (G : in out Graph) return String;
   --  The graph prefix for the blank line git prints between two commits
   --  (git's graph_padding_line): the columns entering this commit drawn as
   --  `| `, padded to the graph width. Call after Update, before Begin_Commit.

   function Begin_Commit (G : in out Graph) return Step;
   --  git's graph_show_commit: the pre-commit expansion lines (if any) and the
   --  commit-line prefix, assuming Update has already run.

   function Next_Line (G : in out Graph) return String;
   --  One graph line (git's graph_show_oneline): the prefix for the next
   --  content line of the current commit, advancing the lane state.

   function Is_Finished (G : Graph) return Boolean;
   --  True once the current commit has no further graph output (git's
   --  graph_is_commit_finished) -- i.e. the lanes have settled.

private

   Max_Columns : constant := 512;

   type Id_Array is
     array (Natural range 0 .. Max_Columns - 1) of Version.Objects.Hex_Object_Id;
   type Int_Array is
     array (Natural range 0 .. 2 * Max_Columns - 1) of Integer;

   type State_Kind is
     (S_Padding, S_Skip, S_Pre_Commit, S_Commit, S_Post_Merge, S_Collapsing);

   type Graph is record
      Commit            : Version.Objects.Hex_Object_Id;
      Have_Commit       : Boolean := False;
      Parents           : Version.Objects.Object_Id_Vectors.Vector;
      Num_Parents       : Integer := 0;
      Width             : Integer := 0;
      Expansion_Row     : Integer := 0;
      State             : State_Kind := S_Padding;
      Prev_State        : State_Kind := S_Padding;
      Commit_Index      : Integer := 0;
      Prev_Commit_Index : Integer := 0;
      Merge_Layout      : Integer := 0;
      Edges_Added       : Integer := 0;
      Prev_Edges_Added  : Integer := 0;
      Num_Columns       : Integer := 0;
      Num_New_Columns   : Integer := 0;
      Mapping_Size      : Integer := 0;
      Columns           : Id_Array;
      New_Columns       : Id_Array;
      Mapping           : Int_Array := [others => -1];
      Old_Mapping       : Int_Array := [others => -1];
   end record;

end Version.Log_Graph;
