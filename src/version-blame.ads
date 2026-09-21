with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.History;
with Version.Merge;
with Version.Objects;
with Version.Repository;

--  `git blame`: attribute each line of a file to the commit that introduced
--  it.  A port of git's blame.c scoreboard: the final image starts as one
--  suspect entry on the tip's origin (a <commit, path> pair); each origin
--  in turn hands the lines its parents already had to them (following the
--  file across renames, and with -M/-C across moves and copies from other
--  paths), keeps the rest as its own, and the parents are examined in
--  commit-date order until every line has found its guilty commit.
package Version.Blame is

   use Ada.Strings.Unbounded;

   --  git's die(): the message is the text after "fatal: ".
   Blame_Error : exception;
   --  A -L spec git answers with its usage line.
   Range_Error : exception;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  git's -S <file> grafts: a commit's parents replaced for the walk.
   type Graft is record
      Commit  : Version.Objects.Object_Id_Storage;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
   end record;
   package Graft_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Graft);

   Default_Move_Score : constant := 20;
   Default_Copy_Score : constant := 40;

   type Blame_Options is record
      Reverse_Blame    : Boolean := False;   --  --reverse
      First_Parent     : Boolean := False;   --  --first-parent
      Find_Moves       : Boolean := False;   --  -M
      --  -C count: 1 copies from paths deleted in the same commit, 2 also
      --  from paths that exist when the file was created, 3 from any path.
      Copies           : Natural := 0;
      Move_Score       : Natural := Default_Move_Score;
      Copy_Score       : Natural := Default_Copy_Score;
      Whitespace       : Version.Merge.Whitespace_Mode :=
        Version.Merge.Whitespace_Strict;   --  -w
      Algorithm        : Version.Merge.Diff_Algorithm :=
        Version.Merge.Diff_Algorithm_Myers;
      --  git's diff engine turns the indent heuristic on unless
      --  --no-indent-heuristic is given, blame included.
      Indent_Heuristic : Boolean := True;
      Max_Age          : Long_Long_Integer := -1;   --  --since (unix time)
      Show_Root        : Boolean := False;   --  --root
      Follow_Renames   : Boolean := True;    --  --no-follow clears it
      Textconv         : Boolean := True;
      Ignore_Revs      : Version.Objects.Object_Id_Vectors.Vector;
      --  --contents <file>: the final image comes from Contents rather
      --  than the working file; Contents_Name is what the fake commit's
      --  summary calls it ("standard input" for `-`).
      Have_Contents    : Boolean := False;
      Contents         : Unbounded_String;
      Contents_Name    : Unbounded_String;
      --  Raw -L specs, applied in order with git's anchoring.
      Ranges           : String_Vectors.Vector;
      Grafts           : Graft_Vectors.Vector;
   end record;

   --  A run of lines with one guilty <commit, path>: Lno is the 0-based
   --  first line in the final image, S_Lno that line's number in the
   --  suspect's copy of the file.  The fake working-tree commit has the
   --  all-zero id.
   type Blame_Entry is record
      Lno             : Natural := 0;
      Num_Lines       : Natural := 0;
      S_Lno           : Natural := 0;
      Commit          : Version.Objects.Object_Id_Storage;
      Path            : Unbounded_String;
      Boundary        : Boolean := False;   --  git's UNINTERESTING mark (^)
      Ignored         : Boolean := False;   --  --ignore-rev moved it here
      Unblamable      : Boolean := False;   --  an ignored commit's own line
      Score           : Natural := 0;       --  --score-debug
      Refcnt          : Natural := 0;
      Has_Previous    : Boolean := False;   --  porcelain "previous"
      Previous_Commit : Version.Objects.Object_Id_Storage;
      Previous_Path   : Unbounded_String;
      --  The commit is guilty for more than one path (git's
      --  MORE_THAN_ONE_PATH): porcelain repeats the filename.
      Multi_Path      : Boolean := False;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Blame_Entry);

   package Offset_Vectors is new Ada.Containers.Vectors
     (Index_Type => Natural, Element_Type => Natural);

   type Blame_Result is record
      --  Final image order, adjacent runs of one origin coalesced.
      Entries       : Entry_Vectors.Vector;
      --  In the order the guilty commits were found (--incremental),
      --  uncoalesced.
      Found_Order   : Entry_Vectors.Vector;
      Final_Text    : Unbounded_String;
      --  0-based byte offsets of each line's start, plus the text length.
      Line_Starts   : Offset_Vectors.Vector;
      Num_Lines     : Natural := 0;
      --  The fake commit stands in for the working file (or --contents):
      --  when it exists, its "now" timestamp and its parents (HEAD or the
      --  named tip, then MERGE_HEAD).
      Has_Fake      : Boolean := False;
      Fake_Time     : Long_Long_Integer := 0;
      Fake_Parents  : Version.Objects.Object_Id_Vectors.Vector;
      --  --show-stats counters.
      Num_Read_Blob : Natural := 0;
      Num_Get_Patch : Natural := 0;
      Num_Commits   : Natural := 0;
   end record;

   --  Blame Path as of the single positive commit in Include (none: the
   --  working file on top of HEAD), stopping at the ancestors of Exclude.
   --  Include_Names/Exclude_Names are the operands as typed, for messages.
   --  Under Reverse_Blame the single Exclude commit is where the walk
   --  starts and the blame follows children instead, ending at the
   --  Include tip (a lone Include with no Exclude means Include..HEAD).
   function Blame
     (Repo          : Version.Repository.Repository_Handle;
      Path          : String;
      Include       : Version.History.Commit_Id_Vectors.Vector;
      Exclude       : Version.History.Commit_Id_Vectors.Vector;
      Include_Names : String_Vectors.Vector;
      Exclude_Names : String_Vectors.Vector;
      Options       : Blame_Options := (others => <>))
      return Blame_Result;
   --  Raises Blame_Error with git's fatal text, Range_Error for a -L spec
   --  git rejects with its usage.

   --  Line Lno (0-based) of the final image, newline included.
   function Nth_Line (Result : Blame_Result; Lno : Natural) return String;

end Version.Blame;
