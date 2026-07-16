--  Whitespace/comment cleanup of a message, matching `git stripspace`.
package Version.Stripspace is

   type Mode is (Default, Strip_Comments, Comment_Lines);

   --  Default: strip trailing whitespace from every line, collapse runs of
   --  blank lines to a single blank, drop leading/trailing blank lines, and
   --  newline-terminate a non-empty result.
   --  Strip_Comments: as Default, and additionally drop lines whose first
   --  character is Comment_Char.
   --  Comment_Lines: prefix every input line with Comment_Char (a "# " prefix,
   --  or a bare Comment_Char for an empty line); no stripping or collapsing.
   function Clean
     (Input        : String;
      Kind         : Mode      := Default;
      Comment_Char : Character := '#')
      return String;

end Version.Stripspace;
