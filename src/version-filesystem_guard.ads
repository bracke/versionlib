with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Version.Filesystem_Guard is

   use Ada.Strings.Unbounded;

   type Planned_Path is record
      Path         : Unbounded_String;
      Is_Directory : Boolean := False;
      Is_Symlink   : Boolean := False;
   end record;

   package Planned_Path_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Planned_Path);

   procedure Set_Force_Case_Insensitive
     (Enabled : Boolean);

   function Collision_Key
     (Path : String)
      return String;

   procedure Require_No_Collisions
     (Paths : Planned_Path_Vectors.Vector);

   procedure Require_Safe_Write_Target
     (Repo_Root     : String;
      Relative_Path : String;
      Is_Directory  : Boolean := False;
      Is_Symlink    : Boolean := False);

   procedure Require_Safe_Delete_Target
     (Repo_Root     : String;
      Relative_Path : String);

   procedure Preflight_Checkout
     (Repo_Root : String;
      Paths     : Planned_Path_Vectors.Vector);

end Version.Filesystem_Guard;
