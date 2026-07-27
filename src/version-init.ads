with Version.Hash;

package Version.Init is

   type Ref_Storage_Kind is (Files, Reftable);
   --  The ref backend a new repository uses: loose files + packed-refs
   --  (git's default) or the binary reftable stack.

   procedure Init
      (Path           : String := ".";
       Object_Format  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;
       Ref_Storage    : Ref_Storage_Kind := Files;
       Initial_Branch : String := "main");

   procedure Init_Bare
      (Path           : String := ".";
       Object_Format  : Version.Hash.Hash_Algorithm := Version.Hash.Sha1;
       Ref_Storage    : Ref_Storage_Kind := Files;
       Initial_Branch : String := "main");
   --  Initial_Branch names the branch HEAD points at in a fresh repository
   --  (git's `--initial-branch`; the CLI passes git's "master" default when no
   --  init.defaultBranch is configured).

end Version.Init;
