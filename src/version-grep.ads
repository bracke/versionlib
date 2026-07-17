with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

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

   --  Backward-compatible convenience: a simple case-toggled basic search.
   function Search
     (Repo        : Version.Repository.Repository_Handle;
      Pattern     : String;
      Ignore_Case : Boolean)
      return Match_Vectors.Vector;

end Version.Grep;
