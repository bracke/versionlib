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
      Current_Branch : String)
      return String;

end Version.Fmt_Merge_Msg;
