with Version.Repository;

package Version.Text_Filter is
   --  Line-ending normalization for check-in and checkout, driven by
   --  `.gitattributes` (text / -text / text=auto / eol=lf|crlf, and the old
   --  crlf synonyms) layered over `core.autocrlf` (true / input / false) and
   --  `core.eol`. Mirrors the LFS clean/smudge wrappers so the staging and
   --  checkout paths can compose both. Binary content (NUL in the first 8000
   --  bytes, git's heuristic) is never converted unless an explicit text
   --  attribute forces it.

   function Is_Active
     (Repo : Version.Repository.Repository_Handle)
      return Boolean;
   --  True when any line-ending normalization could apply in this repo
   --  (core.autocrlf set, core.eol=crlf, or a .gitattributes / info/attributes
   --  file present). Lets hot scan loops skip the per-file filter entirely when
   --  nothing is configured (the common case), preserving byte-for-byte hashing.

   function Clean_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;
   --  Check-in (add): collapse CRLF to LF when the path is treated as text.

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;
   --  Checkout: expand LF to CRLF when the path's effective checkout EOL is
   --  CRLF (eol=crlf, core.autocrlf=true, or a text file with core.eol=crlf).

end Version.Text_Filter;
