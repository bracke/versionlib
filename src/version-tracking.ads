with Ada.Strings.Unbounded;

with Version.Repository;

package Version.Tracking is

   use Ada.Strings.Unbounded;

   type Upstream_Info is record
      Remote : Unbounded_String;
      Merge  : Unbounded_String;
   end record;

   type Ahead_Behind is record
      Ahead  : Natural;
      Behind : Natural;
   end record;

   function Has_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Boolean;

   function Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Upstream_Info;

   procedure Set_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String;
      Remote_Name : String;
      Merge_Ref   : String);

   procedure Unset_Upstream
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String);

   function Remote_Tracking_Ref
     (Info : Upstream_Info)
      return String;

   function Count_Ahead_Behind
     (Repo        : Version.Repository.Repository_Handle;
      Branch_Name : String)
      return Ahead_Behind;

end Version.Tracking;
