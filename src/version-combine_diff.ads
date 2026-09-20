with Version.Diff;
with Version.Objects;
with Version.Pathspec;
with Version.Pickaxe;
with Version.Repository;

--  git's combined diff of a merge commit (`-c` / `--cc`, combine-diff.c):
--  for every path the merge result differs from at least one parent in,
--  the result's lines annotated per parent -- a column per parent, `+`
--  where that parent lacks the line, `-` lines the result dropped from a
--  parent -- in `@@@ -l,n -l,n +l,n @@@` hunks.  Dense (`--cc`) drops the
--  hunks that only changed against one parent or where the result took
--  one parent's side wholesale, which is what leaves the conflict
--  resolutions.
package Version.Combine_Diff is

   --  The combined patch of Commit against Parents (its parents, in
   --  order), limited to Paths when non-empty.  Options' context width,
   --  whitespace mode, algorithm, prefixes and index abbreviation apply.
   function Combined_Patch
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Options   : Version.Diff.Diff_Options := (others => <>);
      Dense     : Boolean := True;
      Pick      : Version.Pickaxe.Spec := (others => <>)) return String;
   --  Pick (git's generic path scan under -S/-G) keeps only the paths whose
   --  change against every parent matches.

   --  git's --raw / --name-only / --name-status of a merge under -c/--cc
   --  (show_raw_diff): the same paths, one line each -- raw as
   --  `::<parent modes> <mode> <parent ids> <id> <statuses>\t<path>`, the
   --  status letters one per parent.
   type Listing_Kind is (Raw_Listing, Name_Only_Listing, Name_Status_Listing);

   function Combined_Listing
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Parents   : Version.Objects.Object_Id_Vectors.Vector;
      Paths     : Version.Pathspec.Pathspec_Vectors.Vector :=
        Version.Pathspec.Pathspec_Vectors.Empty_Vector;
      Options   : Version.Diff.Diff_Options := (others => <>);
      Kind      : Listing_Kind := Name_Only_Listing;
      Pick      : Version.Pickaxe.Spec := (others => <>)) return String;

end Version.Combine_Diff;
