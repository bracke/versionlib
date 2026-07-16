with Version.Objects;
with Version.Repository;

--  git's "dumb" HTTP protocol: no server-side git, just files served over
--  ordinary GETs.  Everything reachable from a commit is walked by hand --
--  each object is fetched as a loose file, and when the server does not have
--  it loose, from the packs it advertises in `objects/info/packs`.
--
--  This is what `http-fetch` speaks.  version's normal HTTP transport is the
--  smart one; this is only for a server that has none.
package Version.Dumb_Http is

   --  Fetch every object reachable from Commit_Id into Repo.  Base_Url is the
   --  repository's URL (the directory holding `objects/` and `info/`).
   procedure Fetch
     (Repo      : Version.Repository.Repository_Handle;
      Base_Url  : String;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Verbose   : Boolean := False);

end Version.Dumb_Http;
