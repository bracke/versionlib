with Ada.Containers.Ordered_Maps;
with Ada.Containers.Ordered_Sets;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Version.Object_Cache;
with Version.Objects; use Version.Objects;
with Version.Hash;
with Version.Shallow_Cache;
with Version.Tree_Cache;

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

   --  git's rev-list: a committer-date-ordered walk over both the interesting
   --  (Include) and uninteresting (Exclude) frontiers at once.  The queue is
   --  popped newest-first, so by the time a commit is popped every child that
   --  could mark it uninteresting has already been popped and propagated --
   --  which is also why, exactly as in git, clock skew can leak a commit.
   function Rev_List
     (Repo    : Version.Repository.Repository_Handle;
      Include : Commit_Id_Vectors.Vector;
      Exclude : Commit_Id_Vectors.Vector := Commit_Id_Vectors.Empty_Vector;
      Options : Rev_List_Options := (others => <>))
      return Commit_Id_Vectors.Vector
   is
      type Queue_Entry is record
         Time          : Long_Long_Integer := 0;
         Seq           : Natural := 0;
         Uninteresting : Boolean := False;
         Id            : Version.Objects.Object_Id_Storage;
      end record;

      --  Newest first; Seq breaks ties so the order is total (and stable in
      --  discovery order, as git's insertion-ordered queue is).
      function "<" (L, R : Queue_Entry) return Boolean is
        (if L.Time /= R.Time then L.Time > R.Time else L.Seq < R.Seq);

      package Queue_Sets is new Ada.Containers.Ordered_Sets
        (Element_Type => Queue_Entry, "<" => "<");

      --  Each commit is queued at most twice: once per frontier.  Re-queuing
      --  on the uninteresting side is what lets a commit already popped as
      --  interesting still propagate the boundary to its parents.
      type Seen_State is record
         Interesting   : Boolean := False;
         Uninteresting : Boolean := False;
      end record;

      package Seen_Maps is new Ada.Containers.Ordered_Maps
        (Key_Type     => Version.Objects.Object_Id_Storage,
         Element_Type => Seen_State);

      package Signature_Maps is new Ada.Containers.Ordered_Maps
        (Key_Type     => Version.Objects.Object_Id_Storage,
         Element_Type => Unbounded_String);

      Objects    : Version.Object_Cache.Object_Cache;
      Shallow    : Version.Shallow_Cache.Shallow_Cache;
      Trees      : Version.Tree_Cache.Tree_Cache;
      Signatures : Signature_Maps.Map;

      Queue   : Queue_Sets.Set;
      Seen    : Seen_Maps.Map;
      Seq     : Natural := 0;
      Live    : Natural := 0;   --  interesting entries still queued
      Skipped : Natural := 0;
      Result  : Commit_Id_Vectors.Vector;

      function Commit_Time
        (Id : Version.Objects.Hex_Object_Id) return Long_Long_Integer
      is
      begin
         return Version.Objects.Commit_Committer_Time
           (Version.Object_Cache.Read_Object (Repo, Objects, Id));
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
            return 0;
      end Commit_Time;

      procedure Push
        (Id            : Version.Objects.Hex_Object_Id;
         Uninteresting : Boolean)
      is
         Cur   : constant Seen_Maps.Cursor := Seen.Find (Id);
         State : Seen_State;
      begin
         if Seen_Maps.Has_Element (Cur) then
            State := Seen_Maps.Element (Cur);
            if (Uninteresting and then State.Uninteresting)
              or else (not Uninteresting and then State.Interesting)
            then
               return;   --  already queued on this frontier
            end if;
         end if;

         if Uninteresting then
            State.Uninteresting := True;
         else
            State.Interesting := True;
            Live := Live + 1;
         end if;

         if Seen_Maps.Has_Element (Cur) then
            Seen.Replace_Element (Cur, State);
         else
            Seen.Insert (Id, State);
         end if;

         Queue.Insert
           ((Time          => Commit_Time (Id),
             Seq           => Seq,
             Uninteresting => Uninteresting,
             Id            => Id));
         Seq := Seq + 1;
      end Push;

      Path_Limited : constant Boolean := not Options.Paths.Is_Empty;

      function Under_Limit (Path : String) return Boolean is
      begin
         --  A limit names a file, or a directory whose subtree it covers.
         for Limit of Options.Paths loop
            if Path = Limit
              or else (Path'Length > Limit'Length
                       and then Path (Path'First
                                      .. Path'First + Limit'Length - 1) = Limit
                       and then Path (Path'First + Limit'Length) = '/')
            then
               return True;
            end if;
         end loop;

         return False;
      end Under_Limit;

      function Signature
        (Id : Version.Objects.Hex_Object_Id) return Unbounded_String
      is
         Cur  : constant Signature_Maps.Cursor := Signatures.Find (Id);
         Text : Unbounded_String;
      begin
         if Signature_Maps.Has_Element (Cur) then
            return Signature_Maps.Element (Cur);
         end if;

         --  What the commit's tree holds under the limits. Two commits with
         --  equal signatures are TREESAME in git's sense.
         declare
            Commit : constant Version.Objects.Git_Object :=
              Version.Object_Cache.Read_Object (Repo, Objects, Id);
         begin
            for E of Version.Tree_Cache.Flatten_Tree
              (Repo, Trees, Version.Objects.Commit_Tree_Id (Commit))
            loop
               if Under_Limit (To_String (E.Path)) then
                  Append (Text, E.Path);
                  Append (Text, Character'Val (0));
                  Append (Text, Version.Objects.To_String (E.Id));
                  Append (Text, Character'Val (10));
               end if;
            end loop;
         exception
            when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
               null;
         end;

         Signatures.Insert (Id, Text);
         return Text;
      end Signature;
   begin
      for Id of Exclude loop
         Push (Id, Uninteresting => True);
      end loop;
      for Id of Include loop
         Push (Id, Uninteresting => False);
      end loop;

      --  Once no interesting commit is queued, the rest of the walk could only
      --  mark boundaries, never produce output.
      while Live > 0 and then not Queue.Is_Empty loop
         declare
            Item : constant Queue_Entry := Queue.First_Element;
            Parents     : Commit_Id_Vectors.Vector;
            Emit        : Boolean;
            Same_Parent : Integer;
         begin
            Queue.Delete_First;

            Parents :=
              Parent_Commits
                (Repo      => Repo,
                 Objects   => Objects,
                 Shallow   => Shallow,
                 Commit_Id => Item.Id);

            if not Item.Uninteresting then
               Live := Live - 1;
            end if;

            --  A commit reached from both frontiers is excluded; the
            --  uninteresting pass still walks it, so drop it here only.
            Emit :=
              not Item.Uninteresting
              and then not Seen.Element (Item.Id).Uninteresting
              and then not (Options.No_Merges
                            and then Natural (Parents.Length) > 1)
              and then Natural (Parents.Length) >= Options.Min_Parents
              and then (Options.Max_Parents = No_Parent_Limit
                        or else Natural (Parents.Length)
                                <= Options.Max_Parents);

            --  git's default history simplification. A commit that leaves the
            --  limited paths exactly as some parent left them is not itself a
            --  change to them, so it is dropped -- and for a merge, only that
            --  parent is followed, which is what makes a side branch that
            --  never touched the paths vanish from the result.
            Same_Parent := -1;

            if Path_Limited and then not Item.Uninteresting then
               declare
                  Mine : constant Unbounded_String := Signature (Item.Id);
               begin
                  for I in Parents.First_Index .. Parents.Last_Index loop
                     if Signature (Parents.Element (I)) = Mine then
                        Same_Parent := I;
                        exit;
                     end if;
                  end loop;

                  if Parents.Is_Empty then
                     --  A root commit counts as a change when the paths
                     --  exist in it at all.
                     Emit := Emit and then Mine /= Null_Unbounded_String;
                  else
                     Emit := Emit and then Same_Parent < 0;
                  end if;
               end;
            end if;

            if Emit then
               --  git drops the first Skip selected commits, so the count cap
               --  below applies to what survives the skip.
               if Skipped < Options.Skip then
                  Skipped := Skipped + 1;
               else
                  Result.Append (Item.Id);
               end if;
            end if;

            exit when Options.Max_Count > 0
              and then Natural (Result.Length) >= Options.Max_Count;

            if Same_Parent >= 0 then
               Push (Parents.Element (Same_Parent), Item.Uninteresting);
            else
               for I in Parents.First_Index .. Parents.Last_Index loop
                  exit when Options.First_Parent
                    and then I > Parents.First_Index;
                  Push (Parents.Element (I), Item.Uninteresting);
               end loop;
            end if;
         end;
      end loop;

      if Options.Oldest_First then
         declare
            Reversed : Commit_Id_Vectors.Vector;
         begin
            for I in reverse Result.First_Index .. Result.Last_Index loop
               Reversed.Append (Result.Element (I));
            end loop;
            return Reversed;
         end;
      end if;

      return Result;
   end Rev_List;

   function Apply_Limits
     (Commits : Commit_Id_Vectors.Vector;
      Options : Rev_List_Options)
      return Commit_Id_Vectors.Vector
   is
      Result : Commit_Id_Vectors.Vector;
      Kept   : Natural := 0;
   begin
      for I in Commits.First_Index .. Commits.Last_Index loop
         exit when Options.Max_Count > 0 and then Kept >= Options.Max_Count;

         if I >= Commits.First_Index + Options.Skip then
            Result.Append (Commits.Element (I));
            Kept := Kept + 1;
         end if;
      end loop;

      if Options.Oldest_First then
         declare
            Reversed : Commit_Id_Vectors.Vector;
         begin
            for I in reverse Result.First_Index .. Result.Last_Index loop
               Reversed.Append (Result.Element (I));
            end loop;

            return Reversed;
         end;
      end if;

      return Result;
   end Apply_Limits;

   function Topological_Order
     (Repo     : Version.Repository.Repository_Handle;
      Selected : Commit_Id_Vectors.Vector)
      return Commit_Id_Vectors.Vector
   is
      package Index_Maps is new Ada.Containers.Ordered_Maps
        (Key_Type     => Version.Objects.Object_Id_Storage,
         Element_Type => Natural);

      Position : Index_Maps.Map;   --  id -> its slot in Selected
      Children : array (0 .. Natural'Max (Natural (Selected.Length), 1) - 1)
                   of Natural := (others => 0);
      Emitted  : array (Children'Range) of Boolean := (others => False);

      Objects : Version.Object_Cache.Object_Cache;
      Shallow : Version.Shallow_Cache.Shallow_Cache;

      Stack  : Commit_Id_Vectors.Vector;
      Result : Commit_Id_Vectors.Vector;

      function Parents_Of (Id : Version.Objects.Hex_Object_Id)
         return Commit_Id_Vectors.Vector
      is
      begin
         return Parent_Commits
           (Repo => Repo, Objects => Objects, Shallow => Shallow,
            Commit_Id => Id);
      end Parents_Of;
   begin
      if Selected.Is_Empty then
         return Result;
      end if;

      for I in Selected.First_Index .. Selected.Last_Index loop
         Position.Include (Selected.Element (I), I);
      end loop;

      --  Count, for each selected commit, how many selected commits name it
      --  as a parent. Those are the children that must come out first.
      for Id of Selected loop
         for P of Parents_Of (Id) loop
            declare
               Cur : constant Index_Maps.Cursor := Position.Find (P);
            begin
               if Index_Maps.Has_Element (Cur) then
                  Children (Index_Maps.Element (Cur)) :=
                    Children (Index_Maps.Element (Cur)) + 1;
               end if;
            end;
         end loop;
      end loop;

      --  Seed with the commits nothing selected points at, oldest last so the
      --  newest is popped first.
      for I in reverse Selected.First_Index .. Selected.Last_Index loop
         if Children (I) = 0 then
            Stack.Append (Selected.Element (I));
         end if;
      end loop;

      while not Stack.Is_Empty loop
         declare
            Id  : constant Version.Objects.Object_Id_Storage :=
              Stack.Last_Element;
            Idx : constant Natural := Position.Element (Id);
         begin
            Stack.Delete_Last;

            if not Emitted (Idx) then
               Emitted (Idx) := True;
               Result.Append (Id);

               for P of Parents_Of (Id) loop
                  declare
                     Cur : constant Index_Maps.Cursor := Position.Find (P);
                  begin
                     if Index_Maps.Has_Element (Cur) then
                        declare
                           PI : constant Natural := Index_Maps.Element (Cur);
                        begin
                           Children (PI) := Children (PI) - 1;

                           --  LIFO: the parent that just became ready is
                           --  taken next, so a side branch stays contiguous.
                           if Children (PI) = 0 then
                              Stack.Append (P);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;

      return Result;
   end Topological_Order;

   function Object_List
     (Repo     : Version.Repository.Repository_Handle;
      Commits  : Commit_Id_Vectors.Vector;
      Excluded : Commit_Id_Vectors.Vector := Commit_Id_Vectors.Empty_Vector)
      return Named_Object_Vectors.Vector
   is
      Result        : Named_Object_Vectors.Vector;
      Uninteresting : Object_Id_Sets.Set;
      Seen          : Object_Id_Sets.Set;
      Objects       : Version.Object_Cache.Object_Cache;

      procedure Walk_Tree
        (Tree_Id : Version.Objects.Hex_Object_Id;
         Prefix  : String)
      is
      begin
         if Uninteresting.Contains (Tree_Id)
           or else Seen.Contains (Tree_Id)
         then
            return;
         end if;

         Seen.Include (Tree_Id);
         Result.Append
           (Named_Object'(Id   => Tree_Id,
                          Name => To_Unbounded_String (Prefix)));

         for E of Version.Objects.Tree_Entries (Repo, Tree_Id) loop
            declare
               Name : constant String :=
                 (if Prefix = "" then To_String (E.Path)
                  else Prefix & "/" & To_String (E.Path));
            begin
               case E.Kind is
                  when Version.Objects.Tree_Directory =>
                     Walk_Tree (E.Id, Name);

                  when Version.Objects.Tree_Blob =>
                     if not Uninteresting.Contains (E.Id)
                       and then not Seen.Contains (E.Id)
                     then
                        Seen.Include (E.Id);
                        Result.Append
                          (Named_Object'(Id   => E.Id,
                                         Name => To_Unbounded_String (Name)));
                     end if;

                  when Version.Objects.Tree_Gitlink =>
                     --  A gitlink names a commit in another repository, which
                     --  this one does not have; git does not list it either.
                     null;
               end case;
            end;
         end loop;
      exception
         when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
            null;
      end Walk_Tree;

      function Root_Tree (Commit : Version.Objects.Hex_Object_Id)
         return Version.Objects.Hex_Object_Id
      is
      begin
         return Version.Objects.Commit_Tree_Id
           (Version.Object_Cache.Read_Object (Repo, Objects, Commit));
      end Root_Tree;
   begin
      --  Everything the excluded side already has is uninteresting, so a
      --  range lists only what it introduced.
      for Id of Excluded loop
         for O of Reachable_Objects (Repo, Id) loop
            Uninteresting.Include (O);
         end loop;
      end loop;

      --  git prints every selected commit first, then the object graph.
      for Id of Commits loop
         Result.Append
           (Named_Object'(Id => Id, Name => Null_Unbounded_String));
      end loop;

      for Id of Commits loop
         begin
            Walk_Tree (Root_Tree (Id), "");
         exception
            when Ada.IO_Exceptions.Data_Error | Ada.IO_Exceptions.Name_Error =>
               null;
         end;
      end loop;

      return Result;
   end Object_List;

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