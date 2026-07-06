with Ada.Containers.Vectors;
with Interfaces;

with Version.Hash;
with Version.Objects;

package Version.Pack_Index is

   type Index_Entry is record
      Id     : Version.Objects.Object_Id_Storage;
      Offset : Interfaces.Unsigned_64 := 0;
      Crc    : Interfaces.Unsigned_32 := 0;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Natural,
      Element_Type => Index_Entry);

   function Build
     (Entries       : Entry_Vectors.Vector;
      Pack_Checksum : String;
      Algorithm     : Version.Hash.Hash_Algorithm := Version.Hash.Sha1)
      return String;
   --  Build a Git IDX v2 payload for Entries. Entries may be unsorted; the
   --  emitted object-name table is sorted by object id. Offsets greater than
   --  16#7FFF_FFFF# are represented through the IDX v2 large-offset table.
   --  Object names and both trailing checksums use Algorithm's width (20 bytes
   --  for Sha1, 32 for Sha256); Pack_Checksum must match that raw width.

end Version.Pack_Index;
