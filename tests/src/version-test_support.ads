with GNAT.Sockets;

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

   procedure Stage_Resolved_File
     (Root : String;
      Path : String);
   --  Mark Path resolved the way a user does with `add`: hash the working-tree
   --  file and put it in the index at stage 0, dropping the conflict stages.
   --  A rebase will not continue while the index is still unmerged, so a test
   --  that only writes the resolved bytes has not finished resolving.

   function Join
     (Left  : String;
      Right : String)
      return String;

   --  The POSIX shell, located on PATH rather than assumed at /bin/sh: Git
   --  for Windows ships sh.exe and the absolute path does not exist there,
   --  so every fixture command failed before it ran.
   function Shell_Program return String;

   --  The git command, located on PATH rather than assumed at /usr/bin/git:
   --  Git for Windows installs elsewhere, and a spawn of a path that does
   --  not exist fails silently -- every oracle then answered "not ignored".
   function Git_Program return String;

   --  Accept a connection, but never for longer than Timeout.
   --
   --  A mock server task that blocks in Accept_Socket forever takes the whole
   --  suite with it: the test's task master waits for the task to terminate,
   --  so any exception raised in the test body before the client connects
   --  deadlocks the run rather than failing one case.  Raising here turns a
   --  hung job into a failing test with its own diagnosis.
   procedure Accept_With_Timeout
     (Server  : GNAT.Sockets.Socket_Type;
      Client  : out GNAT.Sockets.Socket_Type;
      Peer    : out GNAT.Sockets.Sock_Addr_Type;
      Timeout : Duration := 60.0);

end Version.Test_Support;