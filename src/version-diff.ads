with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;
with Version.Pathspec;

package Version.Diff is

   --  Renames_Default consults the `diff.renames` configuration (git's
   --  default is on); the other two force the choice, as `-M`/`--no-renames`.
   type Rename_Detection is (Renames_Default, Renames_On, Renames_Off);

   --  git's --word-diff: WD_Plain marks changed words inline ([-old-]{+new+}),
   --  WD_Porcelain emits one line per word (space/-/+ prefixed) with `~` for a
   --  newline.
   type Word_Diff_Kind is (WD_None, WD_Plain, WD_Porcelain);

   type Diff_Options is record
      Context_Lines  : Natural := 3;
      Word_Diff      : Word_Diff_Kind := WD_None;
      Stat           : Boolean := False;
      Summary        : Boolean := False;
      Name_Only      : Boolean := False;
      Name_Status    : Boolean := False;
      Numstat        : Boolean := False;
      Shortstat      : Boolean := False;
      Raw            : Boolean := False;
      Abbrev         : Natural := 7;
      Compact_Summary : Boolean := False;
      Stat_Width      : Natural := 0;
      Diff_Filter     : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.Null_Unbounded_String;
      Detect_Renames : Rename_Detection := Renames_Default;
      Rename_Score   : Natural := 0;
      Rename_Limit   : Natural := 0;
      Binary_Patch   : Boolean := False;
      Diff_Text      : Boolean := False;
      --  git's --src-prefix/--dst-prefix/--no-prefix. Empty strings drop the
      --  "a/"/"b/" the headers otherwise carry.
      Src_Prefix     : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("a/");
      Dst_Prefix     : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("b/");
   end record;
   --  Name_Only lists just the changed paths; Name_Status prefixes each with
   --  git's status letter (A/D/M/R) and a tab. Both suppress the patch body.
   --  Stat renders git's `--stat` summary (per-file change bars plus a
   --  "N files changed, ..." footer) instead of the unified patch. Summary
   --  appends git's `--summary` lines (create/delete mode, mode change,
   --  rename). When either Stat or Summary is set the patch body is
   --  suppressed; both may be set together (as `git merge` reports).
   --
   --  Detect_Renames pairs deletions with creations and reports them as
   --  renames, which is git's default for diff/log/show (`diff.renames`).
   --  Rename_Score is the minimum similarity, in git's 0 .. 60000 scale
   --  (`-M<n>`); 0 takes git's default of 50%. Rename_Limit caps the
   --  detection matrix (`diff.renameLimit`); 0 takes git's default of 1000.
   --  Binary_Patch emits git's `GIT binary patch` block for a binary file
   --  (git's `--binary`, which `format-patch` implies) instead of the
   --  "Binary files ... differ" line, together with the full index line. The
   --  deflated payload is not byte-identical to git's -- a zlib stream is not
   --  canonical -- but decodes to the same bytes and applies with `git am`.

   function Diff_Working_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Working_Tree
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   function Diff_Staged
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Staged
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   function Diff_Cached
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Cached
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   --  Unified diff between an arbitrary tree and the working tree
   --  (git diff <commit>, git diff-index -p <tree>): the tree is the old
   --  side, the working tree the new side, restricted to tracked paths.
   function Diff_Tree_Vs_Working
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>))
      return String;

   --  Unified diff between an arbitrary tree and the index
   --  (git diff-index -p --cached <tree>).
   function Diff_Tree_Vs_Index
     (Repo    : Version.Repository.Repository_Handle;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : Version.Objects.Hex_Object_Id;
      New_Id    : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>))
      return String;

   function Diff_Trees
     (Repo     : Version.Repository.Repository_Handle;
      Old_Tree : Version.Objects.Hex_Object_Id;
      New_Tree : Version.Objects.Hex_Object_Id;
      Options  : Diff_Options := (others => <>))
      return String;
   --  The unified (or --stat/--name-*) diff between two trees directly, for
   --  `diff-tree -p|--stat <tree> <tree>`. Same rendering as Diff_Commits.

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Diff_Options := (others => <>))
      return String;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>))
      return String;

   --  Raw (`git diff-tree --raw`) diff between two trees: one line per changed
   --  path, ":<mode1> <mode2> <sha1> <sha2> <status>\t<path>", sorted by path,
   --  recursing into subtrees. When Has_Base is False the base is the empty
   --  tree (every path is an addition), for `diff-tree --root`.
   function Raw_Diff_Trees
     (Repo       : Version.Repository.Repository_Handle;
      Base       : Version.Objects.Hex_Object_Id;
      Has_Base   : Boolean;
      Target     : Version.Objects.Hex_Object_Id;
      Recursive  : Boolean := True;
      Show_Trees : Boolean := False)
      return String;
   --  Show_Trees (git's `-t`) also emits a line for each changed subdirectory
   --  (a `040000` entry whose tree object differs), in path order.

   --  git's `--dirstat`: the share of the change that each directory holds,
   --  printed as "  NN.N% <dir>/" for directories at or above Permille (git's
   --  default is 30 = 3%). By_File counts files, By_Line counts added/removed
   --  lines (binary in 64-byte chunks), and the default (neither set) uses
   --  git's content "damage" (diffcore_count_changes). Renames are detected
   --  first, as the porcelain does. Cumulative rolls a subtree's share up into
   --  its parents. A faithful port of show_dirstat/gather_dirstat in diff.c.
   function Dir_Stat
     (Repo       : Version.Repository.Repository_Handle;
      Old_Tree   : Version.Objects.Hex_Object_Id;
      Has_Base   : Boolean;
      New_Tree   : Version.Objects.Hex_Object_Id;
      By_File    : Boolean := False;
      By_Line    : Boolean := False;
      Permille   : Natural := 30;
      Cumulative : Boolean := False)
      return String;

   --  Raw diff of a tree against the index (`git diff-index --cached`, when
   --  Cached is True) or against the working tree (`git diff-index`, when
   --  False -- the second object id is all-zero, as git prints for a working
   --  file). Recurses through subtrees.
   function Raw_Diff_Index
     (Repo   : Version.Repository.Repository_Handle;
      Tree   : Version.Objects.Hex_Object_Id;
      Cached : Boolean)
      return String;

   --  Raw diff of the index against the working tree (`git diff-files`): the
   --  second object id is all-zero.
   function Raw_Diff_Files
     (Repo      : Version.Repository.Repository_Handle;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector)
      return String;
   --  Pathspecs, when non-empty, restricts the output to matching paths, as
   --  git's `diff-files -- <path>` does.

   --  One file's patch, exactly as `git diff` writes it: the `diff --git`
   --  and `index` headers, the mode lines, and the hunks.  A side that is not
   --  present is an add or a delete.  `diff-pairs` renders raw diff records
   --  through this.
   function Unified_Blob_Diff
     (Path        : String;
      Old_Text    : String;
      New_Text    : String;
      Old_Present : Boolean;
      New_Present : Boolean;
      Old_Id      : Version.Objects.Hex_Object_Id;
      New_Id      : Version.Objects.Hex_Object_Id;
      Old_Mode    : String;
      New_Mode    : String;
      Context     : Natural := 3)
      return String;

   --  git's `diff --no-index <old> <new>`: a full patch between two files that
   --  need not live in any repository. The header names the two paths
   --  separately (`a/<old> b/<new>`), and the blob ids on the `index` line are
   --  SHA-1 over the file content (git's default outside a repo). An absent
   --  side (a missing file) is rendered as an add/delete against /dev/null.
   function No_Index_Diff
     (Old_Path    : String;
      New_Path    : String;
      Old_Text    : String;
      New_Text    : String;
      Old_Present : Boolean := True;
      New_Present : Boolean := True;
      Context     : Natural := 3)
      return String;

   --  A plain unified diff of two texts: only `--- a/<path>`, `+++ b/<path>`
   --  and the hunks, with no `diff --git`/`index` header.  This is the shape
   --  `git rerere diff` prints.
   function Unified_Text_Diff
     (Path     : String;
      Old_Text : String;
      New_Text : String;
      Context  : Natural := 3) return String;

   type Patch_Summary_Mode is (Summary_Stat, Summary_Diffstat, Summary_Numstat,
                              Summary_Shortstat, Summary_Names);
   --  Summary_Stat is `git apply --stat` (dest-only renames, a wider count
   --  column, "Bin" for binaries); Summary_Diffstat is the plain `git diff
   --  --stat` diffstat (rename "{old => new}", the graph scaled to the input).

   function Summarize_Patch
     (Patch : String;
      Mode  : Patch_Summary_Mode) return String;
   --  Render what `git apply --stat|--numstat|--shortstat|--summary` prints
   --  for Patch without applying it: the per-file added/deleted line counts
   --  are read from the unified diff, and the mode/create/delete lines for
   --  Summary_Names from its "new file mode" / "deleted file mode" headers.
   --  Summary_Stat reuses the same bar rendering as a tree diff.

end Version.Diff;
