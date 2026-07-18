with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Pathspec;

package Version.Status is

   use Ada.Strings.Unbounded;

   type Change_Kind is
     (New_File,
      Modified_File,
      Deleted_File,
      Renamed_File,
      Ignored_File,
      Unmerged_File,
      Both_Added_File,
      Deleted_Modified_File,
      Directory_File_Conflict_File,
      Binary_Conflict_File);

   type File_Change is record
      Path : Unbounded_String;
      Kind : Change_Kind;
      --  For Renamed_File: where the content came from.  Empty otherwise.
      Old_Path : Unbounded_String;
   end record;

   package File_Change_Vectors is new
     Ada.Containers.Vectors
       (Index_Type   => Natural,
        Element_Type => File_Change);

   type Status_Result is record
      Changes   : File_Change_Vectors.Vector;
      Staged     : File_Change_Vectors.Vector;
      Untracked  : File_Change_Vectors.Vector;
      Ignored    : File_Change_Vectors.Vector;
      Conflicted : File_Change_Vectors.Vector;
   end record;

   type Ignored_Display_Mode is (Ignored_Traditional, Ignored_Matching);

   --  Compute repository status for the current directory.
   --
   --  This function performs the same repository analysis as Print_Status,
   --  but returns structured data for tests and future non-text frontends.
   --
   --  It must not modify repository files.
   --  All_Untracked is git's `-uall`: list every untracked file instead of
   --  collapsing a wholly-untracked directory to `dir/`.
   function Current_Status
     (All_Untracked : Boolean := False) return Status_Result;

   function Current_Status
     (Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector;
      All_Untracked : Boolean := False)
      return Status_Result;

   function Current_Status_With_Ignored
     (Mode          : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked : Boolean := False)
      return Status_Result;

   function Current_Status_With_Ignored
     (Pathspecs     : Version.Pathspec.Pathspec_Vectors.Vector;
      Mode          : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked : Boolean := False)
      return Status_Result;

   function Clean_Status_Line return String;
   function Change_Kind_Text (Kind : Change_Kind) return String;

   function Long_Status_Line
     (Kind     : Change_Kind;
      Path     : String;
      Unmerged : Boolean := False)
      return String;
   --  One entry line of the long `status` format: a tab, git's label for the
   --  change padded to its column (12 normally, 17 in the unmerged section),
   --  then the path.

   function Porcelain_Kind_Code (Kind : Change_Kind) return String;

   function Porcelain_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False;
      Display_Prefix  : String := "") return String;
   --  Display_Prefix re-expresses each path for a reader standing in that
   --  directory. It must stay empty for `--porcelain` itself, whose paths are
   --  worktree-relative by contract; `--short` passes the real prefix.
   function Short_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String;
   function Branch_Status_Text
     (Result          : Status_Result;
      Include_Ignored : Boolean := False) return String;

   --  Show_Untracked is git's `-uno`: omit the untracked section entirely,
   --  which also changes the closing summary line.
   procedure Print_Status
     (All_Untracked  : Boolean := False;
      Show_Untracked : Boolean := True);

   procedure Print_Status
     (Pathspecs      : Version.Pathspec.Pathspec_Vectors.Vector;
      All_Untracked  : Boolean := False;
      Show_Untracked : Boolean := True);

   procedure Print_Porcelain_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Porcelain_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Short_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Short_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Branch_Status
     (Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Branch_Status
     (Pathspecs       : Version.Pathspec.Pathspec_Vectors.Vector;
      Include_Ignored : Boolean := False;
      Ignored_Mode    : Ignored_Display_Mode := Ignored_Traditional;
      All_Untracked   : Boolean := False);

   procedure Print_Ignored_Status
     (Mode : Ignored_Display_Mode := Ignored_Traditional);

   procedure Print_Ignored_Status
     (Pathspecs : Version.Pathspec.Pathspec_Vectors.Vector;
      Mode      : Ignored_Display_Mode := Ignored_Traditional);

end Version.Status;
