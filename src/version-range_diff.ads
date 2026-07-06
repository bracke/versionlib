with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Version.Objects;
with Version.Repository;

--  `git range-diff`: compare two commit ranges (two revisions of a patch
--  series) and pair their commits. Commits are matched first by patch-id
--  (Unchanged) then by subject (Changed); leftovers are Removed (old only) or
--  Added (new only). The inner diff-of-diffs is not produced.
package Version.Range_Diff is

   type Pair_Status is (Unchanged, Changed, Removed, Added);

   type Pairing is record
      Old_Pos : Natural;
      New_Pos : Natural;
      Old_Id  : Version.Objects.Object_Id_Storage;
      New_Id  : Version.Objects.Object_Id_Storage;
      Subject : Ada.Strings.Unbounded.Unbounded_String;
      Status  : Pair_Status;
   end record;

   package Pairing_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Pairing);

   function Compare
     (Repo     : Version.Repository.Repository_Handle;
      Old_Base : Version.Objects.Hex_Object_Id;
      Old_Tip  : Version.Objects.Hex_Object_Id;
      New_Base : Version.Objects.Hex_Object_Id;
      New_Tip  : Version.Objects.Hex_Object_Id)
      return Pairing_Vectors.Vector;

end Version.Range_Diff;
