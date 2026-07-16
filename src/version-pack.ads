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
     (Repo         : Version.Repository.Repository_Handle;
      Pack_Path    : String;
      Canonicalize : Boolean := True);
   --  Build a Git pack index (.idx v2) beside Pack_Path. The index is
   --  generated from the pack contents so Version.Objects.Read_Object can
   --  locate fetched objects through the existing pack reader.
   --
   --  Canonicalize renames the pair to git's "pack-<checksum>" name, which is
   --  what a fetch wants (a fixed temporary name would collide and truncate an
   --  earlier pack).  `index-pack <file>` wants the opposite: the pack stays
   --  where it is and only the index is written.

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

   --  Where a delta-encoded entry's base lives: an absolute pack offset for an
   --  OFS delta, an object id for a REF delta.  Not a delta -> Is_Delta False.
   --  `verify-pack` needs this to report each object's chain depth.
   type Delta_Base_Info is record
      Is_Delta    : Boolean := False;
      By_Offset   : Boolean := False;
      Base_Offset : Interfaces.Unsigned_64 := 0;
      Base_Id     : Version.Objects.Object_Id_Storage;
   end record;

   function Read_Delta_Base
     (Repo     : Version.Repository.Repository_Handle;
      Location : Pack_Location) return Delta_Base_Info;

   function Read_Object_At_Location
     (Repo     : Version.Repository.Repository_Handle;
      Location : Pack_Location)
      return Version.Objects.Git_Object;

   function All_Pack_Objects
     (Repo : Version.Repository.Repository_Handle)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Every object id listed in the repository's pack index (`*.idx`) files.
   --  Used by `cat-file --batch-all-objects` together with the loose objects.

end Version.Pack;
