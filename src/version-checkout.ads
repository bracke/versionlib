with Version.Objects;

package Version.Checkout is

   procedure Checkout_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Branch    : String := "");
   --  Update the working tree to Commit_Id. When Branch is empty HEAD is
   --  left detached at Commit_Id; when it names a local branch (without the
   --  refs/heads/ prefix) HEAD is attached to that branch symbolically, as
   --  `git checkout <branch>` does. Commit_Id must be the branch's tip.

   procedure Checkout_Path_From_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String);

end Version.Checkout;
