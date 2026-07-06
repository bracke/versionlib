with Version.Objects;
with Version.Repository;

package Version.Pack_Write is

   procedure Write_Pack
     (Repo       : Version.Repository.Repository_Handle;
      Object_Ids : Version.Objects.Object_Id_Vectors.Vector;
      Pack_Path  : String;
      Index_Path : String);
   --  Write a Git-compatible non-delta PACK v2 file and matching IDX v2
   --  file for the supplied object ids.
   --
   --  Object_Ids are validated, sorted, and deduplicated before writing so
   --  output is deterministic. Pack entries contain raw object payloads only;
   --  the loose-object "<kind> <size>\0" header is not included in the
   --  compressed pack entry content.
   --
   --  Raises Ada.IO_Exceptions.Data_Error for missing objects, invalid object
   --  ids, unsupported object kinds, and object-id/content mismatches.

end Version.Pack_Write;
