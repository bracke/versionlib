with Ada.Strings.Unbounded;
package body Version.Tree_Cache is

   procedure Clear (Cache : in out Tree_Cache) is
   begin
      Cache.Trees.Clear;
      Cache.Levels.Clear;
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

   function Level
     (Repo    : Version.Repository.Repository_Handle;
      Cache   : in out Tree_Cache;
      Tree_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      Pos : constant Tree_Maps.Cursor := Cache.Levels.Find (Tree_Id);
   begin
      if Tree_Maps.Has_Element (Pos) then
         return Tree_Maps.Element (Pos);
      end if;
      declare
         Entries : constant Version.Objects.Tree_Entry_Vectors.Vector :=
           Version.Objects.Tree_Entries (Repo => Repo, Tree_Id => Tree_Id);
      begin
         Cache.Levels.Include (Tree_Id, Entries);
         return Entries;
      end;
   end Level;

   function Entries_Under
     (Repo    : Version.Repository.Repository_Handle;
      Cache   : in out Tree_Cache;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Limit   : String)
      return Version.Objects.Tree_Entry_Vectors.Vector
   is
      use Ada.Strings.Unbounded;
      use type Version.Objects.Tree_Entry_Kind;
      Result : Version.Objects.Tree_Entry_Vectors.Vector;
      Tree   : Version.Objects.Hex_Object_Id := Tree_Id;
      Start  : Positive := Limit'First;
   begin
      if Limit'Length = 0 then
         return Flatten_Tree (Repo, Cache, Tree_Id);
      end if;

      loop
         declare
            Stop : Natural := Limit'Last + 1;
         begin
            for K in Start .. Limit'Last loop
               if Limit (K) = '/' then
                  Stop := K;
                  exit;
               end if;
            end loop;
            declare
               Name  : constant String := Limit (Start .. Stop - 1);
               Here  : constant Version.Objects.Tree_Entry_Vectors.Vector :=
                 Level (Repo, Cache, Tree);
               Found : Boolean := False;
            begin
               for E of Here loop
                  if To_String (E.Path) = Name then
                     Found := True;
                     if Stop > Limit'Last then
                        --  The limit itself: a file, or a whole subtree.
                        if E.Kind = Version.Objects.Tree_Directory then
                           for Sub of Flatten_Tree (Repo, Cache, E.Id) loop
                              Result.Append
                                (Version.Objects.Tree_Entry'
                                   (Path => To_Unbounded_String
                                              (Limit & "/" & To_String (Sub.Path)),
                                    Id   => Sub.Id,
                                    Kind => Sub.Kind,
                                    Mode => Sub.Mode));
                           end loop;
                        else
                           Result.Append
                             (Version.Objects.Tree_Entry'
                                (Path => To_Unbounded_String (Limit),
                                 Id   => E.Id,
                                 Kind => E.Kind,
                                 Mode => E.Mode));
                        end if;
                        return Result;
                     elsif E.Kind = Version.Objects.Tree_Directory then
                        Tree := E.Id;
                     else
                        --  A file where the limit expects a directory.
                        return Result;
                     end if;
                     exit;
                  end if;
               end loop;
               if not Found then
                  return Result;
               end if;
            end;
            Start := Stop + 1;
         end;
      end loop;
   end Entries_Under;

end Version.Tree_Cache;
