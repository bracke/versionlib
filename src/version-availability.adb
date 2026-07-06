package body Version.Availability is

   function No_Repository return String is
   begin
      return "no repository found: run 'version init' or move into a working tree";
   end No_Repository;

   function No_Active_Branch return String is
   begin
      return "no active branch: HEAD is detached or unborn";
   end No_Active_Branch;

   function No_Staged_Changes return String is
   begin
      return "no staged changes to save";
   end No_Staged_Changes;

   function No_Remote_Configured (Name : String) return String is
   begin
      if Name'Length = 0 then
         return "no remote configured";
      else
         return "no remote configured: " & Name;
      end if;
   end No_Remote_Configured;

   function No_Upstream_Configured (Branch_Name : String) return String is
   begin
      if Branch_Name'Length = 0 then
         return "no upstream configured for current branch";
      else
         return "no upstream configured for branch: " & Branch_Name;
      end if;
   end No_Upstream_Configured;

   function Repository_Format_Unsupported (Detail : String) return String is
   begin
      if Detail'Length = 0 then
         return "repository format unsupported";
      else
         return "repository format unsupported: " & Detail;
      end if;
   end Repository_Format_Unsupported;

   function Operation_Unsafe_In_Linked_Worktree (Operation : String) return String is
   begin
      if Operation'Length = 0 then
         return "operation unsafe in linked worktree";
      else
         return "operation unsafe in linked worktree: " & Operation;
      end if;
   end Operation_Unsafe_In_Linked_Worktree;

   function Path_Outside_Worktree (Path : String) return String is
   begin
      if Path'Length = 0 then
         return "path is outside worktree";
      else
         return "path is outside worktree: " & Path;
      end if;
   end Path_Outside_Worktree;

   function Path_Excluded_By_Sparse_Checkout (Path : String) return String is
   begin
      if Path'Length = 0 then
         return "path is outside sparse checkout";
      else
         return "path is outside sparse checkout: " & Path;
      end if;
   end Path_Excluded_By_Sparse_Checkout;

   function Branch_In_Use_By_Worktree (Branch_Name : String) return String is
   begin
      return "branch already checked out in another worktree: " & Branch_Name;
   end Branch_In_Use_By_Worktree;

end Version.Availability;
