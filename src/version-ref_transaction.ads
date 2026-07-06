with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Packed_Refs;
with Version.Repository;

package Version.Ref_Transaction is

   type Transaction is limited private;

   procedure Start
     (Item : out Transaction;
      Repo : Version.Repository.Repository_Handle);

   procedure Add_Update
     (Item         : in out Transaction;
      Ref_Name     : String;
      New_Id       : Version.Objects.Hex_Object_Id;
      Expected_Old : String := "");

   procedure Add_Delete
     (Item         : in out Transaction;
      Ref_Name     : String;
      Expected_Old : String := "");

   procedure Commit
     (Item : in out Transaction);

   procedure Cancel
     (Item : in out Transaction);

   function Invalid_Expected_Old_Diagnostic return String;
   function Expected_Missing_Ref_Diagnostic (Ref_Name : String) return String;
   function Expected_Old_Mismatch_Diagnostic (Ref_Name : String) return String;

private

   type Operation_Kind is
     (Update_Ref,
      Delete_Ref);

   type Operation is record
      Kind         : Operation_Kind;
      Ref_Name     : Ada.Strings.Unbounded.Unbounded_String;
      New_Id       : Version.Objects.Object_Id_Storage := Version.Objects.Zero_Object_Id;
      Expected_Old : Ada.Strings.Unbounded.Unbounded_String;
      Lock_Path    : Ada.Strings.Unbounded.Unbounded_String;
      Backup_Path  : Ada.Strings.Unbounded.Unbounded_String;
      Had_Backup   : Boolean := False;
      Applied      : Boolean := False;
   end record;

   package Operation_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Operation);

   type Transaction is limited record
      Repo                  : Version.Repository.Repository_Handle;
      Active                : Boolean := False;
      Ops                   : Operation_Vectors.Vector;
      Packed_Backup         : Version.Packed_Refs.Packed_Ref_Vectors.Vector;
      Packed_Backup_Staged  : Boolean := False;
      Packed_Backup_Applied : Boolean := False;
   end record;

end Version.Ref_Transaction;
