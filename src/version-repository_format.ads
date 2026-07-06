with Ada.Strings.Unbounded;

with Version.Hash;

package Version.Repository_Format is

   type Compatibility_Level is
     (Compatible,
      Read_Only,
      Unsupported);

   type Format_Info is record
      Repository_Format_Version : Natural := 0;
      Object_Format             : Ada.Strings.Unbounded.Unbounded_String;
      Ref_Storage               : Ada.Strings.Unbounded.Unbounded_String;
      Worktree_Config           : Boolean := False;
      Partial_Clone_Remote      : Ada.Strings.Unbounded.Unbounded_String;
      Level                     : Compatibility_Level := Compatible;
      Reason                    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   function Read
     (Git_Dir : String)
      return Format_Info;

   procedure Require_Compatible
     (Git_Dir  : String;
      Mutation : Boolean := True);

   function Is_Supported
     (Info : Format_Info)
      return Boolean;

   function Algorithm
     (Info : Format_Info)
      return Version.Hash.Hash_Algorithm;
   --  The object-id hash algorithm implied by Info.Object_Format
   --  ("sha1" -> Sha1, "sha256" -> Sha256; defaults to Sha1).

end Version.Repository_Format;
