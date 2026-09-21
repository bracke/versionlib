with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;
with Version.History;

--  `git shortlog`: summarize history grouped by author -- a port of
--  builtin/shortlog.c: each commit contributes one record per group key
--  (author, committer, trailer values, or a pretty format), the keys kept
--  in byte order, each holding its one-line subjects.
package Version.Shortlog is

   package Subject_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   package String_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   type Author_Group is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;
      --  In output order: the commits as walked, reversed (oldest first
      --  for git's default newest-first walk).
      Subjects : Subject_Vectors.Vector;
      Count    : Natural := 0;
   end record;

   package Group_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Author_Group);

   type Shortlog_Options is record
      Summary       : Boolean := False;   --  -s: counts only
      Email         : Boolean := False;   --  -e: "Name <mail>" keys
      By_Author     : Boolean := False;   --  --group=author
      By_Committer  : Boolean := False;   --  -c / --group=committer
      Trailers      : String_Vectors.Vector;   --  --group=trailer:<key>
      Formats       : String_Vectors.Vector;   --  --group=format:<fmt>
      --  --format=<fmt>: the one-line record is that pretty format
      --  rather than the subject.
      Has_User_Format : Boolean := False;
      User_Format   : Ada.Strings.Unbounded.Unbounded_String;
      Date_Mode     : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   --  No group set at all means author, as in git.

   --  The records collected so far (git's `struct shortlog`).
   type Shortlog is private;

   --  shortlog_add_commit: the commit's records under every group of
   --  Options (a key that several groups produce for one commit counts
   --  once).
   procedure Add_Commit
     (Log     : in out Shortlog;
      Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Options : Shortlog_Options);

   --  insert_one_record: one record for Ident (already mapped) with
   --  Oneline as its subject (trimmed, a leading "[PATCH ...]" dropped,
   --  folded to one line).  What reading `git log` on stdin feeds.
   procedure Add_Record
     (Log     : in out Shortlog;
      Ident   : String;
      Oneline : String;
      Options : Shortlog_Options);

   --  The groups in key order; Numbered sorts them by descending count
   --  (stable, so equal counts stay in key order), as -n does.
   function Groups
     (Log : Shortlog; Numbered : Boolean := False) return Group_Vectors.Vector;

   --  git's strbuf_add_wrapped_text: Text wrapped to Width columns,
   --  the first line indented Indent1, the rest Indent2 (shortlog -w).
   function Wrapped_Text
     (Text : String; Indent1, Indent2, Width : Natural) return String;

   function Summarize
     (Repo : Version.Repository.Repository_Handle;
      Tip  : Version.Objects.Hex_Object_Id)
      return Group_Vectors.Vector;
   --  Commits reachable from Tip, grouped by author name (groups sorted by
   --  name); each group lists the commit subjects oldest first (chronological),
   --  matching git shortlog.

   function Summarize
     (Repo       : Version.Repository.Repository_Handle;
      Commits    : Version.History.Commit_Id_Vectors.Vector;
      With_Email : Boolean := False)
      return Group_Vectors.Vector;
   --  Same, over an already-selected commit list (so the caller can apply a
   --  range, pathspec or --no-merges via rev-list). With_Email groups by the
   --  full "Name <email>" author identity, as `shortlog -e` does. The list is
   --  expected newest-first (rev-list order); each group's subjects are
   --  reversed to chronological order.

private

   type Group_Data is record
      Count    : Natural := 0;
      Subjects : Subject_Vectors.Vector;   --  insertion order
   end record;

   package Group_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Group_Data);

   type Shortlog is record
      Map : Group_Maps.Map;
   end record;

end Version.Shortlog;
