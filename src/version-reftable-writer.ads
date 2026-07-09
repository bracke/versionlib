with Version.Repository;

--  Writer for git's reftable ref storage. Append_Table is the incremental
--  write path: each transaction appends a small table at the next update index
--  and geometric auto-compaction keeps the stack bounded. Write_Stack is the
--  full-rewrite/compaction primitive. git reads the result (verified with
--  for-each-ref / fsck / reflog).
package Version.Reftable.Writer is

   function Serialize
     (Refs             : Ref_Record_Vectors.Vector;
      Logs             : Log_Record_Vectors.Vector;
      Min_Update_Index : Long_Long_Integer;
      Raw_Length       : Positive)
      return String;
   --  A single reftable file image (v1 layout: one ref block, and, when Logs is
   --  non-empty, one zlib-compressed log block; no obj/index sections).
   --  Min_Update_Index is the table's base index; per-record update indices are
   --  encoded relative to it, and Ref_Deletion records become tombstones. Refs
   --  and Logs are sorted here. Exposed for unit testing.

   procedure Write_Stack
     (Repo : Version.Repository.Repository_Handle;
      Refs : Ref_Record_Vectors.Vector;
      Logs : Log_Record_Vectors.Vector := Log_Record_Vectors.Empty_Vector);
   --  Replace Repo's entire reftable stack with a single compacted table
   --  holding Refs (and Logs). Writes the new table, rewrites tables.list to
   --  name only it, and removes the superseded table files.

   procedure Append_Table
     (Repo    : Version.Repository.Repository_Handle;
      Refs    : Ref_Record_Vectors.Vector;
      Deleted : Ref_Record_Vectors.Vector := Ref_Record_Vectors.Empty_Vector;
      Logs    : Log_Record_Vectors.Vector := Log_Record_Vectors.Empty_Vector);
   --  Append one table holding just this transaction's changes (Refs updated,
   --  Deleted as tombstones, Logs added) at the next update index, then run
   --  geometric auto-compaction. O(changed) per call rather than O(stack).

   procedure Initialize_Stack
     (Common_Git_Dir : String;
      Default_Branch : String;
      Raw_Length     : Positive);
   --  Create a fresh reftable stack under Common_Git_Dir/reftable holding just
   --  the HEAD symref (-> refs/heads/Default_Branch), as `git init
   --  --ref-format=reftable` does. Used at init time, before a repository
   --  handle exists.

end Version.Reftable.Writer;
