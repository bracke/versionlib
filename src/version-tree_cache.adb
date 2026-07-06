package body Version.Tree_Cache is

   procedure Clear (Cache : in out Tree_Cache) is
   begin
      Cache.Trees.Clear;
   end Clear;

   function Cached_Tree_Count
     (Cache : Tree_Cache)
      return Natural
   is
   begin
      return Natural (Cache.Trees.Length);
   end Cached_Tree_Count;

   function Flatten_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Cache   : in out Tree_Cache;
      Tree_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Pos : constant Tree_Maps.Cursor := Cache.Trees.Find (Tree_Id);
   begin
      if Tree_Maps.Has_Element (Pos) then
         return Tree_Maps.Element (Pos);
      end if;

      declare
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Flatten_Tree (Repo => Repo, Tree_Id => Tree_Id);
      begin
         Cache.Trees.Include (Tree_Id, Entries);
         return Entries;
      end;
   end Flatten_Tree;

end Version.Tree_Cache;
