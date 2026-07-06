package Version.Git_Fixtures is

   procedure Run
     (Dir     : String;
      Command : String);

   procedure Init_Repo_With_One_Commit
     (Root : String);

   procedure Init_Repo_With_Similar_Files
      (Root : String);

end Version.Git_Fixtures;