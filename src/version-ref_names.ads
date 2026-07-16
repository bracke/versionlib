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

   --  General refname-grammar check, matching `git check-ref-format` (as
   --  opposed to Is_Valid_Ref_Name, which enforces version's stricter
   --  refs/heads|tags|remotes|notes storage policy). A conforming name needs
   --  at least one '/' unless Allow_Onelevel; Refspec_Pattern permits a single
   --  '*' glob.
   function Is_Valid_Check_Ref_Format
     (Name            : String;
      Allow_Onelevel  : Boolean := False;
      Refspec_Pattern : Boolean := False)
      return Boolean;

   --  Normalise per `git check-ref-format --normalize`: drop leading '/' and
   --  collapse runs of '/' to one.
   function Normalize_Ref_Format (Name : String) return String;

   procedure Require_Ref_Name    (Name : String);
   procedure Require_Branch_Name (Name : String);
   procedure Require_Tag_Name    (Name : String);
   procedure Require_Remote_Name (Name : String);

end Version.Ref_Names;
