package Version.Clone is

   procedure Clone
     (Source : String;
      Target : String);

   --  git's `-b <branch>` checks out that branch (setting HEAD to it) instead
   --  of the remote's default; `--no-checkout` registers HEAD and the refs but
   --  leaves the working tree and index empty.
   procedure Clone
     (Source : String;
      Target : String;
      Branch : String;
      No_Checkout : Boolean);

   procedure Clone
     (Source : String;
      Target : String;
      Depth  : Positive);

   --  git's `--bare`/`--mirror`: create a bare repository (no working tree),
   --  fetch every ref, point HEAD at the remote's default branch and pack the
   --  refs. Mirror additionally records the remote as a mirror
   --  (fetch = +refs/*:refs/*, mirror = true, tagOpt = --no-tags).
   procedure Clone_Bare
     (Source : String;
      Target : String;
      Mirror : Boolean := False);

   procedure Clone_Filtered
     (Source : String;
      Target : String;
      Filter : String);
   --  Partial clone applying a filter spec (e.g. "blob:none" or
   --  "blob:limit=<n>"); the repository is configured as a partial clone so
   --  omitted objects are lazily fetched from origin on first access.

end Version.Clone;
