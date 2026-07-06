with Version.Objects;

package Version.Checkout is

   procedure Checkout_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id);

   procedure Checkout_Path_From_Commit
     (Commit_Id : Version.Objects.Hex_Object_Id;
      Path      : String);

end Version.Checkout;
