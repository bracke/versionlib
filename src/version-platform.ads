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

end Version.Platform;
