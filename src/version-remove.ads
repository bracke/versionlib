with Version.Status;

package Version.Remove is

   type Modification_Kind is
     (Unmodified,
      Staged_Change,
      Local_Change,
      Staged_And_Local_Change);
   --  Why a path may not be removed. git refuses to delete content it could
   --  not reconstruct: Staged_Change is an index that differs from HEAD,
   --  Local_Change a working file that differs from the index, and
   --  Staged_And_Local_Change both at once -- the case where the staged
   --  content matches neither the file nor HEAD, so removing loses two
   --  distinct versions. Only Unmodified is recoverable from the object
   --  store, and only it may be removed without -f.

   function Modification_Of
     (Status : Version.Status.Status_Result;
      Path   : String)
      return Modification_Kind;
   --  Classify Path against an already-computed status. Taking the status as
   --  a parameter keeps a multi-path removal to a single scan, and lets the
   --  caller classify every path before deleting any of them, which is what
   --  makes the refusal all-or-nothing.

   procedure Remove_Path
     (Path : String);

   procedure Remove_Path
     (Path        : String;
      Cached_Only : Boolean);
   --  Cached_Only is git's `--cached`: drop the index entry and leave the
   --  working file in place.

end Version.Remove;
