with Version.Objects;
with Version.Repository;
with Version.Pathspec;

package Version.Diff is

   type Diff_Options is record
      Context_Lines : Natural := 3;
   end record;

   function Diff_Working_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Working_Tree
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   function Diff_Staged
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Staged
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   function Diff_Cached
     (Repo    : Version.Repository.Repository_Handle;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Cached
     (Repo       : Version.Repository.Repository_Handle;
      Pathspecs  : Version.Pathspec.Pathspec_Vectors.Vector;
      Options    : Diff_Options := (others => <>))
      return String;

   function Diff_Commits
     (Repo    : Version.Repository.Repository_Handle;
      Old_Id  : Version.Objects.Hex_Object_Id;
      New_Id  : Version.Objects.Hex_Object_Id;
      Options : Diff_Options := (others => <>))
      return String;

   function Diff_Commits
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : Version.Objects.Hex_Object_Id;
      New_Id    : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>))
      return String;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Options   : Diff_Options := (others => <>))
      return String;

   function Diff_Root_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Options   : Diff_Options := (others => <>))
      return String;

end Version.Diff;
