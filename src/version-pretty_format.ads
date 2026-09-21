with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Pretty_Format is

   --  Expand git pretty-format placeholders in Format for the given commit,
   --  matching `git log --pretty=format:<Format>` and the `export-subst`
   --  `$Format:...$` machinery byte-for-byte.
   --
   --  Implemented in tiers; the currently supported placeholders are the
   --  commit-object-derived ones: %H/%h %T/%t %P/%p, author/committer identity
   --  (%an/%aN %ae/%aE %al/%aL and the %c* equivalents), the absolute date
   --  formats (%ad %aD %ai %aI %as %at, %c*), %s %f %b %B %e %n %% %x??.
   --  Unknown/not-yet-supported placeholders are emitted literally, exactly as
   --  git leaves an unrecognized "%x" sequence.
   --  The reflog entry a `log -g` record stands for, feeding %gd/%gD/%gs
   --  and the %gn/%gN/%ge/%gE identity; empty outside a reflog walk.
   type Reflog_Info is record
      Selector : Ada.Strings.Unbounded.Unbounded_String;
      Ident    : Ada.Strings.Unbounded.Unbounded_String;   --  "Name <mail>"
      Message  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Expand
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String;
      Date_Mode : String := "";
      Reflog    : Reflog_Info := (others => <>))
      return String;
   --  Date_Mode is git's --date=<mode>: it changes what the plain %ad/%cd
   --  atoms render ("iso"/"iso8601", "iso-strict", "short", "raw", "unix",
   --  "relative", "human"); "" keeps git's default date. The explicit date
   --  atoms (%ai/%as/%at/...) are unaffected.

   --  The trailers of a commit message (git's trailer block rules: the
   --  last paragraph, "Key: value" lines with continuations), in order.
   --  What %(trailers) renders; shortlog groups by them too.
   type Trailer is record
      Key   : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;   --  embedded LF: continuations
   end record;
   package Trailer_Vectors is new Ada.Containers.Vectors (Positive, Trailer);
   function Parse_Trailers (Message : String) return Trailer_Vectors.Vector;

   --  The "<epoch> <tz>" tail of an ident line rendered under git's
   --  --date=<mode> ("" is the default layout; also "relative", "human",
   --  "format:<strftime>", and any mode with a "-local" suffix).
   function Format_Date (Ident_Tail : String; Mode : String) return String;

end Version.Pretty_Format;
