with Version.Repository;

--  `git apply`: apply a unified diff to the working tree. Supports modify,
--  create (--- /dev/null) and delete (+++ /dev/null) file patches with -p1
--  path stripping and strict context verification. The patch is parsed and
--  validated in full before any file is written (atomic; --check stops here).
--
--  Not yet supported: -R (reverse), -p other than 1, --index/--cached, fuzz,
--  binary patches, and pure rename/mode-only patches.
package Version.Apply is

   type Apply_Options is record
      Check : Boolean := False;  --  --check: validate only, change nothing
   end record;

   procedure Apply_Patch
     (Repo    : Version.Repository.Repository_Handle;
      Patch   : String;
      Options : Apply_Options := (others => <>));
   --  Apply the unified diff in Patch. Raises Ada.IO_Exceptions.Data_Error on
   --  a malformed patch or when a hunk's context/deletion lines do not match
   --  the current file content.

end Version.Apply;
