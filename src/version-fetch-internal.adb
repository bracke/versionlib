with Ada.IO_Exceptions;

with Version.Ref_Names;
with Version.Refs;

package body Version.Fetch.Internal is
   use Version.Objects;

   Zero_Id : constant String := "0000000000000000000000000000000000000000";

   function Current_Ref_Id_Or_Zero
     (Repo     : Version.Repository.Repository_Handle;
      Ref_Name : String) return String
   is
   begin
      Version.Ref_Names.Require_Ref_Name (Ref_Name);

      if Version.Refs.Ref_Exists (Repo => Repo, Name => Ref_Name) then
         return To_String (Version.Refs.Resolve_Ref (Repo => Repo, Name => Ref_Name));
      end if;

      return Zero_Id;
   exception
      when Ada.IO_Exceptions.Data_Error =>
         return Zero_Id;
   end Current_Ref_Id_Or_Zero;

   procedure Add_Update_With_Current_Old
     (Tx       : in out Version.Ref_Transaction.Transaction;
      Repo     : Version.Repository.Repository_Handle;
      Ref_Name : String;
      New_Id   : Version.Objects.Hex_Object_Id)
   is
   begin
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => Ref_Name,
         New_Id       => New_Id,
         Expected_Old => Current_Ref_Id_Or_Zero (Repo, Ref_Name));
   end Add_Update_With_Current_Old;

end Version.Fetch.Internal;
