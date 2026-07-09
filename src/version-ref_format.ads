with Ada.Containers.Indefinite_Vectors;
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
     (Repo     : Version.Repository.Repository_Handle;
      Patterns : String_Vectors.Vector;
      Format   : String := "";
      Sort_Key : String := "";
      Count    : Natural := 0)
      return String_Vectors.Vector;
   --  One element per emitted ref line (no trailing newline). Patterns empty
   --  means "all refs". Sort_Key empty means ascending refname. Count 0 means
   --  unlimited. Raises Constraint_Error on an unknown %(atom) or --sort key,
   --  matching git's fatal diagnostics semantics at the CLI boundary.

   function Git_Date
     (Ident_Value : String;
      Modifier    : String := "")
      return String;
   --  Format the "<unixtime> <tz>" tail of an author/committer/tagger ident
   --  line the way git's date atoms do. Modifier is the part after the colon
   --  in e.g. %(authordate:iso): "" (default), "iso"/"iso8601", "iso-strict",
   --  "short", "raw", "unix". Exposed for reuse and unit testing.

end Version.Ref_Format;
