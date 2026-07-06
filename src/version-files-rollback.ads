package Version.Files.Rollback is
   --  Backup/rollback replacement strategy used when the normal
   --  Version.Files.Atomic_Replace path cannot rely on platform rename
   --  semantics to overwrite an existing target. Production callers should
   --  prefer Version.Files.Atomic_Replace unless they intentionally need this
   --  fallback behavior or its focused regression surface.

   function Rollback_Backup_Path
     (Target  : String;
      Attempt : Positive)
      return String;
   --  Return the collision-safe backup path used by this package for the
   --  given target and allocation attempt. Exposed so regression tests and
   --  diagnostics can reason about rollback artifacts without duplicating the
   --  naming contract.

   procedure Atomic_Replace_With_Backup_Rollback
     (Source_Temp : String;
      Target      : String);
   --  Fallback replacement strategy for platforms whose direct rename cannot
   --  overwrite an existing target. Existing targets are first moved to a
   --  collision-safe rollback path and restored if the final rename fails.

end Version.Files.Rollback;
