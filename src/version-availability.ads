package Version.Availability is

   function No_Repository return String;
   function No_Active_Branch return String;
   function No_Staged_Changes return String;
   function No_Remote_Configured (Name : String) return String;
   function No_Upstream_Configured (Branch_Name : String) return String;
   function Repository_Format_Unsupported (Detail : String) return String;
   function Operation_Unsafe_In_Linked_Worktree (Operation : String) return String;
   function Path_Outside_Worktree (Path : String) return String;
   function Path_Excluded_By_Sparse_Checkout (Path : String) return String;
   function Branch_In_Use_By_Worktree (Branch_Name : String) return String;

end Version.Availability;
