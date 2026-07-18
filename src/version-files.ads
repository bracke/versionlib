package Version.Files is

   function Join
     (Left  : String;
      Right : String)
      return String;

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
