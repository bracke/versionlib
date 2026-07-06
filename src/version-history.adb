with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;

with Version.Object_Cache;
with Version.Objects; use Version.Objects;
with Version.Hash;
with Version.Shallow_Cache;

package body Version.History is

   package Object_Id_Sets is new Ada.Containers.Ordered_Sets
     (Element_Type => Version.Objects.Object_Id_Storage);

   function Parent_Commits
      (Repo      : Version.Repository.Repository_Handle;
       Objects   : in out Version.Object_Cache.Object_Cache;
       Shallow   : in out Version.Shallow_Cache.Shallow_Cache;
       Commit_Id : Version.Objects.Hex_Object_Id)
       return Commit_Id_Vectors.Vector
   is
      Result : Commit_Id_Vectors.Vector;

      Commit_Object : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object
          (Repo,
           Objects,
           Commit_Id);

      Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
        Version.Objects.Commit_Parent_Ids (Commit_Object);
   begin
      if Version.Shallow_Cache.Is_Boundary (Repo, Shallow, Commit_Id) then
         return Result;
      end if;

      if not Parents.Is_Empty then
         for I in Parents.First_Index .. Parents.Last_Index loop
            Result.Append (Parents.Element (I));
         end loop;
      end if;

      return Result;
   end Parent_Commits;

   function Parent_Commits
      (Repo      : Version.Repository.Repository_Handle;
       Commit_Id : Version.Objects.Hex_Object_Id)
       return Commit_Id_Vectors.Vector
   is
      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;
   begin
      return Parent_Commits
        (Repo      => Repo,
         Objects   => Objects,
         Shallow   => Shallow,
         Commit_Id => Commit_Id);
   end Parent_Commits;

   function Is_Ancestor
     (Repo       : Version.Repository.Repository_Handle;
      Base_Id    : Version.Objects.Hex_Object_Id;
      Derived_Id : Version.Objects.Hex_Object_Id)
      return Boolean
   is
      Pending     : Commit_Id_Vectors.Vector;
      Pending_Set : Object_Id_Sets.Set;
      Seen        : Object_Id_Sets.Set;
      Objects     : Version.Object_Cache.Object_Cache;
      Shallow     : Version.Shallow_Cache.Shallow_Cache;
   begin
      Pending.Append (Derived_Id);
      Pending_Set.Include (Derived_Id);

      while not Pending.Is_Empty loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Pending.First_Element;
         begin
            Pending.Delete_First;
            Pending_Set.Exclude (Current_Id);

            if Current_Id = Base_Id then
               return True;
            end if;

            if not Seen.Contains (Current_Id) then
               Seen.Include (Current_Id);

               declare
                  Parents : constant Commit_Id_Vectors.Vector :=
                    Parent_Commits
                      (Repo      => Repo,
                       Objects   => Objects,
                       Shallow   => Shallow,
                       Commit_Id => Current_Id);
               begin
                  if not Parents.Is_Empty then
                     for I in Parents.First_Index .. Parents.Last_Index loop
                        if not Seen.Contains (Parents.Element (I))
                          and then not Pending_Set.Contains (Parents.Element (I))
                        then
                           Pending.Append (Parents.Element (I));
                           Pending_Set.Include (Parents.Element (I));
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      return False;
   end Is_Ancestor;

   function Collect_Ancestors
     (Repo     : Version.Repository.Repository_Handle;
      Start_Id : Version.Objects.Hex_Object_Id)
      return Commit_Id_Vectors.Vector
   is
      Result      : Commit_Id_Vectors.Vector;
      Pending     : Commit_Id_Vectors.Vector;
      Pending_Set : Object_Id_Sets.Set;
      Seen        : Object_Id_Sets.Set;
      Objects     : Version.Object_Cache.Object_Cache;
      Shallow     : Version.Shallow_Cache.Shallow_Cache;
   begin
      Pending.Append (Start_Id);
      Pending_Set.Include (Start_Id);

      while not Pending.Is_Empty loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Pending.First_Element;
         begin
            Pending.Delete_First;
            Pending_Set.Exclude (Current_Id);

            if not Seen.Contains (Current_Id) then
               Seen.Include (Current_Id);
               Result.Append (Current_Id);

               declare
                  Parents : constant Commit_Id_Vectors.Vector :=
                    Parent_Commits
                      (Repo      => Repo,
                       Objects   => Objects,
                       Shallow   => Shallow,
                       Commit_Id => Current_Id);
               begin
                  if not Parents.Is_Empty then
                     for I in Parents.First_Index .. Parents.Last_Index loop
                        if not Seen.Contains (Parents.Element (I))
                          and then not Pending_Set.Contains (Parents.Element (I))
                        then
                           Pending.Append (Parents.Element (I));
                           Pending_Set.Include (Parents.Element (I));
                        end if;
                     end loop;
                  end if;
               end;
            end if;
         end;
      end loop;

      return Result;
   end Collect_Ancestors;

   function Merge_Bases
     (Repo  : Version.Repository.Repository_Handle;
      Left  : Version.Objects.Hex_Object_Id;
      Right : Version.Objects.Hex_Object_Id)
      return Commit_Id_Vectors.Vector
   is
      Left_Ancestors : constant Commit_Id_Vectors.Vector :=
        Collect_Ancestors
          (Repo     => Repo,
           Start_Id => Left);
      Right_Ancestors : constant Commit_Id_Vectors.Vector :=
        Collect_Ancestors
          (Repo     => Repo,
           Start_Id => Right);
      Left_Set   : Object_Id_Sets.Set;
      Common_Set : Object_Id_Sets.Set;
      Common     : Commit_Id_Vectors.Vector;
      Result     : Commit_Id_Vectors.Vector;
   begin
      if not Left_Ancestors.Is_Empty then
         for I in Left_Ancestors.First_Index .. Left_Ancestors.Last_Index loop
            Left_Set.Include (Left_Ancestors.Element (I));
         end loop;
      end if;

      if not Right_Ancestors.Is_Empty then
         for I in Right_Ancestors.First_Index .. Right_Ancestors.Last_Index loop
            declare
               Candidate : constant Version.Objects.Hex_Object_Id :=
                 Right_Ancestors.Element (I);
            begin
               if Left_Set.Contains (Candidate)
                 and then not Common_Set.Contains (Candidate)
               then
                  Common.Append (Candidate);
                  Common_Set.Include (Candidate);
               end if;
            end;
         end loop;
      end if;

      if Common.Is_Empty then
         return Result;
      end if;

      for I in Common.First_Index .. Common.Last_Index loop
         declare
            Candidate : constant Version.Objects.Hex_Object_Id :=
              Common.Element (I);
            Dominated : Boolean := False;
         begin
            for J in Common.First_Index .. Common.Last_Index loop
               if I /= J
                 and then Is_Ancestor
                   (Repo       => Repo,
                    Base_Id    => Candidate,
                    Derived_Id => Common.Element (J))
               then
                  Dominated := True;
                  exit;
               end if;
            end loop;

            if not Dominated then
               Result.Append (Candidate);
            end if;
         end;
      end loop;

      return Result;
   end Merge_Bases;

   function Merge_Base
     (Repo  : Version.Repository.Repository_Handle;
      Left  : Version.Objects.Hex_Object_Id;
      Right : Version.Objects.Hex_Object_Id)
      return Version.Objects.Hex_Object_Id
   is
      Bases : constant Commit_Id_Vectors.Vector :=
        Merge_Bases (Repo => Repo, Left => Left, Right => Right);
   begin
      if Bases.Is_Empty then
         raise Ada.IO_Exceptions.Data_Error with "no merge base found";
      end if;

      return Bases.First_Element;
   end Merge_Base;

   procedure Collect_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Seen    : in out Object_Id_Sets.Set;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Result  : in out Version.Objects.Object_Id_Vectors.Vector);

   procedure Add_Object
     (Id     : Version.Objects.Hex_Object_Id;
      Seen   : in out Object_Id_Sets.Set;
      Result : in out Version.Objects.Object_Id_Vectors.Vector)
   is
   begin
      if not Seen.Contains (Id) then
         Seen.Include (Id);
         Result.Append (Id);
      end if;
   end Add_Object;

   procedure Collect_Tree
     (Repo    : Version.Repository.Repository_Handle;
      Objects : in out Version.Object_Cache.Object_Cache;
      Seen    : in out Object_Id_Sets.Set;
      Tree_Id : Version.Objects.Hex_Object_Id;
      Result  : in out Version.Objects.Object_Id_Vectors.Vector)
   is
      Obj  : constant Version.Objects.Git_Object :=
        Version.Object_Cache.Read_Object (Repo, Objects, Tree_Id);
      Data : constant String := Version.Objects.Content (Obj);
      Pos  : Natural := Data'First;
      Raw_Length : constant Natural :=
        Version.Hash.Raw_Length (Version.Repository.Algorithm (Repo));
   begin
      if Version.Objects.Kind (Obj) /= Version.Objects.Tree_Object then
         raise Ada.IO_Exceptions.Data_Error with "reachable tree object is not a tree";
      end if;

      Add_Object (Tree_Id, Seen, Result);

      while Pos <= Data'Last loop
         declare
            Mode_Start : constant Natural := Pos;
            Mode_End   : Natural := 0;
            Entry_Id   : Version.Objects.Object_Id_Storage;
         begin
            while Pos <= Data'Last and then Data (Pos) /= ' ' loop
               Pos := Pos + 1;
            end loop;

            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error with "corrupt tree: missing mode terminator";
            end if;

            Mode_End := Pos - 1;
            Pos := Pos + 1;
            while Pos <= Data'Last
              and then Data (Pos) /= Character'Val (0)
            loop
               Pos := Pos + 1;
            end loop;

            if Pos > Data'Last then
               raise Ada.IO_Exceptions.Data_Error with "corrupt tree: missing name terminator";
            end if;

            Pos := Pos + 1;

            if Pos + Raw_Length - 1 > Data'Last then
               raise Ada.IO_Exceptions.Data_Error with "corrupt tree: truncated object id";
            end if;

            Entry_Id :=
              Version.Objects.To_Hex (Data (Pos .. Pos + Raw_Length - 1));
            Pos := Pos + Raw_Length;

            declare
               Mode_Text : constant String := Data (Mode_Start .. Mode_End);
            begin
               if Mode_Text = "40000" then
                  Collect_Tree (Repo, Objects, Seen, Entry_Id, Result);
               else
                  Add_Object (Entry_Id, Seen, Result);
               end if;
            end;
         end;
      end loop;
   end Collect_Tree;

   function Reachable_Objects
     (Repo    : Version.Repository.Repository_Handle;
      Root_Id : Version.Objects.Hex_Object_Id)
      return Version.Objects.Object_Id_Vectors.Vector
   is
      Result      : Version.Objects.Object_Id_Vectors.Vector;
      Pending     : Version.Objects.Object_Id_Vectors.Vector;
      Pending_Set : Object_Id_Sets.Set;
      Seen        : Object_Id_Sets.Set;
      Objects     : Version.Object_Cache.Object_Cache;
   begin
      Pending.Append (Root_Id);
      Pending_Set.Include (Root_Id);

      while not Pending.Is_Empty loop
         declare
            Current_Id : constant Version.Objects.Hex_Object_Id :=
              Pending.First_Element;
         begin
            Pending.Delete_First;
            Pending_Set.Exclude (Current_Id);

            if not Seen.Contains (Current_Id) then
               declare
                  Obj : constant Version.Objects.Git_Object :=
                    Version.Object_Cache.Read_Object (Repo, Objects, Current_Id);
               begin
                  Add_Object (Current_Id, Seen, Result);

                  case Version.Objects.Kind (Obj) is
                     when Version.Objects.Commit_Object =>
                        Collect_Tree
                          (Repo    => Repo,
                           Objects => Objects,
                           Seen    => Seen,
                           Tree_Id => Version.Objects.Commit_Tree_Id (Obj),
                           Result  => Result);

                        declare
                           Parents : constant Version.Objects.Object_Id_Vectors.Vector :=
                             Version.Objects.Commit_Parent_Ids (Obj);
                        begin
                           if not Parents.Is_Empty then
                              for I in Parents.First_Index .. Parents.Last_Index loop
                                 if not Seen.Contains (Parents.Element (I))
                                   and then not Pending_Set.Contains (Parents.Element (I))
                                 then
                                    Pending.Append (Parents.Element (I));
                                    Pending_Set.Include (Parents.Element (I));
                                 end if;
                              end loop;
                           end if;
                        end;

                     when Version.Objects.Tree_Object =>
                        Collect_Tree
                          (Repo    => Repo,
                           Objects => Objects,
                           Seen    => Seen,
                           Tree_Id => Current_Id,
                           Result  => Result);

                     when Version.Objects.Blob_Object =>
                        null;

                     when Version.Objects.Tag_Object =>
                        Pending.Append (Version.Objects.Tag_Target_Id (Obj));

                     when Version.Objects.Unknown_Object =>
                        raise Ada.IO_Exceptions.Data_Error with "unknown reachable object kind";
                  end case;
               end;
            end if;
         end;
      end loop;

      return Result;
   end Reachable_Objects;

end Version.History;