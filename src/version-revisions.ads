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

end Version.Revisions;
