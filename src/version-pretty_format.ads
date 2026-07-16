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
   function Expand
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String)
      return String;

end Version.Pretty_Format;
