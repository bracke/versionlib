with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

--  `git clean` semantics: remove untracked files (and, with options, untracked
--  directories and ignored files) from the working tree.
package Version.Clean is

   type Clean_Options is record
      Directories : Boolean := False;  --  -d : include untracked directories
      Ignored     : Boolean := False;  --  -x : also remove ignored files
   end record;

   package Path_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   function Candidates
     (Repo    : Version.Repository.Repository_Handle;
      Options : Clean_Options)
      return Path_Vectors.Vector;
   --  Repo-root-relative paths that clean would remove, collapsed the way git
   --  reports them: a fully-untracked directory appears once with a trailing
   --  '/'. Without Options.Directories untracked directories are omitted.
   --  Does not delete anything (use for the dry run and as the work list).

   procedure Remove_Candidate
     (Repo : Version.Repository.Repository_Handle;
      Path : String);
   --  Delete one candidate produced by Candidates: a file, or (for a path
   --  ending in '/') a directory tree, located under the repository root.

end Version.Clean;
