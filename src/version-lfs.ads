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

end Version.LFS;
