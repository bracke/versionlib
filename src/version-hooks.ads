with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Hooks is

   use Ada.Strings.Unbounded;

   package Argument_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Unbounded_String);

   type Hook_Result is record
      Ran       : Boolean := False;
      Exit_Code : Integer := 0;
      Output    : Unbounded_String;
   end record;

   function Hook_Arguments
     (Values : String)
      return Argument_Vectors.Vector;

   procedure Append_Argument
     (Arguments : in out Argument_Vectors.Vector;
      Value     : String);

   function Run_Hook
     (Repo      : Version.Repository.Repository_Handle;
      Name      : String;
      Arguments : Argument_Vectors.Vector;
      Blocking  : Boolean := True)
      return Hook_Result;

   function Prepare_Commit_Message
     (Repo      : Version.Repository.Repository_Handle;
      Message   : String;
      Run_Hooks : Boolean := True)
      return String;

   procedure Run_Post_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Run_Hooks : Boolean := True);

   procedure Run_Pre_Merge_Commit
     (Repo      : Version.Repository.Repository_Handle;
      Run_Hooks : Boolean := True);

   procedure Run_Post_Checkout
     (Repo      : Version.Repository.Repository_Handle;
      Old_Id    : String;
      New_Id    : String;
      Flag      : String;
      Run_Hooks : Boolean := True);

   procedure Run_Post_Merge
     (Repo      : Version.Repository.Repository_Handle;
      Squash    : Boolean := False;
      Run_Hooks : Boolean := True);

   procedure Require_Hook_Success
     (Result  : Hook_Result;
      Context : String);

   function Hooks_Disabled return Boolean;

end Version.Hooks;
