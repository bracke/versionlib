package Version.Ref_Names is

   function Is_Valid_Ref_Name
     (Name : String)
      return Boolean;

   function Is_Valid_Branch_Name
     (Name : String)
      return Boolean;

   function Is_Valid_Tag_Name
     (Name : String)
      return Boolean;

   function Is_Valid_Remote_Name
     (Name : String)
      return Boolean;

   procedure Require_Ref_Name    (Name : String);
   procedure Require_Branch_Name (Name : String);
   procedure Require_Tag_Name    (Name : String);
   procedure Require_Remote_Name (Name : String);

end Version.Ref_Names;
