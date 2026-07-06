package Version.Test_Support is

   --  Create a fresh temporary directory for a test case.
   --
   --  PROPERTIES:
   --    - unique per call (monotonic counter)
   --    - portable (env-based temp resolution)
   --    - directory is created
   --
   --  POST:
   --    Ada.Directories.Exists(Result) = True
   --
   function Fresh_Temp_Dir
     (Name : String)
      return String;

   --  Recursively delete a directory if it exists.
   --
   --  SAFE:
   --    - does nothing if path does not exist
   --    - never raises for non-existence
   --
   procedure Cleanup
     (Path : String);

   procedure Make_Directory
     (Path : String);

   procedure Write_Text_File
     (Path    : String;
      Content : String);

   function Read_Text_File
     (Path : String)
      return String;

   function Join
     (Left  : String;
      Right : String)
      return String;

end Version.Test_Support;