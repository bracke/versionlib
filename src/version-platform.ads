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

   --  Whether this host's "native" line ending is CRLF. git's core.eol
   --  defaults to `native`, which its NATIVE_CRLF build sets to CRLF, so a
   --  `text` file is checked out with CRLF on Windows and LF everywhere
   --  else.
   function Native_Eol_Is_CRLF return Boolean;

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

   --  Put the three standard streams into binary mode, once, so that what
   --  is written is what the caller gets and what is read is what the
   --  caller sent.
   --
   --  git does this on every host (its stdin/stdout are binary) and writes
   --  LF everywhere; GNAT's Text_IO writes the host's own terminator, so on
   --  Windows every Put_Line reached the caller as CRLF while
   --  Version.Console.Put (raw bytes) reached it as LF -- one stream
   --  carrying two spellings, and neither matching git. On input the same
   --  translation ate the CR out of a pack, a mailbox and a patch fed
   --  through a pipe. A no-op on a host with no text translation, so POSIX
   --  behaviour is unchanged.
   procedure Use_Byte_Exact_Standard_Streams;

   --  Whether the standard input / standard output is a terminal.
   --
   --  git asks this before reading a revision list from a pipe and before
   --  colouring its output. The C runtime's isatty is not the question on
   --  Windows: it answers yes for NUL as well, so `< /dev/null` looked like
   --  a console there and a command read the repository instead of its
   --  standard input. git's own mingw_isatty asks whether the handle is a
   --  console, which is what these do.
   function Stdin_Is_A_Terminal return Boolean;
   function Stdout_Is_A_Terminal return Boolean;

   --  The arguments this process was started with, counted from 1 as
   --  Ada.Command_Line counts them.
   --
   --  Not Ada.Command_Line: on Windows the vector a program receives has
   --  already been through a C runtime that parses one command-line string
   --  back into arguments and, depending on how it was built, expands a
   --  wildcard in it against the current directory first -- so `grep foo
   --  "*.txt"` arrived as the names of that directory's .txt files, where
   --  git matches the pathspec across directories. These ask the operating
   --  system for the command line instead (Hostkit.Command_Line).
   function Argument_Count return Natural;
   function Argument (Index : Positive) return String;

   --  The running executable, as one absolute path that a child process and
   --  a shell both accept. git re-runs itself for the subcommands it
   --  delegates (`stash list` is a `log`, `for-each-repo` runs a git command
   --  per repository); argv[0] alone is relative on a POSIX host and
   --  backslash-separated on Windows, where a shell reads each backslash as
   --  an escape and answers "command not found". Separators come back as
   --  forward slashes, which every host accepts.
   function Self_Program return String;

end Version.Platform;
