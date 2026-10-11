with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Ignore is

   use Ada.Strings.Unbounded;

   type Ignore_Rules is private;

   function Load
     (Root : String)
      return Ignore_Rules;

   function Load
     (Repo : Version.Repository.Repository_Handle)
      return Ignore_Rules;

   function Is_Ignored
     (Rules         : Ignore_Rules;
      Relative_Path : String;
      Is_Directory  : Boolean)
      return Boolean;

   function Is_Ignored_In
     (Rules          : Ignore_Rules;
      Relative_Path  : String;
      Is_Directory   : Boolean;
      Parent_Ignored : Boolean)
      return Boolean;
   --  Is_Ignored, for a caller that knows already whether the directory the
   --  path is in is ignored -- a walk of the tree, which asked it of that
   --  directory -- so its parents are not matched again for every entry.

   function Excludes_Directory
     (Rules          : Ignore_Rules;
      Relative_Dir   : String;
      Parent_Ignored : Boolean)
      return Boolean;
   --  Whether what is under Relative_Dir is ignored for being under it, as
   --  Is_Ignored asks it of each parent of a path: its parent's answer, or
   --  its own match as a directory (a trailing "/**" not counted). A caller
   --  answering many paths keeps this per directory and hands it to
   --  Is_Ignored_In.

   function Rules_From_Text
     (Root             : String;
      Text             : String;
      Case_Insensitive : Boolean := False)
      return Ignore_Rules;
   --  Build a rule set from gitignore-style pattern lines (as sparse-checkout's
   --  non-cone patterns are: `/*`, `!/docs/`, ...) anchored at Root, reading no
   --  file. `Is_Ignored` against the result answers "does this path match the
   --  pattern set" -- which for sparse-checkout means "is it included".

   type Match_Result is record
      Has_Match   : Boolean := False;
      Is_Ignored  : Boolean := False;
      Source_Path : Unbounded_String;
      Source_Line : Natural := 0;
      Pattern     : Unbounded_String;
   end record;

   function Match
     (Rules         : Ignore_Rules;
      Relative_Path : String;
      Is_Directory  : Boolean)
      return Match_Result;

   --  git's wildmatch with pathname semantics: `*`, `?` and `[...]` do not
   --  cross a '/', `**` does.  `.gitattributes` matches with exactly this,
   --  so the attribute engine borrows it rather than reimplementing it.
   --  (Note this is the raw glob -- it carries none of gitignore's rules
   --  about directories and their contents.)
   function Wildcard_Matches
     (Pattern : String;
      Text    : String)
      return Boolean;

private

   type Rule is record
      Base_Dir       : Unbounded_String;
      Pattern        : Unbounded_String;
      Source_Path    : Unbounded_String;
      Source_Pattern : Unbounded_String;
      Source_Line    : Natural := 0;
      Negated        : Boolean := False;
      Directory_Only : Boolean := False;
      Anchored       : Boolean := False;
      Contains_Slash : Boolean := False;
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Rule);

   type Ignore_Rules is record
      Rules            : Rule_Vectors.Vector;
      Case_Insensitive : Boolean := False;
      Root_Path        : Unbounded_String;
   end record;

end Version.Ignore;
