with Ada.Directories;
with Ada.IO_Exceptions;
use type Ada.Directories.File_Kind;

with GNAT.OS_Lib;

with Version.Files;
with Version.Objects;
with Version.Ref_Names;
with Version.Transport.Local;

package body Version.Push.Internal is

   function Remote_Branch_Path
     (Remote_Git_Dir : String;
      Branch_Name    : String) return String
   is
   begin
      Version.Ref_Names.Require_Branch_Name (Branch_Name);
      return Version.Files.Join (Remote_Git_Dir, "refs/heads/" & Branch_Name);
   end Remote_Branch_Path;

   function Remote_Tag_Path
     (Remote_Git_Dir : String;
      Tag_Name       : String) return String
   is
   begin
      Version.Ref_Names.Require_Tag_Name (Tag_Name);
      return Version.Files.Join (Remote_Git_Dir, "refs/tags/" & Tag_Name);
   end Remote_Tag_Path;

   function Read_Remote_Ref_Object_Id
     (Path       : String;
      Diagnostic : String) return String
   is
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Version.Files.To_Native_Path (Path))
        or else Ada.Directories.Kind (Path) = Ada.Directories.Special_File
      then
         raise Ada.IO_Exceptions.Data_Error with
           "invalid remote ref entry: " & Path;
      end if;

      declare
         Text : constant String := Version.Transport.Local.Read_First_Line (Path);
      begin
         if not Version.Objects.Is_Valid_Hex_Object_Id (Text) then
            raise Ada.IO_Exceptions.Data_Error with Diagnostic;
         end if;

         return Text;
      end;
   end Read_Remote_Ref_Object_Id;

   function Remote_Branch_Object_Id
     (Remote_Git_Dir : String;
      Branch_Name    : String) return String
   is
      Path : constant String := Remote_Branch_Path (Remote_Git_Dir, Branch_Name);
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      return Read_Remote_Ref_Object_Id
        (Path       => Path,
         Diagnostic => Version.Push.Invalid_Remote_Branch_Commit_Id_Diagnostic);
   end Remote_Branch_Object_Id;

   function Remote_Tag_Object_Id
     (Remote_Git_Dir : String;
      Tag_Name       : String) return String
   is
      Path : constant String := Remote_Tag_Path (Remote_Git_Dir, Tag_Name);
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      return Read_Remote_Ref_Object_Id
        (Path       => Path,
         Diagnostic => Version.Push.Invalid_Remote_Tag_Object_Id_Diagnostic);
   end Remote_Tag_Object_Id;

   procedure Require_Remote_Branch_Unchanged
     (Remote_Git_Dir    : String;
      Branch_Name       : String;
      Expected_Remote_Id : String)
   is
   begin
      if Remote_Branch_Object_Id (Remote_Git_Dir, Branch_Name)
        /= Expected_Remote_Id
      then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Push.Remote_Branch_Changed_During_Push_Diagnostic;
      end if;
   end Require_Remote_Branch_Unchanged;

   procedure Require_Remote_Tag_Unchanged
     (Remote_Git_Dir    : String;
      Tag_Name          : String;
      Expected_Remote_Id : String)
   is
   begin
      if Remote_Tag_Object_Id (Remote_Git_Dir, Tag_Name) /= Expected_Remote_Id then
         raise Ada.IO_Exceptions.Data_Error with
           Version.Push.Remote_Tag_Changed_During_Push_Diagnostic;
      end if;
   end Require_Remote_Tag_Unchanged;

end Version.Push.Internal;
