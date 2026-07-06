package Version.Stash_Test_Support is

   Zero_Id : constant String := "0000000000000000000000000000000000000000";
   Bad_Old_Id : constant String := "dddddddddddddddddddddddddddddddddddddddd";

   function Stash_Ref_Path (Root : String) return String;
   function Stash_Log_Path (Root : String) return String;

   function Stash_Reflog_Line
     (Old_Id  : String;
      New_Id  : String;
      Message : String)
      return String;

   function Broken_Reflog_Chain
     (First_Id  : String;
      Second_Id : String;
      Bad_Old   : String := Bad_Old_Id)
      return String;

   procedure Write_Stash_Storage
     (Root    : String;
      New_Id  : String;
      Message : String);

end Version.Stash_Test_Support;
