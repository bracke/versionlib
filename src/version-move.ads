with Version.Repository;

--  `git mv` semantics: rename a tracked file in the working tree and restage
--  the rename (drop the source index entry, add the destination with the same
--  blob and mode). Does not create a commit.
package Version.Move is

   procedure Move_Path
     (Source      : String;
      Destination : String;
      Force       : Boolean := False);
   --  Move tracked Source to Destination, updating the index and working tree.
   --  Fails if Source is not tracked, or Destination already exists (in the
   --  index or working tree) unless Force is set.
   --  @param Source Tracked repository-relative path to move.
   --  @param Destination Repository-relative target path.
   --  @param Force Overwrite an existing destination.

   procedure Move_Path
     (Repo           : Version.Repository.Repository_Handle;
      Source         : String;
      Destination    : String;
      Force          : Boolean := False;
      Create_Parents : Boolean := False);
   --  Create_Parents allows the destination's parent directories to be made
   --  rather than required. git renames a directory with a single rename(2),
   --  so the new directory appears even though no parent was created for it;
   --  a caller replaying that as a file-by-file move needs this. For a plain
   --  file destination it stays off, because git reports the rename(2)
   --  failure rather than inventing the directory the caller mistyped.
   --  As above, using an already-open repository handle (so the CLI can move
   --  several sources into a directory under one handle).

end Version.Move;
