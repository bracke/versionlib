with Version.Ref_Names;
with Version.Ref_Transaction;
with Version.Refs;

package body Version.Receive_Pack.Internal is
   use Version.Objects;

   Zero_Id : constant String := "0000000000000000000000000000000000000000";

   function Remote_Tracking_Ref
     (Remote_Name : String;
      Branch_Name : String) return String
   is
   begin
      Version.Ref_Names.Require_Remote_Name (Remote_Name);
      Version.Ref_Names.Require_Branch_Name (Branch_Name);

      return "refs/remotes/" & Remote_Name & "/" & Branch_Name;
   end Remote_Tracking_Ref;

   function Remote_Tracking_Id_Or_Zero
     (Repo        : Version.Repository.Repository_Handle;
      Remote_Name : String;
      Branch_Name : String) return String
   is
      Ref_Name : constant String := Remote_Tracking_Ref (Remote_Name, Branch_Name);
   begin
      if Version.Refs.Ref_Exists (Repo => Repo, Name => Ref_Name) then
         return To_String (Version.Refs.Resolve_Ref (Repo => Repo, Name => Ref_Name));
      end if;

      return Zero_Id;
   end Remote_Tracking_Id_Or_Zero;

   procedure Update_Remote_Tracking_Ref
     (Repo         : Version.Repository.Repository_Handle;
      Remote_Name  : String;
      Branch_Name  : String;
      Commit_Id    : Version.Objects.Hex_Object_Id;
      Expected_Old : String)
   is
      Ref_Name : constant String := Remote_Tracking_Ref (Remote_Name, Branch_Name);
      Tx       : Version.Ref_Transaction.Transaction;
   begin
      Version.Ref_Transaction.Start (Item => Tx, Repo => Repo);
      Version.Ref_Transaction.Add_Update
        (Item         => Tx,
         Ref_Name     => Ref_Name,
         New_Id       => Commit_Id,
         Expected_Old => Expected_Old);
      Version.Ref_Transaction.Commit (Tx);
   exception
      when others =>
         Version.Ref_Transaction.Cancel (Tx);
         raise;
   end Update_Remote_Tracking_Ref;

end Version.Receive_Pack.Internal;
