with Version.Objects;
with Version.Repository;

package Version.LFS is

   function Clean_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Smudge_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Worktree_Content
     (Repo          : Version.Repository.Repository_Handle;
      Relative_Path : String;
      Content       : String)
      return String;

   function Upload_Object
     (Repo        : Version.Repository.Repository_Handle;
      Oid         : String;
      Remote_Name : String)
      return Boolean;
   --  Upload the locally-cached LFS object Oid to the configured LFS store
   --  (lfs.url, else remote.<Remote_Name>.url) when that store is a local
   --  directory, storing it under <store>/objects/<oid[0:2]>/<oid[2:4]>/<oid>.
   --  Returns True if the object is present at the destination afterwards
   --  (uploaded or already there); False if the store is not a local directory
   --  (HTTP/SSH upload remains a follow-up) or the object is not cached locally.

   procedure Upload_Referenced_Objects
     (Repo        : Version.Repository.Repository_Handle;
      Commit_Id   : Version.Objects.Hex_Object_Id;
      Remote_Name : String);
   --  Upload every LFS object referenced by an LFS-pointer blob reachable from
   --  Commit_Id (git-lfs pre-push behavior). Objects whose store is not a local
   --  directory, or that are not cached locally, are skipped.

end Version.LFS;
