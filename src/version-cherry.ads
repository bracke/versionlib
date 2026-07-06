with Ada.Containers.Vectors;

with Version.Objects;
with Version.Repository;

--  `git cherry`: for each commit reachable from Head but not Upstream, report
--  whether an equivalent change (same patch-id) already exists in Upstream.
package Version.Cherry is

   type Cherry_Entry is record
      Id                  : Version.Objects.Object_Id_Storage;
      Equivalent_Upstream : Boolean;  --  True => "-", False => "+"
   end record;

   package Cherry_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Cherry_Entry);

   function Status
     (Repo     : Version.Repository.Repository_Handle;
      Upstream : Version.Objects.Hex_Object_Id;
      Head     : Version.Objects.Hex_Object_Id)
      return Cherry_Vectors.Vector;
   --  Head-only commits, oldest first, each marked equivalent-in-upstream or
   --  not, by comparing patch-ids against the upstream-only commits.

end Version.Cherry;
