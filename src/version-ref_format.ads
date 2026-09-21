with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;
with Version.Repository;

package Version.Ref_Format is
   --  Implements the data model behind `for-each-ref`: enumerate refs,
   --  optionally filter by shell-glob patterns, expand a `--format` template
   --  of %(field) atoms, sort by a `--sort` key, and cap the count. The
   --  default template (empty Format) reproduces git's
   --  "<objectname> <objecttype>\t<refname>" line, byte for byte.

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   function For_Each_Ref
     (Repo        : Version.Repository.Repository_Handle;
      Patterns    : String_Vectors.Vector;
      Format      : String := "";
      Sort_Key    : String := "";
      Count       : Natural := 0;
      Ignore_Case : Boolean := False;
      Quote       : String := "")
      return String_Vectors.Vector;
   --  Quote names git's host-language quoting of each atom's value: "shell"
   --  and "perl"/"python" single-quote it, "tcl" double-quotes it, each with
   --  that language's escaping; "" (default) leaves values unquoted.
   --  One element per emitted ref line (no trailing newline). Patterns empty
   --  means "all refs". Sort_Key empty means ascending refname. Count 0 means
   --  unlimited. Raises Constraint_Error on an unknown %(atom) or --sort key,
   --  matching git's fatal diagnostics semantics at the CLI boundary.

   --  git's struct ref_filter: the selection `tag -l`, `branch -l` and
   --  `for-each-ref` share beyond the name patterns. The commit lists hold
   --  full hex ids; a ref that does not peel to a commit never passes a
   --  commit filter, as in git.
   type Ref_Filter is record
      With_Commits     : String_Vectors.Vector;   --  --contains: any of
      No_Commits       : String_Vectors.Vector;   --  --no-contains: none of
      Reachable_From   : String_Vectors.Vector;   --  --merged: into any of
      Unreachable_From : String_Vectors.Vector;   --  --no-merged: into none
      Points_At        : String_Vectors.Vector;   --  the ref or its peel
      Ignore_Case      : Boolean := False;        --  patterns and sorting
      Match_As_Path    : Boolean := True;
      --  True: for-each-ref's rule (a literal pattern is a prefix at a
      --  '/' boundary, a glob is path-aware). False: git's match_pattern for
      --  `tag`/`branch` -- wildmatch of the whole pattern against the name
      --  with its refs/tags/, refs/heads/, refs/remotes/ or refs/ prefix
      --  dropped, `*` crossing '/'.
      Omit_Empty       : Boolean := False;        --  drop empty lines
      Use_Color        : Boolean := False;        --  expand %(color:...)
      Under            : Ada.Strings.Unbounded.Unbounded_String;
      --  Only refs with this prefix take part ("refs/tags/" for `tag`);
      --  empty means every ref.
   end record;

   function For_Each_Ref
     (Repo      : Version.Repository.Repository_Handle;
      Patterns  : String_Vectors.Vector;
      Format    : String;
      Sort_Keys : String_Vectors.Vector;
      Filter    : Ref_Filter;
      Count     : Natural := 0;
      Quote     : String := "")
      return String_Vectors.Vector;
   --  As above, with git's full selection and several sort keys: the LAST
   --  key given is the primary one (git prepends each --sort), a leading '-'
   --  reverses a key, refname breaks the final tie. Empty Sort_Keys means
   --  ascending refname.

   function Git_Date
     (Ident_Value : String;
      Modifier    : String := "")
      return String;
   --  Format the "<unixtime> <tz>" tail of an author/committer/tagger ident
   --  line the way git's date atoms do. Modifier is the part after the colon
   --  in e.g. %(authordate:iso): "" (default), "iso"/"iso8601", "iso-strict",
   --  "short", "raw", "unix". Exposed for reuse and unit testing.

end Version.Ref_Format;
