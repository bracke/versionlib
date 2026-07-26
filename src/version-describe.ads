with Version.Objects;
with Version.Repository;

--  `git describe`: name a commit relative to the nearest reachable tag.
package Version.Describe is

   function Describe
     (Repo     : Version.Repository.Repository_Handle;
      Commit   : Version.Objects.Hex_Object_Id;
      All_Tags : Boolean := False;
      Long     : Boolean := False;
      Abbrev   : Natural := 7;
      Pattern  : String  := "";
      Exclude  : String  := "")
      return String;
   --  Exclude, when non-empty, drops candidate tags whose short name matches
   --  the glob (git's --exclude).
   --  Long forces the "<tag>-<N>-g<short>" form even for an exactly-tagged
   --  commit, as git's --long does. Abbrev is how many hex digits the short id
   --  carries (git's --abbrev; 0 drops the "-g<short>" suffix entirely).
   --  Pattern, when non-empty, restricts the candidate tags to those whose
   --  short name matches the glob, as git's --match does.
   --  The tag name if Commit is exactly tagged, otherwise
   --  "<tag>-<N>-g<short>" where <tag> is the nearest ancestor tag and <N> is
   --  the number of commits since it. Like git, only annotated tags are
   --  considered by default; All_Tags (git's `--tags`) also considers
   --  lightweight tags. Raises Ada.IO_Exceptions.Data_Error when no eligible
   --  tag is an ancestor (mirroring git's "No names found" / "No annotated
   --  tags can describe ... try --tags" messages).

   function Describe_By_Any_Ref
     (Repo    : Version.Repository.Repository_Handle;
      Commit  : Version.Objects.Hex_Object_Id;
      Long    : Boolean := False;
      Abbrev  : Natural := 7;
      Pattern : String  := "";
      Exclude : String  := "")
      return String;
   --  git's --all: name Commit by the nearest reachable ref of any kind, not
   --  only tags, with the namespace kept ("tags/v2", "heads/main"). The tail
   --  and Pattern behave as for Describe.

end Version.Describe;
