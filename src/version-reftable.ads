with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Version.Objects;
with Version.Repository;

--  Reader for git's reftable ref storage (`extensions.refStorage = reftable`).
--  A reftable "stack" is the newline-separated list of binary table files in
--  `.git/reftable/tables.list` (oldest first); each table holds prefix-
--  compressed, varint-encoded ref (and log) records. Resolution merges the
--  stack newest-first, with a deletion record masking older entries.
--
--  This package is the P0 read path: it parses the ref blocks of each table
--  and exposes the merged, live ref set. Log blocks, the obj/index sections,
--  and writing are handled elsewhere.
package Version.Reftable is

   use Ada.Strings.Unbounded;

   type Ref_Value_Kind is
     (Ref_Deletion,   --  ref removed in this table (masks older tables)
      Ref_Direct,     --  a single object id
      Ref_Peeled,     --  object id plus peeled target (annotated tag)
      Ref_Symref);    --  symbolic ref (e.g. HEAD -> refs/heads/main)

   type Ref_Record is record
      Name         : Unbounded_String;
      Kind         : Ref_Value_Kind := Ref_Deletion;
      Id           : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Peeled       : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Target       : Unbounded_String;         --  symref target
      Update_Index : Long_Long_Integer := 0;
   end record;

   package Ref_Record_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Ref_Record);

   --  A reflog entry stored in a reftable log block (zlib-compressed). Log
   --  records key on (refname, reversed update index) so newest sorts first.
   type Log_Record is record
      Ref_Name        : Unbounded_String;
      Update_Index    : Long_Long_Integer := 0;
      Old_Id          : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      New_Id          : Version.Objects.Object_Id_Storage :=
        Version.Objects.Zero_Object_Id;
      Committer_Name  : Unbounded_String;
      Committer_Email : Unbounded_String;
      Time_Seconds    : Long_Long_Integer := 0;
      TZ_Offset       : Integer := 0;
      Message         : Unbounded_String;
      Is_Deletion     : Boolean := False;
   end record;

   package Log_Record_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Log_Record);

   function Is_Reftable
     (Repo : Version.Repository.Repository_Handle) return Boolean;
   --  True when the repository's ref storage is reftable.

   function Live_Refs
     (Repo : Version.Repository.Repository_Handle)
      return Ref_Record_Vectors.Vector;
   --  All live (non-deleted) refs, merged across the stack newest-wins,
   --  sorted by name. Symrefs are returned unresolved.

   function Find
     (Repo  : Version.Repository.Repository_Handle;
      Name  : String;
      Found : out Boolean)
      return Ref_Record;
   --  The winning record for Name across the stack (Found = False if absent
   --  or masked by a deletion). The record may be a symref.

   procedure Set_In
     (Refs : in out Ref_Record_Vectors.Vector;
      Rec  : Ref_Record);
   --  Replace the record named Rec.Name in Refs, or append it if absent.

   procedure Delete_In
     (Refs : in out Ref_Record_Vectors.Vector;
      Name : String);
   --  Remove the record named Name from Refs (no-op if absent).

   package Name_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Unbounded_String);

   function Stack_Table_Names
     (Repo : Version.Repository.Repository_Handle)
      return Name_Vectors.Vector;
   --  The table file names from tables.list, oldest first.

   function Table_Path
     (Repo : Version.Repository.Repository_Handle;
      Name : String) return String;
   --  Absolute path of a table file named in tables.list.

   function Current_Max_Update_Index
     (Repo : Version.Repository.Repository_Handle) return Long_Long_Integer;
   --  The highest max_update_index across the stack's tables, or 0 if empty.
   --  The next appended table uses Current_Max_Update_Index + 1.

   function Live_Logs
     (Repo : Version.Repository.Repository_Handle)
      return Log_Record_Vectors.Vector;
   --  All reflog entries across the stack, newest first (by refname then
   --  descending update index). Deletion entries are dropped.

   function Log_For
     (Repo     : Version.Repository.Repository_Handle;
      Ref_Name : String)
      return Log_Record_Vectors.Vector;
   --  Reflog entries for one ref, newest first.

   --  Parse the ref records of a single in-memory reftable file (exposed for
   --  unit testing). Raw_Length is the object-id width (20 or 32).
   function Parse_Table
     (Bytes      : String;
      Raw_Length : Positive)
      return Ref_Record_Vectors.Vector;

   --  Parse the log records of a single in-memory reftable file (exposed for
   --  unit testing); empty when the table has no log block.
   function Parse_Log_Records
     (Bytes      : String;
      Raw_Length : Positive)
      return Log_Record_Vectors.Vector;

end Version.Reftable;
