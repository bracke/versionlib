with Version.Objects;
with Version.Repository;

--  `git describe`: name a commit relative to the nearest reachable tag.
package Version.Describe is

   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False)
      return String;
   --  The tag name if Commit is exactly tagged, otherwise
   --  "<tag>-<N>-g<short>" where <tag> is the nearest ancestor tag and <N> is
   --  the number of commits since it. Like git, only annotated tags are
   --  considered by default; All_Tags (git's `--tags`) also considers
   --  lightweight tags. Raises Ada.IO_Exceptions.Data_Error when no eligible
   --  tag is an ancestor (mirroring git's "No names found" / "No annotated
   --  tags can describe ... try --tags" messages).

end Version.Describe;
