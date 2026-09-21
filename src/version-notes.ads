with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git notes`: attach text notes to objects, stored in a notes ref's tree
--  (object id -> note blob). The in-memory Notes_Tree mirrors git's
--  `struct notes_tree` (notes.c): a map from annotated object to note blob,
--  a dirty flag, and the ref the tree came from. Every subcommand loads a
--  tree, edits it through Add_Note/Remove_Note/Copy_Note, and calls
--  Commit_Notes, which writes a commit only when something changed.
--
--  On disk, git fans a large tree out into 2-hex-digit directories; any
--  fanout is read (paths are joined back into object ids) and the written
--  layout follows git's determine_fanout heuristic, so small trees stay flat.
package Version.Notes is

   Default_Ref : constant String := "refs/notes/commits";
   --  git's `--ref=<name>` selects another notes ref; a bare name means
   --  refs/notes/<name>. Every operation takes the ref so a caller can keep
   --  several independent sets of notes, as git does.

   function Qualify_Ref (Name : String) return String;
   --  git's expand_notes_ref: "review" -> "refs/notes/review", "notes/review"
   --  -> "refs/notes/review"; a name under refs/notes/ comes back unchanged.
   --  An empty name gives Default_Ref.

   function Default_Notes_Ref
     (Repo : Version.Repository.Repository_Handle) return String;
   --  git's default_notes_ref: $GIT_NOTES_REF, else core.notesRef, else
   --  Default_Ref -- the ref every subcommand acts on absent `--ref`.

   Notes_Error : exception;
   --  A condition git dies on (message is git's text without "fatal: ").

   ---------------------------------------------------------------------------
   --  Notes tree model

   type Notes_Tree is private;

   --  git's combine_notes_fn: how Add_Note reconciles a new note with one
   --  already attached to the object.
   type Combine_Mode is
     (Combine_Overwrite,
      Combine_Ignore,
      Combine_Concatenate,
      Combine_Cat_Sort_Uniq);

   function Parse_Combine_Mode
     (Text : String; Mode : out Combine_Mode) return Boolean;
   --  Case-insensitive "overwrite" / "ignore" / "concatenate" /
   --  "cat_sort_uniq" (git's notes.rewriteMode values); False otherwise.

   function Empty_Tree (Ref : String) return Notes_Tree;
   --  A tree with no notes, as an unborn Ref has.

   procedure Load
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String;
      Tree : out Notes_Tree);
   --  The notes tree Ref (a full ref name) points at, empty when the ref
   --  does not exist. Commit_Notes advances the same ref.

   procedure Load_From_Commit
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String;
      Tree   : out Notes_Tree);
   --  The notes tree of a specific commit (git's init_notes on
   --  NOTES_MERGE_PARTIAL); Commit_Notes would advance Ref.

   function Ref_Of (Tree : Notes_Tree) return String;
   function Is_Dirty (Tree : Notes_Tree) return Boolean;

   function Note_Of (Tree : Notes_Tree; Object : String) return String;
   --  The hex id of Object's note blob, or "" when it has none. Object is a
   --  full hex object id.

   procedure Add_Note
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      Object  : String;
      Note    : String;
      Combine : Combine_Mode := Combine_Overwrite);
   --  git's add_note: attach the blob Note to Object, reconciling with an
   --  existing note per Combine (Concatenate/Cat_Sort_Uniq write a new blob).
   --  An empty Note means "no note": it removes the existing one under
   --  Combine_Overwrite, is a no-op under Combine_Ignore. Always dirties.

   function Remove_Note
     (Tree : in out Notes_Tree; Object : String) return Boolean;
   --  git's remove_note: True when a note was removed (and the tree
   --  dirtied); False when Object had none.

   function Copy_Note
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      From    : String;
      To      : String;
      Force   : Boolean;
      Combine : Combine_Mode := Combine_Overwrite) return Boolean;
   --  git's copy_note: True on failure (To already has a note and Force is
   --  off). A source without a note clears To's note under Overwrite.

   type Note_Entry is record
      Commit    : Ada.Strings.Unbounded.Unbounded_String;
      Note_Blob : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Note_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Note_Entry);

   function Entries (Tree : Notes_Tree) return Note_Vectors.Vector;
   --  Every note, in object-id order (git's for_each_note order).

   function Write_Tree
     (Repo : Version.Repository.Repository_Handle;
      Tree : Notes_Tree) return Version.Objects.Hex_Object_Id;
   --  git's write_notes_tree: the tree object for the notes, fanned out as
   --  git would fan it.

   function Create_Notes_Commit
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : Notes_Tree;
      Parents : Version.Objects.Object_Id_Vectors.Vector;
      Message : String) return Version.Objects.Hex_Object_Id;
   --  git's create_notes_commit: commit the tree with the given parents; an
   --  empty Parents means "the commit Ref_Of (Tree) points at, if any". The
   --  ref is not moved.

   procedure Commit_Notes
     (Repo    : Version.Repository.Repository_Handle;
      Tree    : in out Notes_Tree;
      Message : String);
   --  git's commit_notes: no-op unless the tree is dirty; otherwise commit on
   --  top of the ref's current commit and advance the ref, logging
   --  "notes: <Message>".

   function Prune_Candidates
     (Repo : Version.Repository.Repository_Handle;
      Tree : Notes_Tree) return Note_Vectors.Vector;
   --  The notes whose annotated object no longer exists, in tree order --
   --  what `git notes prune` removes (and `-n`/`-v` report).

   ---------------------------------------------------------------------------
   --  One-call conveniences over the model

   procedure Add
     (Repo            : Version.Repository.Repository_Handle;
      Commit          : Version.Objects.Hex_Object_Id;
      Message         : String;
      Ref             : String := Default_Ref;
      Cleanup_Message : Boolean := True);
   --  Set (or replace) the note for Commit and advance the notes ref. Message
   --  is whitespace-cleaned (trailing blanks trimmed, newline-terminated)
   --  unless Cleanup_Message is False, in which case it becomes the note blob
   --  verbatim -- the caller having already assembled the exact bytes.

   function Show
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return String;
   --  The note text for Commit, or "" when there is none.

   function List
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref)
      return Note_Vectors.Vector;
   --  Every noted commit and the blob holding its note, in commit-id order.

   function Has_Note
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref)
      return Boolean;

   procedure Remove
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id;
      Ref    : String := Default_Ref);
   --  Drop Commit's note. Raises when it has none, as git does.

   procedure Append
     (Repo            : Version.Repository.Repository_Handle;
      Commit          : Version.Objects.Hex_Object_Id;
      Message         : String;
      Ref             : String := Default_Ref;
      Cleanup_Message : Boolean := True);
   --  Add Message to any existing note, separated by a blank line -- which is
   --  how git joins them, and why appending is not merely a rewrite. When
   --  Cleanup_Message is False, Message is appended verbatim (the caller has
   --  already assembled the exact bytes) rather than whitespace-cleaned.

   procedure Copy
     (Repo  : Version.Repository.Repository_Handle;
      From  : Version.Objects.Hex_Object_Id;
      To    : Version.Objects.Hex_Object_Id;
      Force : Boolean := False;
      Ref   : String := Default_Ref);
   --  Copy From's note onto To. Raises when From has none, or when To already
   --  has one and Force is off.

   procedure Prune
     (Repo : Version.Repository.Repository_Handle;
      Ref  : String := Default_Ref);
   --  Drop notes whose commit no longer exists.

private

   package Note_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type     => String,    --  annotated object, full hex
      Element_Type => String);   --  note blob, full hex

   type Notes_Tree is record
      Ref   : Ada.Strings.Unbounded.Unbounded_String;
      Notes : Note_Maps.Map;
      Dirty : Boolean := False;
   end record;

end Version.Notes;
