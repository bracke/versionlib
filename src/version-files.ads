package Version.Files is

   function Join
     (Left  : String;
      Right : String)
      return String;

   function Exists
     (Path : String)
      return Boolean;
   --  Whether Path names something on disk. Unlike Exists
   --  this answers False for a name the host cannot spell rather than
   --  raising: on Windows every character git allows in a pathspec or a
   --  rev:path -- `*`, `?`, `:` -- makes the name malformed there, so the
   --  plain test turned `show HEAD:nosuch` into "fatal: invalid path name"
   --  and a `*.txt` pathspec into the same.

   function Relative_To_Prefix
     (Path   : String;
      Prefix : String)
      return String;
   --  Re-express a worktree-relative Path for display from the directory
   --  Prefix names (itself worktree-relative and slash-terminated), the way
   --  git shows paths to a human: a path inside the directory loses the
   --  prefix, one outside it gains the "../" steps needed to reach it. An
   --  empty Prefix returns Path unchanged. Machine-readable output must not
   --  use this -- git keeps `--porcelain` worktree-relative on purpose.

   function Normalize_Separators
     (Path : String)
      return String;

   function To_Native_Path
     (Path : String)
      return String;

   procedure Require_Reasonable_Path_Length
     (Path : String);

   procedure Create_Parent_Directories
     (Path : String);

   procedure Create_Directory_If_Missing
     (Path : String);

   procedure Write_Binary_File
     (Path    : String;
      Content : String);

   procedure Write_Binary_File_Atomic
     (Path    : String;
      Content : String);

   function Read_Binary_File
      (Path : String) return String;

   procedure Atomic_Replace
     (Source_Temp : String;
      Target      : String);
   --  Preferred replacement API. Uses the platform's direct rename/replace
   --  behavior where it can preserve an existing target atomically.

   function Child_Path
     (Directory : String;
      Name      : String)
      return String;
   --  Directory, a separator, and Name kept byte for byte -- what a
   --  directory entry's path is. Join is wrong here because it normalizes
   --  separators, which rewrites a file name that legitimately contains a
   --  backslash; Ada.Directories.Full_Name is wrong because it validates
   --  the simple name, which a host may reject for a control character git
   --  tracks happily.

   procedure Delete_File
     (Path : String);
   --  Remove Path. Unlike Ada.Directories.Delete_File this clears the
   --  read-only attribute and tries once more when the host refuses: git
   --  writes every loose object read-only, and Windows will not unlink a
   --  read-only file -- git's own mingw_unlink chmods first for exactly
   --  this reason. Raises what Ada.Directories.Delete_File raises otherwise.

   procedure Delete_File_If_Exists
     (Path : String);

   procedure Rename_Directory
     (Source : String;
      Target : String);

   procedure Delete_Directory_Tree_If_Exists
     (Path : String);

   procedure Remove_File_If_Safe
     (Repo_Root     : String;
      Relative_Path : String);

   procedure Set_Executable
     (Path : String; Executable : Boolean);
   --  Set (Executable) or clear the executable bits of Path via POSIX chmod
   --  (mode 0755 vs 0644). A no-op on platforms without an executable bit.

   procedure Write_Symlink
     (Path : String; Target : String);
   --  Create Path as a symbolic link to Target, replacing whatever is already
   --  there. A mode 120000 index or tree entry stores its target as the blob
   --  content, so anything materialising such an entry must come through here
   --  -- writing the content as a regular file instead silently turns the
   --  link into a file whose text happens to be a path. Raises Use_Error if
   --  the link cannot be created, and Data_Error on a platform without
   --  symbolic links or for a target that cannot be one.

   function Is_Ordinary_File
     (Path : String)
      return Boolean;

   function Is_Directory
     (Path : String)
      return Boolean;

   function Current_Directory return String;

   procedure Set_Current_Directory
     (Path : String);

   procedure With_Directory
     (Path   : String;
      Action : not null access procedure);

end Version.Files;
