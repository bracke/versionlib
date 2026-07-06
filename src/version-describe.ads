with Version.Objects;
with Version.Repository;

--  `git describe`: name a commit relative to the nearest reachable tag.
package Version.Describe is

   function Describe
     (Repo   : Version.Repository.Repository_Handle;
      Commit : Version.Objects.Hex_Object_Id)
      return String;
   --  The tag name if Commit is exactly tagged, otherwise
   --  "<tag>-<N>-g<short>" where <tag> is the nearest ancestor tag and <N> is
   --  the number of commits since it. Raises Ada.IO_Exceptions.Data_Error when
   --  no tag is an ancestor.

end Version.Describe;
