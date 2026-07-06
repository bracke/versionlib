with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;
with Version.Staging;

package Version.Merge is

   type Merge_Result_Kind is
     (Clean_Merge,
      Fast_Forward,
      Already_Up_To_Date,
      Conflicted_Merge);

   type Conflict_Kind is
     (Content_Conflict,
      Add_Add_Conflict,
      Delete_Modify_Conflict,
      Directory_File_Conflict,
      Binary_Conflict);

   type Conflict_Favor is
     (Favor_Neither,
      Favor_Current,
      Favor_Target);

   type Conflict_Style is
     (Conflict_Style_Merge,
      Conflict_Style_Diff3,
      Conflict_Style_ZDiff3);

   type Whitespace_Mode is
     (Whitespace_Strict,
      Whitespace_Ignore_Space_Change,
      Whitespace_Ignore_All_Space,
      Whitespace_Ignore_Space_At_EOL,
      Whitespace_Ignore_CR_At_EOL);

   type Diff_Algorithm is
     (Diff_Algorithm_Default,
      Diff_Algorithm_Myers,
      Diff_Algorithm_Minimal,
      Diff_Algorithm_Patience,
      Diff_Algorithm_Histogram);

   type Directory_Rename_Mode is
     (Directory_Renames_Disabled,
      Directory_Renames_Conflict,
      Directory_Renames_Apply);

   type Merge_Behavior is record
      Favor            : Conflict_Favor := Favor_Neither;
      Style            : Conflict_Style := Conflict_Style_Merge;
      Marker_Size      : Positive := 7;
      Detect_Renames   : Boolean := True;
      Rename_Threshold : Natural := 50;
      Rename_Limit     : Natural := 0;
      Detect_Copies    : Boolean := False;
      Directory_Renames : Directory_Rename_Mode := Directory_Renames_Apply;
      Recurse_Submodules : Boolean := True;
      Renormalize      : Boolean := False;
      Whitespace       : Whitespace_Mode := Whitespace_Strict;
      Algorithm        : Diff_Algorithm := Diff_Algorithm_Default;
      Enable_Rerere    : Boolean := False;
      Update_Worktree  : Boolean := True;
      Materialize_Virtual_Conflicts : Boolean := False;
   end record;

   type Conflict is record
      Path : Ada.Strings.Unbounded.Unbounded_String;
      Kind : Conflict_Kind;
   end record;

   package Conflict_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Conflict);

   function Conflict_Kind_Image (Kind : Conflict_Kind) return String;

   function Conflict_Kind_Value (Text : String) return Conflict_Kind;

   function Is_Binary_Content (Content : String) return Boolean;

   function Is_Safe_Relative_Path (Path : String) return Boolean;

   procedure Require_Safe_Path (Path : String);

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Favor         : Conflict_Favor := Favor_Neither);

   procedure Merge_Trees
     (Repo          : Version.Repository.Repository_Handle;
      Current_Name  : String;
      Target_Name   : String;
      Base_Items    : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Merged_Index  : in out Version.Staging.Index_Entry_Vectors.Vector;
      Conflicts     : in out Conflict_Vectors.Vector;
      Behavior      : Merge_Behavior);

   procedure Record_Rerere_Resolutions
     (Repo : Version.Repository.Repository_Handle; Conflicts : Conflict_Vectors.Vector);

end Version.Merge;
