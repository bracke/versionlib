with Version.Repository;

--  git's commit-graph file (`.git/objects/info/commit-graph`): a cache of the
--  commit history's shape -- each commit's tree, its parents' positions, its
--  commit time, and its generation number -- so a traversal need not open the
--  commit objects themselves.
--
--  The file is "CGPH", a chunk table, and then the chunks: OIDF (fanout), OIDL
--  (the sorted object ids), CDAT (tree, parents, time and generation) and GDA2
--  (the corrected-commit-date offsets), with a trailing checksum.
package Version.Commit_Graph is

   --  Write the graph for every commit reachable from the repository's refs.
   procedure Write (Repo : Version.Repository.Repository_Handle);

   --  Is the graph on disk well-formed and consistent with the objects?
   --  Returns False (and says why through Diagnostic) if not.
   function Verify
     (Repo       : Version.Repository.Repository_Handle;
      Diagnostic : out String;
      Last       : out Natural)
      return Boolean;

   function Exists (Repo : Version.Repository.Repository_Handle)
     return Boolean;

end Version.Commit_Graph;
