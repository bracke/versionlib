with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git notes`: attach text notes to commits, stored in a notes ref's tree
--  (commit id -> note blob). Notes are stored flat (one entry per full commit
--  id), which git reads; git's fanout layout is read only at top level.
package Version.Notes is

   Default_Ref : constant String := "refs/notes/commits";
   --  git's `--ref=<name>` selects another notes ref; a bare name means
   --  refs/notes/<name>. Every operation takes the ref so a caller can keep
   --  several independent sets of notes, as git does.

   function Qualify_Ref (Name : String) return String;
   --  "review" -> "refs/notes/review"; an already-qualified name comes back
   --  unchanged, and an empty name gives Default_Ref.

   type Note_Entry is record
      Commit    : Ada.Strings.Unbounded.Unbounded_String;
      Note_Blob : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Note_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Note_Entry);

   procedure Add
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String;
      Ref     : String := Default_Ref);
   --  Set (or replace) the note for Commit and advance the notes ref.

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
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Message : String;
      Ref     : String := Default_Ref);
   --  Add Message to any existing note, separated by a blank line -- which is
   --  how git joins them, and why appending is not merely a rewrite.

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

end Version.Notes;
