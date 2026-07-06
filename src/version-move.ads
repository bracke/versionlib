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
     (Repo        : Version.Repository.Repository_Handle;
      Source      : String;
      Destination : String;
      Force       : Boolean := False);
   --  As above, using an already-open repository handle (so the CLI can move
   --  several sources into a directory under one handle).

end Version.Move;
