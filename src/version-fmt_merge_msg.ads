with Version.Repository;

--  Format a merge-commit message from FETCH_HEAD-style input, matching
--  `git fmt-merge-msg`.
package Version.Fmt_Merge_Msg is

   --  Input is FETCH_HEAD content: lines of "<sha> TAB <flag> TAB <desc>",
   --  where a non-empty <flag> ("not-for-merge") lines are skipped and <desc>
   --  is e.g. "branch 'x' of <url>", "tag 'x'", or "branch 'x'". Current_Branch
   --  is the short name of the branch being merged into (for the " into <name>"
   --  suffix, which git omits on "master"/"main"). Repo is used to read the
   --  message of any merged annotated tag, appended to the body as git does.
   function Format
     (Repo           : Version.Repository.Repository_Handle;
      Input          : String;
      Current_Branch : String;
      Log_Entries    : Integer := 0)
      return String;
   --  Log_Entries is `--log[=<n>]`: 0 for no shortlog (the default), -1 for
   --  `--log` with no limit, or a positive count. The shortlog lists the
   --  subjects of the commits being merged, newest first, under a "* <branch>:"
   --  heading; when a limit hides some, git says how many there were and
   --  closes the list with "...".

end Version.Fmt_Merge_Msg;
