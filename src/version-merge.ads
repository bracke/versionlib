with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;
with Version.Staging;

package Version.Merge is

   type Merge_Result_Kind is
     (Clean_Merge,
      Fast_Forward,
      Already_Up_To_Date,
      Conflicted_Merge);

   type Conflict_Kind is
     (Content_Conflict,
      Add_Add_Conflict,
      Delete_Modify_Conflict,
      Directory_File_Conflict,
      Binary_Conflict);

   type Conflict_Favor is
     (Favor_Neither,
      Favor_Current,
      Favor_Target);

   type Conflict_Style is
     (Conflict_Style_Merge,
      Conflict_Style_Diff3,
      Conflict_Style_ZDiff3);

   type Whitespace_Mode is
     (Whitespace_Strict,
      Whitespace_Ignore_Space_Change,
      Whitespace_Ignore_All_Space,
      Whitespace_Ignore_Space_At_EOL,
      Whitespace_Ignore_CR_At_EOL);

   type Diff_Algorithm is
     (Diff_Algorithm_Default,
      Diff_Algorithm_Myers,
      Diff_Algorithm_Minimal,
      Diff_Algorithm_Patience,
      Diff_Algorithm_Histogram);

   type Directory_Rename_Mode is
     (Directory_Renames_Disabled,
      Directory_Renames_Conflict,
      Directory_Renames_Apply);

   type Merge_Behavior is record
      Favor            : Conflict_Favor := Favor_Neither;
      Style            : Conflict_Style := Conflict_Style_Merge;
      Marker_Size      : Positive := 7;
      --  Label for the diff3/zdiff3 `|||||||` section.  git names the merge
      --  base there: the abbreviated ancestor commit id, or "merged common
      --  ancestors" when the recursive merge built a virtual one.
      Base_Label       : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("base");
      Detect_Renames   : Boolean := True;
      Rename_Threshold : Natural := 50;
      Rename_Limit     : Natural := 0;
      Detect_Copies    : Boolean := False;
      Directory_Renames : Directory_Rename_Mode := Directory_Renames_Apply;
      --  git's submodule.recurse defaults to false: a merge updates the
      --  gitlink but leaves the submodule's working tree where it is.
      Recurse_Submodules : Boolean := False;
      Renormalize      : Boolean := False;
      Whitespace       : Whitespace_Mode := Whitespace_Strict;
      Algorithm        : Diff_Algorithm := Diff_Algorithm_Default;
      Enable_Rerere    : Boolean := False;
      Update_Worktree  : Boolean := True;
      Materialize_Virtual_Conflicts : Boolean := False;
   end record;

   type Conflict is record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Kind : Conflict_Kind;
   end record;

   package Conflict_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Conflict);

   function Conflict_Kind_Image (Kind : Conflict_Kind) return String;

   function Conflict_Kind_Value (Text : String) return Conflict_Kind;

   function Is_Binary_Content (Content : String) return Boolean;

   function Is_Safe_Relative_Path (Path : String) return Boolean;

   procedure Require_Safe_Path (Path : String);

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Favor         : Conflict_Favor := Favor_Neither);

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior);

   procedure Record_Rerere_Resolutions
     (Repo : Version.Repository.Repository_Handle; Conflicts : Conflict_Vectors.Vector);

   --  git's label for the diff3 base section: the abbreviated ancestor commit
   --  id.  A merge with no single ancestor (the recursive merge built a
   --  virtual one) is labelled "merged common ancestors", as git does.
   function Base_Label_For
     (Repo    : Version.Repository.Repository_Handle;
      Base_Id : Version.Objects.Hex_Object_Id) return String;

   --  git's label for the side being replayed by cherry-pick/rebase:
   --  `<abbrev> (<subject>)`.
   function Commit_Label_For
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id) return String;

   --  git's rerere conflict id for a conflicted file: SHA-1 over, per conflict
   --  block, `min_side & NUL & max_side & NUL` (sides sorted, newlines kept),
   --  markers ignored.  "" when the content has no conflict.  Byte-identical to
   --  git's rr-cache directory name.
   function Rerere_Conflict_Id (Conflicted_Content : String) return String;

   --  A run of changed lines: Old_First/Old_After and New_First/New_After are
   --  0-based half-open line ranges.  This is git's change script, as produced
   --  by the ported xdiff engine -- everything that diffs text in version goes
   --  through it, so hunks land exactly where git puts them.
   type Text_Change is record
      Old_First : Natural;
      Old_After : Natural;
      New_First : Natural;
      New_After : Natural;
   end record;

   package Text_Change_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Text_Change);

   --  Indent_Heuristic is git's diff.indentHeuristic, which `git diff` turns on
   --  by default and the merge machinery leaves off.
   function Text_Changes
     (Old_Text         : String;
      New_Text         : String;
      Algorithm        : Diff_Algorithm := Diff_Algorithm_Myers;
      Indent_Heuristic : Boolean := False) return Text_Change_Vectors.Vector;

   package Line_Match_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Natural);

   --  For each line of Current_Text (1-based), the line number it corresponds
   --  to in Parent_Text, or 0 when the line is new.  Uses git's own diff, so
   --  `blame` follows lines exactly where git follows them -- an equally
   --  minimal alignment is not enough, it has to be *git's* alignment.
   function Align_Lines
     (Current_Text : String;
      Parent_Text  : String) return Line_Match_Vectors.Vector;

   --  `git merge-file`: a hunk-level 3-way text merge.  Favor resolves
   --  conflicts to one side (or unions both); Style selects the marker layout.
   type Merge_File_Favor is
     (Favor_None, Favor_File_Ours, Favor_File_Theirs, Favor_Union);

   type Merge_File_Options is record
      Ours_Label   : Ada.Strings.Unbounded.Unbounded_String;
      Base_Label   : Ada.Strings.Unbounded.Unbounded_String;
      Theirs_Label : Ada.Strings.Unbounded.Unbounded_String;
      Style        : Conflict_Style := Conflict_Style_Merge;
      Favor        : Merge_File_Favor := Favor_None;
      Marker_Size  : Positive := 7;
      Algorithm    : Diff_Algorithm := Diff_Algorithm_Myers;
      --  Lines that differ only in whitespace this mode ignores are treated as
      --  equal when diffing, as `git merge -Xignore-*` does.
      Whitespace   : Whitespace_Mode := Whitespace_Strict;
      --  git's merge "level": `git merge-file` runs at XDL_MERGE_ZEALOUS_ALNUM,
      --  which also combines two conflicts separated by more than three common
      --  lines when none of those lines contains a letter or digit.  `git
      --  merge` itself runs at XDL_MERGE_ZEALOUS and does not.
      Simplify_No_Alnum : Boolean := True;
   end record;

   --  Merge Ours_Text and Theirs_Text against their common Base_Text,
   --  emitting the same bytes as `git merge-file -p` (clean regions stay
   --  outside `<<<<<<<`/`=======`/`>>>>>>>` markers; conflicts separated by up
   --  to three common lines are combined into one).  Conflicts returns the
   --  number of conflict hunks (git's exit code).
   procedure Merge_File
     (Ours_Text   : String;
      Base_Text   : String;
      Theirs_Text : String;
      Options     : Merge_File_Options;
      Merged      : out Ada.Strings.Unbounded.Unbounded_String;
      Conflicts   : out Natural);

end Version.Merge;
