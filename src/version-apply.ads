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
   end record;

   procedure Apply_Patch
     (Repo    : Version.Repository.Repository_Handle;
      Patch   : String;
      Options : Apply_Options := (others => <>));
   --  Apply the unified diff in Patch. Raises Ada.IO_Exceptions.Data_Error on
   --  a malformed patch or when a hunk's context/deletion lines do not match
   --  the current file content.

end Version.Apply;
