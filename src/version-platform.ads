package Version.Platform is

   type Platform_Kind is
     (POSIX_Platform,
      Windows_Platform,
      Unknown_Platform);

   function Current return Platform_Kind;

   function Is_Case_Insensitive_Default return Boolean;

   function Supports_Executable_Bit return Boolean;

   function Core_Filemode_Default return String;

   function Is_Windows_Drive_Path
     (Path : String)
      return Boolean;

   function Is_Windows_Drive_Like_Path
     (Path : String)
      return Boolean;

   function Native_Path_Separator return Character;

   --  The POSIX shell git runs hooks, editors, aliases and merge drivers
   --  through. /bin/sh on a POSIX host; on Windows there is no such path and
   --  the shell is whatever Git for Windows put on PATH, so it is located
   --  rather than assumed. Falls back to "/bin/sh" when nothing is found, so
   --  the caller still reports the failure it always did.
   function Shell_Program return String;

end Version.Platform;
