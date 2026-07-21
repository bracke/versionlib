with Version.Repository;

--  `git apply`: apply a unified diff to the working tree and/or index.
--  Supports modify, create (--- /dev/null), delete (+++ /dev/null),
--  pure rename and mode-only patches; -R (reverse), -p<n> path stripping,
--  --index/--cached, whitespace-tolerant context matching (fuzz), and git
--  binary patches (literal/delta, base85). The patch is parsed and validated
--  in full before any file is written (atomic; --check stops here).
package Version.Apply is

   type Apply_Options is record
      Check         : Boolean := False;  --  --check: validate only
      Reverse_Patch : Boolean := False;  --  -R / --reverse
      Strip         : Natural := 1;      --  -p<n> (leading path components)
      Update_Index  : Boolean := False;  --  --index (working tree + index)
      Cached        : Boolean := False;  --  --cached (index only)
      Allow_Empty   : Boolean := False;  --  --allow-empty: accept no patches
   end record;

   Malformed_Patch : exception;
   --  The input is not a well-formed patch at all -- unparsable, corrupt, or
   --  with a header that cannot yield a filename. git dies (exit 128) on these,
   --  distinct from a well-formed patch that simply does not apply.

   procedure Apply_Patch
     (Repo    : Version.Repository.Repository_Handle;
      Patch   : String;
      Options : Apply_Options := (others => <>));
   --  Apply the unified diff in Patch. Raises Malformed_Patch when the input is
   --  not a valid patch (git's die, exit 128), and Ada.IO_Exceptions.Data_Error
   --  when a well-formed patch does not apply -- a hunk's context/deletion
   --  lines do not match, or --index finds the file out of sync (exit 1).

end Version.Apply;
