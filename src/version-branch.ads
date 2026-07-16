with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;

package Version.Branch is

   type Merge_Fast_Forward_Mode is
     (Fast_Forward_Allowed,
      Fast_Forward_Only,
      Fast_Forward_Disabled);

   type Merge_Conflict_Favor is
     (Favor_Neither,
      Favor_Current,
      Favor_Target);

   type Merge_Conflict_Style is
     (Conflict_Style_Default,
      Conflict_Style_Merge,
      Conflict_Style_Diff3,
      Conflict_Style_ZDiff3);

   type Merge_Whitespace_Mode is
     (Whitespace_Strict,
      Whitespace_Ignore_Space_Change,
      Whitespace_Ignore_All_Space,
      Whitespace_Ignore_Space_At_EOL,
      Whitespace_Ignore_CR_At_EOL);

   type Merge_Diff_Algorithm is
     (Diff_Algorithm_Default,
      Diff_Algorithm_Myers,
      Diff_Algorithm_Minimal,
      Diff_Algorithm_Patience,
      Diff_Algorithm_Histogram);

   type Merge_Strategy is
     (Strategy_Default,
      Strategy_Ort,
      Strategy_Recursive,
      Strategy_Resolve,
      Strategy_Ours,
      Strategy_Octopus,
      Strategy_Subtree);

   type Merge_Directory_Rename_Mode is
     (Directory_Renames_Default,
      Directory_Renames_Disabled,
      Directory_Renames_Conflict,
      Directory_Renames_Apply);

   type Merge_Options is record
      Fast_Forward : Merge_Fast_Forward_Mode := Fast_Forward_Allowed;
      Fast_Forward_Explicit : Boolean := False;
      Squash : Boolean := False;
      Squash_Explicit : Boolean := False;
      No_Commit : Boolean := False;
      No_Commit_Explicit : Boolean := False;
      Allow_Unrelated_Histories : Boolean := False;
      Run_Hooks : Boolean := True;
      Autostash : Boolean := False;
      Autostash_Explicit : Boolean := False;
      Strategy : Merge_Strategy := Strategy_Default;
      Strategy_Explicit : Boolean := False;
      Strategy_Ours : Boolean := False;
      Conflict_Favor : Merge_Conflict_Favor := Favor_Neither;
      Conflict_Favor_Explicit : Boolean := False;
      Conflict_Style : Merge_Conflict_Style := Conflict_Style_Default;
      Marker_Size : Positive := 7;
      Detect_Renames : Boolean := True;
      Detect_Renames_Explicit : Boolean := False;
      Rename_Threshold : Natural := 50;
      Rename_Limit : Natural := 0;
      Rename_Limit_Explicit : Boolean := False;
      Detect_Copies : Boolean := False;
      Detect_Copies_Explicit : Boolean := False;
      Directory_Renames : Merge_Directory_Rename_Mode := Directory_Renames_Default;
      --  git's submodule.recurse default is false.
      Recurse_Submodules : Boolean := False;
      Recurse_Submodules_Explicit : Boolean := False;
      Renormalize : Boolean := False;
      Renormalize_Explicit : Boolean := False;
      Whitespace : Merge_Whitespace_Mode := Whitespace_Strict;
      Algorithm : Merge_Diff_Algorithm := Diff_Algorithm_Default;
      Subtree : Boolean := False;
      Subtree_Prefix : Ada.Strings.Unbounded.Unbounded_String;
      Enable_Rerere : Boolean := False;
      Stat : Boolean := False;
      Stat_Explicit : Boolean := False;
      Compact_Summary : Boolean := False;
      Log_Limit : Natural := 0;
      Log_Explicit : Boolean := False;
      Signoff : Boolean := False;
      Signoff_Explicit : Boolean := False;
      Verify_Signatures : Boolean := False;
      Verify_Signatures_Explicit : Boolean := False;
      GPG_Sign : Ada.Strings.Unbounded.Unbounded_String;
      GPG_Sign_Explicit : Boolean := False;
      Cleanup_Mode : Ada.Strings.Unbounded.Unbounded_String;
      Into_Name : Ada.Strings.Unbounded.Unbounded_String;
      Edit_Message : Boolean := False;
      Edit_Explicit : Boolean := False;
      Message : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   procedure Create_Branch
      (Name      : String;
       Commit_Id : String);

   procedure Create_Branch
     (Name : String);

   procedure Rename_Branch
     (Old_Name : String;
      New_Name : String);

   procedure Rename_Current_Branch
     (New_Name : String);

   procedure Delete_Branch
     (Name  : String;
      Force : Boolean := False);

   procedure Switch_Branch
     (Name : String);

   function Current_Branch_Name return String;

   function Current_Branch_Text return String;

   function Branch_Exists
     (Name : String)
      return Boolean;

   function Resolve_Branch
     (Name : String)
      return Version.Objects.Hex_Object_Id;

   function Resolve_Branch_Text
     (Name : String)
      return String;

   function Upstream_Text
     (Name : String := "")
      return String;

   function List_Branches_Verbose_Text return String;

   function Branches_Containing_Text
     (Revision : String)
      return String;

   function Merged_Branches_Text
     (Base_Branch : String := "")
      return String;

   function Unmerged_Branches_Text
     (Base_Branch : String := "")
      return String;

   procedure Update_Current_Branch
     (Target_Name : String);

   procedure Integrate_Branch
     (Name : String);

   package Merge_Target_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Ada.Strings.Unbounded.Unbounded_String,
      "="          => Ada.Strings.Unbounded."=");

   --  git's subtree strategy: shift a side's tree so it lines up with ours.
   --  The prefix is inferred from the two trees when it is not given (that is
   --  what `-Xsubtree` without a value does).  Both the other side's tree and
   --  the merge base's must be shifted the same way.
   function Shift_Subtree_Items
     (Items         : Version.Objects.Tree_Entry_Vectors.Vector;
      Current_Items : Version.Objects.Tree_Entry_Vectors.Vector;
      Target_Items  : Version.Objects.Tree_Entry_Vectors.Vector;
      Prefix        : String := "")
      return Version.Objects.Tree_Entry_Vectors.Vector;

   procedure Merge
     (Target  : String;
      Options : Merge_Options);

   procedure Merge_Multiple
     (Targets : Merge_Target_Vectors.Vector;
      Options : Merge_Options);

   procedure Finalize_Integration
     (Run_Hooks : Boolean := False);

   procedure Abort_Integration;

   procedure Quit_Integration;

end Version.Branch;