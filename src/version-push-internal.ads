package Version.Push.Internal is

   procedure Require_Remote_Branch_Unchanged
     (Remote_Git_Dir    : String;
      Branch_Name       : String;
      Expected_Remote_Id : String);

   procedure Require_Remote_Tag_Unchanged
     (Remote_Git_Dir    : String;
      Tag_Name          : String;
      Expected_Remote_Id : String);

   function Remote_Tag_Object_Id
     (Remote_Git_Dir : String;
      Tag_Name       : String) return String;

end Version.Push.Internal;
