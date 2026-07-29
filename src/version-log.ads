with Version.History;
with Version.Objects;
with Version.Pathspec;
with Version.Repository;

package Version.Log is

   --  git's named `--pretty=`/`--format=` header layouts. Pretty_Oneline is
   --  rendered by the dedicated oneline path; the others share Log_List_Text.
   --  Short shows only the subject; Full/Fuller add the committer identity
   --  (and, for Fuller, both dates); Raw prints the commit object's own
   --  headers verbatim.
   type Pretty_Kind is
     (Pretty_Short, Pretty_Medium, Pretty_Full, Pretty_Fuller, Pretty_Raw);

   function Format_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Full_Message : Boolean := False)
      return String;

   function Log_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Context        : Natural := 3;
      Oneline        : Boolean := False;
      First_Parent   : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Paths          : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Date_Mode      : String := "") return String;
   --  Paths, when non-empty, limits each commit's --stat/-p/--raw diff to the
   --  matching files, as git's `log -p -- <path>` does (the walk is already
   --  path-limited by rev-list; this restricts the shown diff too).
   --  First_Parent (git's `--first-parent`) makes a merge commit's diff run
   --  against its first parent, so its --stat/--name-only/-p is shown rather
   --  than suppressed the way a merge otherwise is.
   --  Date_Mode is `--date=<mode>` for the "Date:" header (iso/short/raw/...).
   --  Oneline replaces each commit's header with git's oneline form and runs
   --  the file changes straight after it (no separating blank), as
   --  `log --oneline --name-only`/`--numstat`/`--raw`/... do.

   type Decorate_Mode is (No_Decorate, Short_Decorate, Full_Decorate);

   function Log_Oneline_List_Text
     (Repo          : Version.Repository.Repository_Handle;
      Commits       : Version.History.Commit_Id_Vectors.Vector;
      With_Parents  : Boolean := False;
      With_Children : Boolean := False;
      With_Boundary : Boolean := False;
      Decorate      : Decorate_Mode := No_Decorate) return String;
   --  With_Boundary adds git's `--boundary`: after the shown commits, the
   --  excluded commits that are a parent of a shown one (the traversal's
   --  uninteresting frontier of a range), each prefixed "- ", newest first.
   --  With_Parents adds git's `--parents`: the abbreviated parent ids after
   --  each commit id. With_Children adds git's `--children`: the abbreviated
   --  ids of the shown commits that name this one as a parent, in git's order
   --  (each child prepended as the display-order walk reaches it). Decorate adds git's `--decorate` ref names in parens
   --  (Short_Decorate: "main"/"tag: v2"; Full_Decorate: the full refnames),
   --  with the current branch shown as "HEAD -> <branch>".

   function Log_Graph_Oneline_List_Text
     (Repo          : Version.Repository.Repository_Handle;
      Commits       : Version.History.Commit_Id_Vectors.Vector;
      With_Parents  : Boolean := False;
      With_Children : Boolean := False;
      Decorate      : Decorate_Mode := No_Decorate) return String;
   --  git's `log --graph --oneline`: the oneline listing of Commits with an
   --  ASCII commit-graph drawn to its left (Version.Log_Graph). Each commit
   --  keeps its Log_Oneline_List_Text content; the graph prefix and connector
   --  lines (`|\`, `|/`) are interleaved around it. A parent counts as an edge
   --  only when it is itself in Commits (git's "interesting parent").

   function Log_Graph_List_Text
     (Repo           : Version.Repository.Repository_Handle;
      Commits        : Version.History.Commit_Id_Vectors.Vector;
      Show_Signature : Boolean := False;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Context        : Natural := 3;
      First_Parent   : Boolean := False;
      Kind           : Pretty_Kind := Pretty_Medium;
      Show_Notes     : Boolean := True;
      Paths          : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Date_Mode      : String := "") return String;
   --  git's `log --graph` in the default (multi-line) format: each commit's
   --  full Log_List_Text block with the ASCII commit graph drawn down its left
   --  edge -- the commit line, then a graph column line prefixing every
   --  following line (header, message, and any --stat/-p output), the
   --  connector rows for merges, and git's graph-prefixed blank line between
   --  commits.

   function Log_Formatted_List_Text
     (Repo    : Version.Repository.Repository_Handle;
      Commits : Version.History.Commit_Id_Vectors.Vector;
      Format  : String;
      Terminate_Records : Boolean := True;
      Date_Mode : String := "") return String;
   --  Render an already-selected list of commits. The caller does the
   --  revision walk, so ranges, exclusions, path limits and ordering are
   --  decided once and shared with rev-list rather than re-derived here.

   function Log_From_Commit
     (Repo           : Version.Repository.Repository_Handle;
      Commit_Id      : Version.Objects.Hex_Object_Id;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3)
      return String;
   --  Patch appends git's `-p`/`--patch` diff (against the first parent, or the
   --  empty tree for a root commit) after each commit; Context is its `-U<n>`.
   --  Stat appends git's `--stat` diffstat (against the first parent, or the
   --  empty tree for a root commit) after each commit.
   --  Show_Signature interleaves gpg's verification lines (as
   --  `log --show-signature`) after each commit header for signed commits.
   --  Max_Count limits the number of commits shown (git's -<n>/-n <count>);
   --  0 means unlimited.

   function Log_Oneline_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Max_Count : Natural := 0)
      return String;

   function Log_Head
     (Repo           : Version.Repository.Repository_Handle;
      Show_Signature : Boolean := False;
      Max_Count      : Natural := 0;
      Stat           : Boolean := False;
      Patch          : Boolean := False;
      Context        : Natural := 3)
      return String;

   function Log_Oneline_Head
     (Repo      : Version.Repository.Repository_Handle;
      Max_Count : Natural := 0)
      return String;

   function Log_Formatted_From_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Format    : String;
      Terminate_Records : Boolean := True;
      Max_Count : Natural := 0;
      Date_Mode : String := "")
      return String;
   --  Walk first-parent history from Commit_Id, expanding each commit through
   --  Version.Pretty_Format with Format. Terminate_Records = True appends a
   --  newline after every record (git's `--format`/`tformat:`); False joins
   --  records with a single newline and omits the trailing one (git's
   --  `--pretty=format:`).

end Version.Log;
