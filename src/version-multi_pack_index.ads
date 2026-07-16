with Version.Repository;

--  git's multi-pack-index (`.git/objects/pack/multi-pack-index`): one lookup
--  table over every pack in the repository, so finding an object does not mean
--  searching each pack's index in turn.
--
--  The file is "MIDX", a chunk table, and then PNAM (the pack names), OIDF
--  (fanout), OIDL (the sorted object ids) and OOFF (which pack each object is
--  in, and where), with a trailing checksum.
package Version.Multi_Pack_Index is

   procedure Write (Repo : Version.Repository.Repository_Handle);

   function Verify
     (Repo       : Version.Repository.Repository_Handle;
      Diagnostic : out String;
      Last       : out Natural)
      return Boolean;

end Version.Multi_Pack_Index;
