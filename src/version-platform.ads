package Version.Platform is

   type Platform_Kind is
     (POSIX_Platform,
      Windows_Platform,
      Unknown_Platform);

   function Current return Platform_Kind;

   function Is_Case_Insensitive_Default return Boolean;

   function Supports_Executable_Bit return Boolean;

   function Core_Filemode_Default return String;

   --  Whether the host lets an ordinary process create a symbolic link.
   --  git probes this at `init` and records core.symlinks = false where it
   --  cannot, which a stock Windows install cannot.
   function Supports_Symbolic_Links return Boolean;

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

   --  Path resolved to the form the host itself reports: on Windows %TEMP%
   --  is handed out in the 8.3 short spelling (C:\Users\RUNNER~1\...) while
   --  every tool prints the long one, so a path built from it never matched
   --  the paths in the output it was compared against. Returns Path unchanged
   --  when it cannot be resolved (it does not exist, or the host has no
   --  notion of a canonical form).
   function Canonical_Path (Path : String) return String;

   --  Put standard output and standard error into binary mode, once, so that
   --  a line terminator written through Ada.Text_IO is a single LF.
   --
   --  git writes LF on every host; GNAT's Text_IO writes the host's own
   --  terminator, so on Windows every Put_Line reached the caller as CRLF
   --  while Version.Console.Put (raw bytes) reached it as LF -- one stream
   --  carrying two spellings, and neither matching git. A no-op on a host
   --  with no text translation, so POSIX output is unchanged.
   procedure Use_Byte_Exact_Standard_Streams;

   --  The running executable, as one absolute path that a child process and
   --  a shell both accept. git re-runs itself for the subcommands it
   --  delegates (`stash list` is a `log`, `for-each-repo` runs a git command
   --  per repository); argv[0] alone is relative on a POSIX host and
   --  backslash-separated on Windows, where a shell reads each backslash as
   --  an escape and answers "command not found". Separators come back as
   --  forward slashes, which every host accepts.
   function Self_Program return String;

end Version.Platform;
