with Version.Objects;
with Version.Repository;
with Interfaces;
with Ada.Strings.Unbounded;

package Version.Pack is

   function Contains
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Boolean;

   function Read_Object
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Version.Objects.Git_Object;

   procedure Index_Pack
     (Repo      : Version.Repository.Repository_Handle;
      Pack_Path : String);
   --  Build a Git pack index (.idx v2) beside Pack_Path. The index is
   --  generated from the pack contents so Version.Objects.Read_Object can
   --  locate fetched objects through the existing pack reader.

   type Pack_Location is record
      Found      : Boolean := False;
      Pack_Path  : Ada.Strings.Unbounded.Unbounded_String;
      Offset     : Interfaces.Unsigned_64 := 0;
      End_Offset : Interfaces.Unsigned_64 := 0;
   end record;

   function Find_Location
     (Repo : Version.Repository.Repository_Handle;
      Id   : Version.Objects.Hex_Object_Id)
      return Pack_Location;

   type Packed_Object_Type is
     (Packed_Commit,
      Packed_Tree,
      Packed_Blob,
      Packed_Tag,
      Packed_Ofs_Delta,
      Packed_Ref_Delta,
      Packed_Unsupported);

   type Packed_Object_Header is record
      Kind : Packed_Object_Type := Packed_Unsupported;
      Size : Interfaces.Unsigned_64 := 0;
      Data_Offset : Interfaces.Unsigned_64 := 0;
   end record;

   function Read_Header
     (Location : Pack_Location)
      return Packed_Object_Header;

   function Read_Object_At_Location
     (Repo     : Version.Repository.Repository_Handle;
      Location : Pack_Location)
      return Version.Objects.Git_Object;

end Version.Pack;
