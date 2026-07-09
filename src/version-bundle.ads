with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git bundle` v2 offline transport: a bundle is a text header (a magic line,
--  optional prerequisite lines, then "<oid> <refname>" lines, then a blank
--  line) followed by a packfile of the objects reachable from those refs.
package Version.Bundle is

   type Ref_Entry is record
      Id   : Version.Objects.Object_Id_Storage;
      Name : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Ref_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ref_Entry);

   procedure Create
     (Repo        : Version.Repository.Repository_Handle;
      Bundle_Path : String;
      Refs        : Ref_Vectors.Vector);
   --  Write a complete (no-prerequisite) v2 bundle at Bundle_Path containing
   --  Refs and a packfile of all objects reachable from them.
   --  @param Repo Open repository handle.
   --  @param Bundle_Path Destination file path.
   --  @param Refs Resolved refs (object id + full ref name) to include.

   type Bundle_Info is record
      Refs          : Ref_Vectors.Vector;
      Prerequisites : Version.Objects.Object_Id_Vectors.Vector;
      Complete      : Boolean := True;  --  no prerequisites recorded
   end record;

   function Read_Header (Bundle_Path : String) return Bundle_Info;
   --  Parse the textual header of a v2/v3 bundle (refs and prerequisites);
   --  the packfile payload is not read. Raises Data_Error if the file is not a
   --  git bundle.

   procedure Unbundle
     (Repo        : Version.Repository.Repository_Handle;
      Bundle_Path : String;
      Info        : out Bundle_Info);
   --  Unpack the bundle's packfile into Repo's object store (writing a pack
   --  plus its index) and return the parsed header. Refs are not created --
   --  the caller (e.g. `bundle unbundle`, or a clone) decides what to do with
   --  Info.Refs. Raises Data_Error if the bundle is malformed or a recorded
   --  prerequisite object is absent from the receiving repository.

end Version.Bundle;
