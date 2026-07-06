with Version.Objects;
with Version.Repository;

package Version.Receive_Pack.Internal is

   function Remote_Tracking_Id_Or_Zero
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Branch_Name : String) return String;

   procedure Update_Remote_Tracking_Ref
     (Repo         : Version.Repository.Repository_Handle;
      Remote_Name  : String;
      Branch_Name  : String;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Expected_Old : String);

end Version.Receive_Pack.Internal;
