with Version.Objects;
with Version.Repository;
with Version.Path_Safety;

package Version.Checkout is

   procedure Require_Switch_Safe
     (Repo      : Version.Repository.Repository_Handle;
      Commit_Id : Version.Objects.Hex_Object_Id;
      Carried   : out Version.Path_Safety.Path_Vector);
   --  git's rule for moving HEAD to Commit_Id with work in progress: refuse
   --  only for paths the move would write over -- those whose content differs
   --  between HEAD and Commit_Id -- and carry every other local edit across
   --  untouched. Carried returns those paths, which the caller must exclude
   --  when materializing the target tree, or the edit is silently lost.
   --  Raises git's "Your local changes ... would be overwritten" otherwise.

   procedure Checkout_Commit
     (Commit_Id     : Version.Objects.Hex_Object_Id;
      Branch        : String := "";
      Force         : Boolean := False;
      Reflog_Target : String := "";
      Reflog_Old    : String := "";
      Write_Reflog  : Boolean := True);
   --  Update the working tree to Commit_Id. When Branch is empty HEAD is
   --  left detached at Commit_Id; when it names a local branch (without the
   --  refs/heads/ prefix) HEAD is attached to that branch symbolically, as
   --  `git checkout <branch>` does. Commit_Id must be the branch's tip.
   --  Force is `checkout -f`: local edits to tracked paths and unmerged
   --  entries are thrown away instead of blocking the switch.
   --  The HEAD reflog line is git's "checkout: moving from <old> to
   --  <target>", where <target> is Reflog_Target as the user typed it
   --  (the branch, else the commit id) and <old> the departed branch or
   --  commit unless Reflog_Old names it; Write_Reflog => False writes none
   --  (a bare `checkout -f` of the current HEAD).

   procedure Checkout_Path_From_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String);

end Version.Checkout;
