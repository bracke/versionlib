with Version.Objects;
with Version.Repository;

package Version.Revisions is

   type Revision_Kind is
     (Any_Object,
      Commitish,
      Treeish);

   function Resolve
     (Repo : Version.Repository.Repository_Handle;
      Text : String;
      Kind : Revision_Kind := Any_Object)
      return Version.Objects.Hex_Object_Id;

   function Resolve_Commit
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id;

   function Resolve_Tree
     (Repo : Version.Repository.Repository_Handle;
      Text : String)
      return Version.Objects.Hex_Object_Id;

   function Unique_Abbrev_Length
     (Repo    : Version.Repository.Repository_Handle;
      Id      : Version.Objects.Hex_Object_Id;
      Minimum : Positive)
      return Natural;
   --  The shortest hexadecimal prefix length (>= Minimum, capped at the full
   --  id width) that uniquely identifies Id among all loose and packed
   --  objects -- git's `find_unique_abbrev` behaviour for %h/%t/%p. Minimum is
   --  the configured floor (7 for core.abbrev=auto, or the requested width).

   function Objects_With_Prefix
     (Repo   : Version.Repository.Repository_Handle;
      Prefix : String)
      return Version.Objects.Object_Id_Vectors.Vector;
   --  Every object id (any type, loose or packed) whose hexadecimal spelling
   --  starts with Prefix, sorted ascending and de-duplicated -- git's
   --  `rev-parse --disambiguate=<prefix>`.  Prefix shorter than two hex
   --  digits, or non-hexadecimal, yields the empty vector, as git does.

end Version.Revisions;
