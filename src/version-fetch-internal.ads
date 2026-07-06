with Version.Objects;
with Version.Ref_Transaction;
with Version.Repository;

package Version.Fetch.Internal is

   procedure Add_Update_With_Current_Old
     (Tx       : in out Version.Ref_Transaction.Transaction;
      Repo     : Version.Repository.Repository_Handle;
      Ref_Name : String;
      New_Id   : Version.Objects.Hex_Object_Id);

end Version.Fetch.Internal;
