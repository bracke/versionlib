with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git describe`: name a commit relative to the nearest reachable tag --
--  a port of builtin/describe.c: the ref table with git's priorities
--  (annotated tag, lightweight tag, other ref; two annotated tags on one
--  commit decided by tagger date), the commit-date search for the
--  candidate tags, the depth of the best one, and the blob form.
package Version.Describe is

   use Ada.Strings.Unbounded;

   --  git's die(): the message is the text after "fatal: ".
   Describe_Error : exception;

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   Default_Candidates : constant := 10;
   Max_Candidates     : constant := 27;   --  git's FLAG_BITS - 1

   type Describe_Options is record
      All_Refs     : Boolean := False;   --  --all
      Tags         : Boolean := False;   --  --tags (lightweight too)
      Long         : Boolean := False;   --  --long
      First_Parent : Boolean := False;   --  --first-parent
      Always       : Boolean := False;   --  --always
      Debug        : Boolean := False;   --  --debug (text in Messages)
      --  --abbrev: -1 is git's auto width (unique, at least 7), 0 drops the
      --  "-g<id>" suffix, otherwise at least that many digits.
      Abbrev       : Integer := -1;
      --  --candidates=<n>; 0 is --exact-match.
      Candidates   : Natural := Default_Candidates;
      Patterns     : String_Vectors.Vector;   --  --match
      Excludes     : String_Vectors.Vector;   --  --exclude
      Suffix       : Unbounded_String;        --  the --dirty/--broken mark
   end record;

   --  git's `names`: every ref that may name a commit, by the object it
   --  peels to.  Loaded once and shared by the operands of one command.
   type Name_Table is private;

   function Load_Names
     (Repo    : Version.Repository.Repository_Handle;
      Options : Describe_Options) return Name_Table;

   function Name_Count (Table : Name_Table) return Natural;

   --  The description of Commit; Messages collects git's stderr text
   --  (--debug lines and the "externally known as" warnings), each line
   --  newline-terminated -- a warning once per table, as git warns once
   --  per command.  Raises Describe_Error with git's fatal text.
   function Describe_Commit
     (Repo     : Version.Repository.Repository_Handle;
      Table    : in out Name_Table;
      Commit   : Version.Objects.Hex_Object_Id;
      Options  : Describe_Options;
      Messages : in out Unbounded_String) return String;

   --  `git describe <blob>`: the first commit (oldest first from HEAD)
   --  whose tree holds Blob, described, then ":<path>".
   function Describe_Blob
     (Repo     : Version.Repository.Repository_Handle;
      Table    : in out Name_Table;
      Blob     : Version.Objects.Hex_Object_Id;
      Options  : Describe_Options;
      Messages : in out Unbounded_String) return String;

   --  The older entry points, kept for the callers that want one answer.
   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False;
      Long     : Boolean := False;
      Abbrev   : Natural := 7;
      Pattern  : String  := "";
      Exclude  : String  := "")
      return String;
   --  The tag name if Commit is exactly tagged, otherwise
   --  "<tag>-<N>-g<short>".  Only annotated tags count unless All_Tags.
   --  Raises Ada.IO_Exceptions.Data_Error with git's message when no tag
   --  can describe the commit.

   function Describe_By_Any_Ref
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Long    : Boolean := False;
      Abbrev  : Natural := 7;
      Pattern : String  := "";
      Exclude : String  := "")
      return String;
   --  git's --all: the nearest ref of any kind, namespace kept.

private

   type Commit_Name is record
      Peeled       : Version.Objects.Object_Id_Storage;
      Id           : Version.Objects.Object_Id_Storage;   --  the ref's object
      Path         : Unbounded_String;
      Prio         : Natural := 0;   --  2 annotated, 1 lightweight, 0 other
      Tag_Name     : Unbounded_String;   --  the tag object's own name
      Tagger_Date  : Long_Long_Integer := 0;
      Name_Checked : Boolean := False;
      Misnamed     : Boolean := False;
   end record;

   package Name_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Version.Objects.Object_Id_Storage,
      Element_Type => Commit_Name,
      "<"          => Version.Objects."<");

   type Name_Table is record
      Names : Name_Maps.Map;
   end record;

end Version.Describe;
