with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

package Version.Packed_Refs is

   type Packed_Ref is record
      Name : Ada.Strings.Unbounded.Unbounded_String;
      Id   : Version.Objects.Object_Id_Storage;
   end record;

   package Packed_Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Packed_Ref);

   function Read_All
     (Repo : Version.Repository.Repository_Handle)
      return Packed_Ref_Vectors.Vector;

   function Find
     (Repo : Version.Repository.Repository_Handle;
      Name : String;
      Id   : out Version.Objects.Hex_Object_Id)
      return Boolean;

   procedure Write_All
     (Repo : Version.Repository.Repository_Handle;
      Refs : Packed_Ref_Vectors.Vector);

   procedure Pack_Refs
     (Repo          : Version.Repository.Repository_Handle;
      Include_Heads : Boolean := True;
      Include_Tags  : Boolean := True;
      Include_All   : Boolean := False;
      Prune_Loose   : Boolean := False);
   --  Include_All is git's `--all`: pack every ref under refs/, not just the
   --  branches and tags. Remote-tracking refs are the common case, and a
   --  repository can hold refs/notes, refs/stash or a third party's
   --  hierarchy besides -- none of which "heads and tags" reaches.

   procedure Remove
     (Repo : Version.Repository.Repository_Handle;
      Name : String);

end Version.Packed_Refs;
